package PVE::Storage::Custom::TrueNASPlugin;

use v5.36;
use strict;
use warnings;

use JSON::PP qw(encode_json decode_json);
use URI::Escape qw(uri_escape);
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha1);
use IO::Socket::INET;
use IO::Socket::SSL;
use Time::HiRes qw(usleep);
use Socket qw(inet_ntoa);
use LWP::UserAgent;
use HTTP::Request;
use Cwd qw(abs_path);
use Carp qw(carp croak);

use PVE::Tools qw(run_command trim);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

# ======== Storage plugin identity ========
sub api  { return 11; }                 # storage plugin API version
sub type { return 'truenasplugin'; }    # storage.cfg "type"

sub plugindata {
    return {
        content => [ { images => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],
    };
}


# ======== Config schema (only plugin-specific keys) ========
sub properties {
    return {
        # Transport & connection
        api_transport => {
            description => "API transport: 'ws' (JSON-RPC) or 'rest'.",
            type => 'string', optional => 1,
        },
        api_host => {
            description => "TrueNAS hostname or IP.",
            type => 'string', format => 'pve-storage-server',
        },
        api_key => {
            description => "TrueNAS user-linked API key.",
            type => 'string',
        },
        api_scheme => {
            description => "wss/ws for WS, https/http for REST (defaults: wss/https).",
            type => 'string', optional => 1,
        },
        api_port => {
            description => "TCP port (defaults: 443 for wss/https, 80 for ws/http).",
            type => 'integer', optional => 1,
        },
        api_insecure => {
            description => "Skip TLS certificate verification.",
            type => 'boolean', optional => 1, default => 0,
        },
        prefer_ipv4 => {
            description => "Prefer IPv4 (A records) when resolving api_host.",
            type => 'boolean', optional => 1, default => 1,
        },

        # Placement
        dataset => {
            description => "Parent dataset for zvols (e.g. tank/proxmox).",
            type => 'string',
        },
        zvol_blocksize => {
            description => "ZVOL volblocksize (e.g. 16K, 64K).",
            type => 'string', optional => 1,
        },

        # iSCSI target & portals
        target_iqn => {
            description => "Shared iSCSI Target IQN on TrueNAS (or target's short name).",
            type => 'string',
        },
        discovery_portal => {
            description => "Primary SendTargets portal (IP[:port] or [IPv6]:port).",
            type => 'string',
        },
        portals => {
            description => "Comma-separated additional portals.",
            type => 'string', optional => 1,
        },

        # Initiator pathing
        use_multipath => { type => 'boolean', optional => 1, default => 1 },
        force_delete_on_inuse => {
            description => 'Temporarily logout the target on this node to force delete when TrueNAS reports "target is in use".',
            type        => 'boolean',
            default     => 'false',
        },
        logout_on_free => {
            description => 'After delete, logout the target if no LUNs remain for this node.',
            type        => 'boolean',
            default     => 'false',
        },

        use_by_path   => { type => 'boolean', optional => 1, default => 0 },
        ipv6_by_path  => {
            description => "Normalize IPv6 by-path names (enable only if using IPv6 portals).",
            type => 'boolean', optional => 1, default => 0,
        },

        # CHAP (optional)
        chap_user     => { type => 'string', optional => 1 },
        chap_password => { type => 'string', optional => 1 },

        # Thin provisioning toggle (maps to TrueNAS sparse)
        tn_sparse => {
            description => "Create thin-provisioned zvols on TrueNAS (maps to 'sparse').",
            type => 'boolean', optional => 1, default => 1,
        },
    };
}
sub options {
    return {
        # Base storage options (do NOT add to properties)
        disable => { optional => 1 },
        nodes   => { optional => 1 },
        content => { optional => 1 },
        shared  => { optional => 1 },

        # Connection (fixed to avoid orphaning volumes)
        api_transport => { optional => 1, fixed => 1 },
        api_host      => { fixed => 1 },
        api_key       => { fixed => 1 },
        api_scheme    => { optional => 1, fixed => 1 },
        api_port      => { optional => 1, fixed => 1 },
        api_insecure  => { optional => 1, fixed => 1 },
        prefer_ipv4   => { optional => 1 },

        # Placement
        dataset        => { fixed => 1 },
        zvol_blocksize => { optional => 1, fixed => 1 },

        # Target & portals
        target_iqn       => { fixed => 1 },
        discovery_portal => { fixed => 1 },
        portals          => { optional => 1 },
        force_delete_on_inuse  => { optional => 1 },  # temporarily logout → delete → login (default: off)
        logout_on_free         => { optional => 1 },  # logout if no LUNs remain for this target (default: off)

        # Initiator
        use_multipath => { optional => 1 },
        use_by_path   => { optional => 1 },
        ipv6_by_path  => { optional => 1 },

        # CHAP
        chap_user     => { optional => 1 },
        chap_password => { optional => 1 },

        # Thin toggle
        tn_sparse => { optional => 1 },
    };
}

# ======== DNS/IPv4 helper ========
sub _host_ipv4($host) {
    return $host if $host =~ /^\d+\.\d+\.\d+\.\d+$/; # already IPv4 literal
    my @ent = Socket::gethostbyname($host);          # A-record lookup
    if (@ent && defined $ent[4]) {
        my $ip = inet_ntoa($ent[4]);
        return $ip if $ip;
    }
    return $host; # fallback (could be IPv6 literal or DNS)
}

# ======== REST client (fallback) ========
sub _ua($scfg) {
    my $ua = LWP::UserAgent->new(
        timeout   => 30,
        keep_alive=> 1,
        ssl_opts  => {
            verify_hostname => !$scfg->{api_insecure},
            SSL_verify_mode => $scfg->{api_insecure} ? 0x00 : 0x02,
        }
    );
    return $ua;
}
sub _rest_base($scfg) {
    my $scheme = ($scfg->{api_scheme} && $scfg->{api_scheme} =~ /^http$/i) ? 'http' : 'https';
    my $port = $scfg->{api_port} // ($scheme eq 'https' ? 443 : 80);
    return "$scheme://$scfg->{api_host}:$port/api/v2.0";
}
sub _rest_call($scfg, $method, $path, $payload=undef) {
    my $ua = _ua($scfg);
    my $url = _rest_base($scfg) . $path;
    my $req = HTTP::Request->new(uc($method) => $url);
    $req->header('Authorization' => "Bearer $scfg->{api_key}");
    $req->header('Content-Type'  => 'application/json');
    $req->content(encode_json($payload)) if defined $payload;
    my $res = $ua->request($req);
    die "TrueNAS REST $method $path failed: ".$res->status_line."\nBody: ".$res->decoded_content."\n"
        if !$res->is_success;
    my $content = $res->decoded_content // '';
    return length($content) ? decode_json($content) : undef;
}

# ======== WebSocket JSON-RPC client ========
# Connect to ws(s)://<host>/api/current; auth via auth.login_with_api_key.
sub _ws_defaults($scfg) {
    my $scheme = $scfg->{api_scheme};
    if (!$scheme) { $scheme = 'wss'; }
    elsif ($scheme =~ /^https$/i) { $scheme = 'wss'; }
    elsif ($scheme =~ /^http$/i)  { $scheme = 'ws'; }
    my $port = $scfg->{api_port} // (($scheme eq 'wss') ? 443 : 80);
    return ($scheme, $port);
}
sub _ws_open($scfg) {
    my ($scheme, $port) = _ws_defaults($scfg);
    my $host = $scfg->{api_host};
    my $peer = ($scfg->{prefer_ipv4} // 1) ? _host_ipv4($host) : $host;
    my $path = '/api/current';
    my $sock;
    if ($scheme eq 'wss') {
        $sock = IO::Socket::SSL->new(
            PeerHost => $peer,
            PeerPort => $port,
            SSL_verify_mode => $scfg->{api_insecure} ? 0x00 : 0x02,
            SSL_hostname    => $host,
            Timeout => 15,
        ) or die "wss connect failed: $SSL_ERROR\n";
    } else {
        $sock = IO::Socket::INET->new(
            PeerHost => $peer, PeerPort => $port, Proto => 'tcp', Timeout => 15,
        ) or die "ws connect failed: $!\n";
    }
    # WebSocket handshake
    my $key_raw = join '', map { chr(int(rand(256))) } 1..16;
    my $key_b64 = encode_base64($key_raw, '');
    my $hosthdr = $host.":$port";
    my $req =
      "GET $path HTTP/1.1\r\n".
      "Host: $hosthdr\r\n".
      "Upgrade: websocket\r\n".
      "Connection: Upgrade\r\n".
      "Sec-WebSocket-Key: $key_b64\r\n".
      "Sec-WebSocket-Version: 13\r\n".
      "\r\n";
    print $sock $req;
    my $resp = '';
    while ($sock->sysread(my $buf, 1024)) {
        $resp .= $buf;
        last if $resp =~ /\r\n\r\n/s;
    }
    die "WebSocket handshake failed (no 101)" if $resp !~ m#^HTTP/1\.[01] 101#;
    my ($accept) = $resp =~ /Sec-WebSocket-Accept:\s*(\S+)/i;
    my $expect = encode_base64(sha1($key_b64 . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), '');
    # Case-sensitive check (correct)
    die "WebSocket handshake invalid accept key" if ($accept // '') ne $expect;

    # Authenticate with API key (JSON-RPC)
    my $conn = { sock => $sock, next_id => 1 };
    _ws_rpc($conn, {
        jsonrpc => "2.0", id => $conn->{next_id}++,
        method  => "auth.login_with_api_key",
        params  => [ $scfg->{api_key} ],
    }) or die "TrueNAS auth.login_with_api_key failed";
    return $conn;
}
# ---- WS framing helpers (text only) ----
sub _xor_mask {
    my ($data, $mask) = @_;
    my $len = length($data);
    my $out = $data;
    my $m0 = ord(substr($mask,0,1));
    my $m1 = ord(substr($mask,1,1));
    my $m2 = ord(substr($mask,2,1));
    my $m3 = ord(substr($mask,3,1));
    for (my $i=0; $i<$len; $i++) {
        my $mi = ($i & 3) == 0 ? $m0 : ($i & 3) == 1 ? $m1 : ($i & 3) == 2 ? $m2 : $m3;
        substr($out, $i, 1, chr( ord(substr($out, $i, 1)) ^ $mi ));
    }
    return $out;
}
sub _ws_send_text {
    my ($sock, $payload) = @_;
    my $fin_opcode = 0x81; # FIN + text
    my $maskbit = 0x80;    # client must mask
    my $len = length($payload);
    my $hdr = pack('C', $fin_opcode);
    my $lenfield;
    if ($len <= 125) { $lenfield = pack('C', $maskbit | $len); }
    elsif ($len <= 0xFFFF) { $lenfield = pack('C n', $maskbit | 126, $len); }
    else { $lenfield = pack('C Q>', $maskbit | 127, $len); }
    my $mask = join '', map { chr(int(rand(256))) } 1..4;
    my $masked = _xor_mask($payload, $mask);
    my $frame = $hdr . $lenfield . $mask . $masked;
    my $off = 0;
    while ($off < length($frame)) {
        my $w = $sock->syswrite($frame, length($frame) - $off, $off);
        die "WS write failed: $!" unless defined $w;
        $off += $w;
    }
}
sub _ws_read_exact {
    my ($sock, $ref, $want) = @_;
    $$ref = '' if !defined $$ref;
    my $got = 0;
    while ($got < $want) {
        my $r = $sock->sysread($$ref, $want - $got, $got);
        return undef if !defined $r || $r == 0;
        $got += $r;
    }
    return 1;
}
sub _ws_recv_text {
    my $sock = shift;
    my $hdr;
    _ws_read_exact($sock, \$hdr, 2) or die "WS read hdr failed";
    my ($b1, $b2) = unpack('CC', $hdr);
    my $opcode = $b1 & 0x0f;
    die "WS: unexpected opcode $opcode" if $opcode != 1; # text only
    my $masked = ($b2 & 0x80) ? 1 : 0; # server MUST NOT mask
    my $len = ($b2 & 0x7f);
    if ($len == 126) {
        my $ext; _ws_read_exact($sock, \$ext, 2) or die "WS len16 read fail";
        $len = unpack('n', $ext);
    } elsif ($len == 127) {
        my $ext; _ws_read_exact($sock, \$ext, 8) or die "WS len64 read fail";
        $len = unpack('Q>', $ext);
    }
    my $mask_key = '';
    if ($masked) { _ws_read_exact($sock, \$mask_key, 4) or die "WS unexpected mask"; }
    my $payload = '';
    _ws_read_exact($sock, \$payload, $len) or die "WS payload read fail";
    if ($masked) { $payload = _xor_mask($payload, $mask_key); }
    return $payload;
}
sub _ws_rpc {
    my ($conn, $obj) = @_;
    my $text = encode_json($obj);
    _ws_send_text($conn->{sock}, $text);
    my $resp = _ws_recv_text($conn->{sock});
    my $decoded = decode_json($resp);
    die "JSON-RPC error: ".encode_json($decoded->{error}) if exists $decoded->{error};
    return $decoded->{result};
}

# ======== Transport-agnostic API wrapper ========
sub _api_call($scfg, $ws_method, $ws_params, $rest_fallback) {
    my $transport = lc($scfg->{api_transport} // 'ws');
    if ($transport eq 'ws') {
        my ($res, $err);
        eval {
            my $conn = _ws_open($scfg);
            $res = _ws_rpc($conn, {
                jsonrpc => "2.0", id => 1, method => $ws_method, params => $ws_params // [],
            });
        };
        $err = $@ if $@;
        return $res if !$err;
        return $rest_fallback->() if $rest_fallback;
        die $err;
    } elsif ($transport eq 'rest') {
        return $rest_fallback->() if $rest_fallback;
        die "REST fallback not provided for $ws_method";
    } else {
        die "Invalid api_transport '$transport' (use 'ws' or 'rest')";
    }
}

# ======== TrueNAS API ops (WS with REST fallback) ========
sub _tn_get_target($scfg) {
    my $res = _api_call($scfg, 'iscsi.target.query', [],
        sub { _rest_call($scfg, 'GET', '/iscsi/target') }
    );
    if (ref($res) eq 'ARRAY' && !@$res) {
        my $rest = _rest_call($scfg, 'GET', '/iscsi/target');
        $res = $rest if ref($rest) eq 'ARRAY';
    }
    return $res;
}
sub _tn_targetextents($scfg) {
    my $res = _api_call($scfg, 'iscsi.targetextent.query', [],
        sub { _rest_call($scfg, 'GET', '/iscsi/targetextent') }
    );
    if (ref($res) eq 'ARRAY' && !@$res) {
        my $rest = _rest_call($scfg, 'GET', '/iscsi/targetextent');
        $res = $rest if ref($rest) eq 'ARRAY';
    }
    return $res;
}
sub _tn_extents($scfg) {
    my $res = _api_call($scfg, 'iscsi.extent.query', [],
        sub { _rest_call($scfg, 'GET', '/iscsi/extent') }
    );
    if (ref($res) eq 'ARRAY' && !@$res) {
        my $rest = _rest_call($scfg, 'GET', '/iscsi/extent');
        $res = $rest if ref($rest) eq 'ARRAY';
    }
    return $res;
}
sub _tn_global($scfg) {
    return _api_call($scfg, 'iscsi.global.config', [],
        sub { _rest_call($scfg, 'GET', '/iscsi/global') }
    );
}
# PVE passes size in KiB; TrueNAS expects bytes (volsize) and supports 'sparse'
sub _tn_dataset_create($scfg, $full, $size_kib, $blocksize) {
    my $bytes = int($size_kib) * 1024;
    my $payload = {
        name    => $full,
        type    => 'VOLUME',
        volsize => $bytes,
        sparse  => ($scfg->{tn_sparse} // 1) ? JSON::PP::true : JSON::PP::false,
    };
    $payload->{volblocksize} = $blocksize if $blocksize;
    return _api_call($scfg, 'pool.dataset.create', [ $payload ],
        sub { _rest_call($scfg, 'POST', '/pool/dataset', $payload) }
    );
}
sub _tn_dataset_delete($scfg, $full) {
    my $id = uri_escape($full); # encode '/' as %2F for REST
    return _api_call($scfg, 'pool.dataset.delete', [ $full, { recursive => JSON::PP::true } ],
        sub { _rest_call($scfg, 'DELETE', "/pool/dataset/id/$id?recursive=true") }
    );
}
sub _tn_dataset_get($scfg, $full) {
    my $id = uri_escape($full);
    return _api_call($scfg, 'pool.dataset.get_instance', [ $full ],
        sub { _rest_call($scfg, 'GET', "/pool/dataset/id/$id") }
    );
}

sub _tn_dataset_resize($scfg, $full, $new_bytes) {
    # REST path uses %2F for '/', same as get/delete helpers
    my $id = URI::Escape::uri_escape($full);
    my $payload = { volsize => int($new_bytes) }; # grow-only
    return _api_call($scfg, 'pool.dataset.update', [ $full, $payload ],
        sub { _rest_call($scfg, 'PUT', "/pool/dataset/id/$id", $payload) }
    );
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    # We support disk snapshots via ZFS (no vmstate/RAM).
    return 1 if $feature && $feature eq 'snapshot';

    return undef; # others unchanged
}

# Grow-only resize of a raw iSCSI-backed zvol, with TrueNAS 80% preflight and initiator rescan.
sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $new_size_bytes, @rest) = @_;

    # Parse our custom volname: "vol-<zname>-lun<N>"
    my (undef, $zname, undef, undef, undef, undef, $fmt, $lun) =
        $class->parse_volname($volname);
    die "only raw is supported\n" if defined($fmt) && $fmt ne 'raw';

    my $full = $scfg->{dataset} . '/' . $zname;

    # Fetch current zvol info from TrueNAS
    my $ds = _tn_dataset_get($scfg, $full) // {};
    my $norm = sub {
        my ($v) = @_;
        return 0 if !defined $v;
        return $v if !ref($v);
        return $v->{parsed} // $v->{raw} // 0 if ref($v) eq 'HASH';
        return 0;
    };
    my $cur_bytes = $norm->($ds->{volsize});
    my $bs_bytes  = $norm->($ds->{volblocksize}); # may be 0/undef

    # IMPORTANT: Proxmox passes the ABSOLUTE target size in BYTES.
    my $req_bytes = int($new_size_bytes);

    # Grow-only enforcement
    die "shrink not supported (current=$cur_bytes requested=$req_bytes)\n"
        if $req_bytes <= $cur_bytes;

    # Align up to volblocksize to avoid middleware alignment complaints
    if ($bs_bytes && $bs_bytes > 0) {
        my $rem = $req_bytes % $bs_bytes;
        $req_bytes += ($bs_bytes - $rem) if $rem;
    }

    # Compute delta AFTER alignment
    my $delta = $req_bytes - $cur_bytes;

    # ---- Preflight: mirror TrueNAS middleware's ~80% headroom rule ----
    my $pds          = _tn_dataset_get($scfg, $scfg->{dataset}) // {};
    my $avail_bytes  = $norm->($pds->{available}); # parent dataset/pool available
    my $max_grow     = $avail_bytes ? int($avail_bytes * 0.80) : 0;

    if ($avail_bytes && $delta > $max_grow) {
        my $fmt_g = sub { sprintf('%.2f GiB', $_[0] / (1024*1024*1024)) };
        die sprintf(
            "resize refused by preflight: requested grow %s exceeds TrueNAS ~80%% headroom (%s) on dataset %s.\n".
            "Reduce the grow amount or free space on the backing dataset/pool.\n",
            $fmt_g->($delta), $fmt_g->($max_grow), $scfg->{dataset}
        );
    }
    # ---- End preflight ----

    # Perform the TrueNAS zvol grow
    my $id = URI::Escape::uri_escape($full);
    my $payload = { volsize => int($req_bytes) };

    _api_call(
        $scfg,
        'pool.dataset.update',
        [ $full, $payload ],
        sub { _rest_call($scfg, 'PUT', "/pool/dataset/id/$id", $payload) },
    );

    # Initiator-side rescan so Linux + multipath see the new size
    _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan failed");
    if ($scfg->{use_multipath}) {
        _try_run(['multipath','-r'], "multipath map reload failed");
    }
    run_command(['udevadm','settle'], outfunc => sub {});
    select(undef, undef, undef, 0.25);  # ~250ms

    # Proxmox expects KiB as return value
    my $ret_kib = int(($req_bytes + 1023) / 1024);
    return $ret_kib;
}

# Create a ZFS snapshot on the TrueNAS zvol backing this volume.
# 'snapname' must be a simple token (PVE passes it).
sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname, $vmstate) = @_;

    # We only support disk-only snapshots on this backend.
    die "RAM/vmstate snapshots are not supported on TrueNAS iSCSI backend\n"
        if $vmstate;

    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{dataset} . '/' . $zname; # pool/dataset/.../vm-<id>-disk-<n>

    # TrueNAS REST: POST /zfs/snapshot  { "dataset": "<pool/ds/...>", "name": "<snap>", "recursive": false }
    # Snapshot will be <pool/ds/...>@<snapname>
    my $payload = { dataset => $full, name => $snapname, recursive => JSON::false };

    _api_call(
        $scfg, 'zfs.snapshot.create', [ $payload ],
        sub { _rest_call($scfg, 'POST', '/zfs/snapshot', $payload) },
    );

    return undef;
}

# Delete a ZFS snapshot on the zvol.
sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{dataset} . '/' . $zname;          # pool/dataset/.../vm-<id>-disk-<n>
    my $snap_full = $full . '@' . $snapname;             # full snapshot name
    my $id = URI::Escape::uri_escape($snap_full);        # '@' must be URL-encoded in path

    # TrueNAS REST: DELETE /zfs/snapshot/id/<pool%2Fds%40snap>
    _api_call(
        $scfg, 'zfs.snapshot.delete', [ $snap_full ],
        sub { _rest_call($scfg, 'DELETE', "/zfs/snapshot/id/$id", undef) },
    );

    return undef;
}

# Roll back the zvol to a specific ZFS snapshot and rescan iSCSI/multipath.
sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{dataset} . '/' . $zname;
    my $snap_full = $full . '@' . $snapname;

    # ZFS semantics: rolling back to a non-latest snapshot requires destroying newer ones.
    # TrueNAS exposes a 'rollback' action for snapshots. We request a forced rollback to handle older snapshots.
    my $payload = {
        snapshot => $snap_full,
        force    => JSON::true,   # allow rollback even if newer snaps exist (destroy them)
        recursive => JSON::false, # zvol only
    };

    # TrueNAS REST: POST /zfs/snapshot/rollback { snapshot, force, recursive }
    _api_call(
        $scfg, 'zfs.snapshot.rollback', [ $payload ],
        sub { _rest_call($scfg, 'POST', '/zfs/snapshot/rollback', $payload) },
    );

    # Refresh initiator view so the kernel/multipath sees rolled-back size/geometry immediately
    eval { PVE::Tools::run_command(['iscsiadm','-m','session','-R'], outfunc=>sub{}) };
    if ($scfg->{use_multipath}) {
        eval { PVE::Tools::run_command(['multipath','-r'], outfunc=>sub{}) };
    }
    eval { PVE::Tools::run_command(['udevadm','settle'], outfunc=>sub{}) };

    return undef;
}

# Return a hash describing available snapshots for this volume.
# Shape: { <snapname> => { id => <snapname>, timestamp => <epoch> }, ... }
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{dataset} . '/' . $zname;

    # TrueNAS REST: GET /zfs/snapshot  (returns an array of snapshots system-wide)
    # We'll filter to our dataset/zvol and normalize fields.
    my $list = _rest_call($scfg, 'GET', '/zfs/snapshot', undef) // [];

    my $snaps = {};
    for my $s (@$list) {
        my $name = $s->{name} // next;     # "pool/ds@sn"
        next unless $name =~ /^\Q$full\E\@(.+)$/;
        my $snapname = $1;

        # Try to extract creation time; fall back to 0 if not provided
        my $ts = 0;
        if (my $props = $s->{properties}) {
            # common layouts: { creation => { rawvalue => <epoch> } } or { creation => <string> }
            if (ref($props->{creation}) eq 'HASH') {
                $ts = int($props->{creation}{rawvalue} // 0);
            } elsif (defined $props->{creation} && $props->{creation} =~ /(\d{10})/) {
                $ts = int($1);
            }
        }

        $snaps->{$snapname} = { id => $snapname, timestamp => $ts };
    }

    return $snaps;
}

# List TrueNAS iSCSI targets (array of hashes; each has at least {id, name, ...}).
sub _tn_targets {
    my ($scfg) = @_;
    # NOTE: adjust the argument list if your _rest_call signature differs.
    my $list = _rest_call($scfg, 'GET', '/iscsi/target', undef);
    return $list // [];
}

sub _tn_extent_create($scfg, $zname, $full) {
    my $payload = {
        name => $zname, type => 'DISK', disk => "zvol/$full", insecure_tpc => JSON::PP::true,
    };
    return _api_call($scfg, 'iscsi.extent.create', [ $payload ],
        sub { _rest_call($scfg, 'POST', '/iscsi/extent', $payload) }
    );
}
sub _tn_extent_delete($scfg, $extent_id) {
    return _api_call($scfg, 'iscsi.extent.delete', [ $extent_id ],
        sub { _rest_call($scfg, 'DELETE', "/iscsi/extent/id/$extent_id") }
    );
}
sub _tn_targetextent_create($scfg, $target_id, $extent_id, $lun) {
    my $payload = { target => $target_id, extent => $extent_id, lunid => $lun };
    return _api_call($scfg, 'iscsi.targetextent.create', [ $payload ],
        sub { _rest_call($scfg, 'POST', '/iscsi/targetextent', $payload) }
    );
}
sub _tn_targetextent_delete($scfg, $tx_id) {
    return _api_call($scfg, 'iscsi.targetextent.delete', [ $tx_id ],
        sub { _rest_call($scfg, 'DELETE', "/iscsi/targetextent/id/$tx_id") }
    );
}

sub _current_lun_for_zname($scfg, $zname) {
    my $extents = _tn_extents($scfg) // [];
    my ($extent) = grep { ($_->{name} // '') eq $zname } @$extents;
    return undef if !$extent || !defined $extent->{id};

    my $target_id = _resolve_target_id($scfg);
    my $maps = _tn_targetextents($scfg) // [];
    my ($tx) = grep {
        ($_->{target} // -1) == $target_id
            && (($_->{extent} // -1) == $extent->{id})
    } @$maps;
    return defined($tx) ? $tx->{lunid} : undef;
}

# Robustly resolve the TrueNAS target id for a configured fully-qualified IQN.
sub _resolve_target_id {
    my ($scfg) = @_;

    my $want = $scfg->{target_iqn} // die "target_iqn not set in storage.cfg\n";

    # 1) Get targets; if empty, surface a clear diagnostic
    my $targets = _tn_targets($scfg) // [];
    if (!@$targets) {
        # Try to fetch the base name for a more helpful message
        my $global   = eval { _rest_call($scfg, 'GET', '/iscsi/global', undef) } // {};
        my $basename = $global->{basename} // '(unknown)';
        my $portal   = $scfg->{portal} // '(none)';

        my $msg = join("\n",
            "TrueNAS API returned no iSCSI targets.",
            "  iSCSI Base Name: $basename",
            "  Configured discovery portal: $portal",
            "",
            "Next steps:",
            "  1) On TrueNAS, ensure the iSCSI service is RUNNING.",
            "  2) In Shares -> Block (iSCSI) -> Portals, add/listen on $portal (or 0.0.0.0:3260).",
            "  3) From this Proxmox node, run:",
            "     iscsiadm -m discovery -t sendtargets -p $portal",
        );

        die "$msg\n";
    }

    # 2) Get global base name to construct full IQNs
    my $global = eval { _rest_call($scfg, 'GET', '/iscsi/global', undef) } // {};
    my $basename = $global->{basename} // '';

    # 3) Try several matching strategies
    my $found;
    for my $t (@$targets) {
        my $name = $t->{name} // '';
        my $full = ($basename && $name) ? "$basename:$name" : undef;

        # Some SCALE builds include 'iqn' per target; prefer exact match if present
        if (defined $t->{iqn} && $t->{iqn} eq $want) { $found = $t; last; }

        # Otherwise compare constructed IQN or target suffix
        if ($full && $full eq $want)             { $found = $t; last; }
        if ($name && $want =~ /:\Q$name\E$/)     { $found = $t; last; }
    }

    die "could not resolve target id for IQN $want (saw ".scalar(@$targets)." target(s))\n"
        if !$found;

    return $found->{id};
}

# ======== Portal normalization & reachability ========
sub _normalize_portal($p) {
    $p //= '';
    $p =~ s/^\s+|\s+$//g;
    return $p if !$p;
    # strip IPv6 brackets for by-path normalization
    $p = ($p =~ /^\[(.+)\]:(\d+)$/) ? "$1:$2" : $p;
    # strip trailing ",TPGT"
    $p =~ s/,\d+$//;
    return $p;
}
sub _probe_portal($portal) {
    my ($h,$port) = $portal =~ /^(.+):(\d+)$/;
    return 1 if !$h || !$port; # nothing to probe
    my $sock = IO::Socket::INET->new(PeerHost=>$h, PeerPort=>$port, Proto=>'tcp', Timeout=>5);
    die "iSCSI portal $portal is not reachable (TCP connect failed)\n" if !$sock;
    close $sock;
    return 1;
}

# ======== Safe wrappers for external commands ========
sub _try_run {
    my ($cmd, $errmsg) = @_;
    my $ok = 1;
    eval { run_command($cmd, errmsg => $errmsg, outfunc => sub {}, errfunc => sub {}); };
    if ($@) { carp (($errmsg // 'cmd failed').": $@"); $ok = 0; }
    return $ok;
}
sub _run_lines {
    my ($cmd) = @_;
    my @lines;
    eval {
        run_command($cmd,
            outfunc => sub { push @lines, $_[0] if defined $_[0] && $_[0] =~ /\S/; },
            errfunc => sub {});
    };
    return @lines; # return whatever we captured even on non-zero RC
}

# ======== Initiator: discovery/login and device resolution ========
sub _iscsi_login_all($scfg) {
    my $primary = _normalize_portal($scfg->{discovery_portal});
    my @extra = $scfg->{portals} ? map { _normalize_portal($_) } split(/\s*,\s*/, $scfg->{portals}) : ();

    # Preflight reachability
    _probe_portal($primary);
    _probe_portal($_) for @extra;

    # Discovery (don't die on non-zero)
    _try_run(['iscsiadm','-m','discovery','-t','sendtargets','-p',$primary], "iSCSI discovery failed (primary)");
    for my $p (@extra) {
        _try_run(['iscsiadm','-m','discovery','-t','sendtargets','-p',$p], "iSCSI discovery failed ($p)");
    }

    my $iqn = $scfg->{target_iqn};
    my @nodes = _run_lines(['iscsiadm','-m','node','-T',$iqn]);

    # Login to all discovered portals for this IQN; ensure node.startup=automatic
    for my $n (@nodes) {
        next unless $n =~ /^(\S+)\s+$iqn$/;
        my $portal = _normalize_portal($1);
        _try_run(['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.startup','-v','automatic'],
                 "iscsiadm update failed (node.startup)");
        if ($scfg->{chap_user} && $scfg->{chap_password}) {
            for my $cmd (
                ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.authmethod','-v','CHAP'],
                ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.username','-v',$scfg->{chap_user}],
                ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.password','-v',$scfg->{chap_password}],
            ) { _try_run($cmd, "iscsiadm CHAP update failed"); }
        }
        _try_run(['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'--login'],
                 "iscsiadm login failed ($portal)");
    }
    # attempt direct login for any extra portals not already in -m node
    for my $p (@extra) {
        _try_run(['iscsiadm','-m','node','-T',$iqn,'-p',$p,'--login'],
                 "iscsiadm login failed ($p)");
    }

    # Verify a session exists; if not, retry once
    my $have_session = 0;
    for my $line (_run_lines(['iscsiadm','-m','session'])) {
        if ($line =~ /\b\Q$iqn\E\b/) { $have_session = 1; last; }
    }
    if (!$have_session) {
        _try_run(['iscsiadm','-m','discovery','-t','sendtargets','-p',$primary], "iSCSI discovery retry");
        for my $p (@extra, $primary) {
            _try_run(['iscsiadm','-m','node','-T',$iqn,'-p',$p,'--login'], "iSCSI login retry ($p)");
        }
    }

    run_command(['udevadm','settle'], outfunc => sub {});
    usleep(250_000); # modest grace
}

sub _find_by_path_for_lun($scfg, $lun) {
    my $iqn = $scfg->{target_iqn};
    my $pattern = "-iscsi-$iqn-lun-$lun";
    opendir(my $dh, "/dev/disk/by-path") or die "cannot open /dev/disk/by-path\n";
    my @paths = grep { $_ =~ /^ip-.*\Q$pattern\E$/ } readdir($dh);
    closedir($dh);
    return "/dev/disk/by-path/$paths[0]" if @paths;
    return undef;
}

sub _dm_map_for_leaf($leaf) {
    # Map /dev/<leaf> (e.g. sdc) to its multipath /dev/mapper/<name> using sysfs
    my $sys = "/sys/block";
    opendir(my $dh, $sys) or return undef;
    while (my $e = readdir($dh)) {
        next unless $e =~ /^dm-\d+$/;
        my $slave = "$sys/$e/slaves/$leaf";
        next unless -e $slave;
        my $name = '';
        if (open my $fh, '<', "$sys/$e/dm/name") {
            chomp($name = <$fh> // ''); close $fh;
        }
        closedir($dh);
        return $name ? "/dev/mapper/$name" : "/dev/$e";
    }
    closedir($dh);
    return undef;
}

sub _logout_target_all_portals {
    my ($scfg) = @_;
    my $iqn = $scfg->{target_iqn};
    my @portals = map { s/^\s+|\s+$//gr } split(/\s*,\s*/, ($scfg->{portal}//''));
    for my $p (@portals) {
        eval { PVE::Tools::run_command(['iscsiadm','-m','node','-p',$p,'--targetname',$iqn,'--logout'], errfunc=>sub{}) };
        eval { PVE::Tools::run_command(['iscsiadm','-m','node','-p',$p,'--targetname',$iqn,'-o','delete'], errfunc=>sub{}) };
    }
}

sub _login_target_all_portals {
    my ($scfg) = @_;
    my $iqn = $scfg->{target_iqn};
    my @portals = map { s/^\s+|\s+$//gr } split(/\s*,\s*/, ($scfg->{portal}//''));

    for my $p (@portals) {
        eval {
            # Ensure node record exists & autostarts, then login
            PVE::Tools::run_command(['iscsiadm','-m','node','-p',$p,'--targetname',$iqn,'-o','new'], errfunc=>sub{});
            PVE::Tools::run_command(['iscsiadm','-m','node','-p',$p,'--targetname',$iqn,'--op','update','-n','node.startup','-v','automatic'], errfunc=>sub{});
            PVE::Tools::run_command(['iscsiadm','-m','node','-p',$p,'--targetname',$iqn,'--login'], errfunc=>sub{});
        };
    }

    # Refresh kernel & multipath views
    eval { PVE::Tools::run_command(['iscsiadm','-m','session','-R'], outfunc=>sub{}) };
    eval { PVE::Tools::run_command(['udevadm','settle'], outfunc=>sub{}) };
    if ($scfg->{use_multipath}) {
        eval { PVE::Tools::run_command(['multipath','-r'], outfunc=>sub{}) };
        eval { PVE::Tools::run_command(['udevadm','settle'], outfunc=>sub{}) };
    }
}

sub _device_for_lun($scfg, $lun) {
    # Wait briefly for by-path to appear if needed
    my $by;
    for (my $i = 1; $i <= 50; $i++) { # up to ~5s
        $by = _find_by_path_for_lun($scfg, $lun);
        last if $by && -e $by;
        run_command(['udevadm','settle'], outfunc => sub {});
        if ($i == 10 || $i == 20 || $i == 35) {
            _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan");
            run_command(['udevadm','settle'], outfunc => sub {});
        }
        usleep(100_000);
    }
    die "Could not locate by-path device for LUN $lun (IQN $scfg->{target_iqn})\n" if !$by || !-e $by;

    # Multipath preference
    if ($scfg->{use_multipath} && !$scfg->{use_by_path}) {
        my $real = abs_path($by);
        if ($real && $real =~ m{^/dev/([^/]+)$}) {
            my $leaf = $1; # e.g., sdc
            if (my $dm = _dm_map_for_leaf($leaf)) {
                return $dm; # /dev/mapper/<name> (or /dev/dm-*)
            }
        }
        return $by; # fallback to by-path
    }

    return $by; # by-path preferred or fallback
}

sub _zvol_name($vmid, $name) {
    $name //= 'disk-0';
    $name =~ s/[^a-zA-Z0-9._\-]+/_/g;
    return "vm-$vmid-$name";
}

# ======== Required storage interface ========
# volname format: vol-<zname>-lun<N>, where <zname> is usually vm-<vmid>-disk-<n>
sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^vol-([A-Za-z0-9:_\.\-]+)-lun(\d+)$/) {
        my ($zname, $lun) = ($1, $2);

        my $vmid;
        $vmid = $1 if $zname =~ m/^vm-(\d+)-/; # derive owner if named vm-<vmid>-...

        # return shape mimics other block plugins:
        # ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format, $lun)
        return ('images', $zname, $vmid, undef, undef, undef, 'raw', $lun);
    }

    die "unable to parse volname '$volname'\n";
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    die "snapshots not supported on raw iSCSI LUNs" if defined $snapname;
    my (undef, $zname, undef, undef, undef, undef, undef, $lun) = $class->parse_volname($volname);

    _iscsi_login_all($scfg);

    my $dev;
    eval { $dev = _device_for_lun($scfg, $lun); };
    if ($@ || !$dev) {
        # try to re-resolve LUN mapping from TrueNAS
        my $real_lun = eval { _current_lun_for_zname($scfg, $zname) };
        if (defined $real_lun && (!defined($lun) || $real_lun != $lun)) {
            $dev = _device_for_lun($scfg, $real_lun);
            # (optional) carp "LUN changed for $zname: $lun -> $real_lun; resolved $dev";
        } else {
            die $@ if $@; # bubble up original cause
            die "Could not locate device for LUN $lun (IQN $scfg->{target_iqn})\n";
        }
    }
    return ($dev, undef, 'images');
}

# Create a new VM disk (zvol + iSCSI extent + mapping) and hand it to Proxmox.
# Arguments (per PVE): ($class, $storeid, $scfg, $vmid, $fmt, $name, $size_bytes)
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "only raw is supported\n" if defined($fmt) && $fmt ne 'raw';
    die "invalid size\n"         if !defined($size) || $size <= 0;

    # Determine a disk name under our dataset: vm-<vmid>-disk-<n>
    my $zname = $name;
    if (!$zname) {
        # naive free name finder: vm-<vmid>-disk-0...999 (replace with your own helper if you have one)
        for (my $n = 0; $n < 1000; $n++) {
            my $candidate = "vm-$vmid-disk-$n";
            my $full = $scfg->{dataset} . '/' . $candidate;
            my $exists = eval { _tn_dataset_get($scfg, $full) };
            if ($@ || !$exists) { $zname = $candidate; last; }
        }
        die "unable to find free disk name\n" if !$zname;
    }

    my $full_ds = $scfg->{dataset} . '/' . $zname;

    # 1) Create the zvol (VOLUME) on TrueNAS with requested size (bytes)
    my $create_payload = {
        name    => $full_ds,
        type    => 'VOLUME',
        volsize => int($size),
        # optionally: volblocksize => '16K', sparse => JSON::true
    };
    _api_call(
        $scfg,
        'pool.dataset.create',
        [ $create_payload ],
        sub { _rest_call($scfg, 'POST', '/pool/dataset', $create_payload) },
    );

    # 2) Create an iSCSI extent for that zvol (device-backed)
    # TrueNAS expects a 'disk' like "zvol/<pool>/<zname>"
    my $zvol_path = 'zvol/' . $full_ds;
    my $extent_payload = {
        name => $zname,
        type => 'DISK',
        disk => $zvol_path,
        insecure_tpc => JSON::true, # typical default for modern OS initiators
    };
    my $extent_id;
    {
        my $ext = _api_call(
            $scfg,
            'iscsi.extent.create',
            [ $extent_payload ],
            sub { _rest_call($scfg, 'POST', '/iscsi/extent', $extent_payload) },
        );
        # normalize id from either WS result or REST (hashref)
        $extent_id = ref($ext) eq 'HASH' ? $ext->{id} : $ext;
    }
    die "failed to create extent for $zname\n" if !defined $extent_id;

    # 3) Map extent to our shared target (targetextent.create); lunid is auto-assigned if not given
    my $target_id = _resolve_target_id($scfg);
    my $tx_payload = { target => $target_id, extent => $extent_id };
    my $tx = _api_call(
        $scfg,
        'iscsi.targetextent.create',
        [ $tx_payload ],
        sub { _rest_call($scfg, 'POST', '/iscsi/targetextent', $tx_payload) },
    );

    # 4) Find the lunid that TrueNAS assigned for this (target, extent)
    my $maps = _tn_targetextents($scfg) // [];
    my ($tx_map) = grep {
        ($_->{target}//-1) == $target_id && ($_->{extent}//-1) == $extent_id
    } @$maps;
    my $lun = $tx_map ? $tx_map->{lunid} : undef;
    die "could not determine assigned LUN for $zname\n" if !defined $lun;

    # 5) Refresh initiator view on this node (login already exists; rescan & multipath)
    eval { _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan failed"); };
    if ($scfg->{use_multipath}) {
        eval { _try_run(['multipath','-r'], "multipath reload failed"); };
    }
    eval { run_command(['udevadm','settle'], outfunc => sub {}); };

    # 6) Return our encoded volname so Proxmox can store it in the VM config
    # We use the same naming scheme we handle elsewhere: vol-<zname>-lun<lun>
    my $volname = "vol-$zname-lun$lun";
    return $volname;
}


# Return size in bytes (scalar), or (size_bytes, format) in list context
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my (undef, $zname, undef, undef, undef, undef, $fmt, undef) =
        $class->parse_volname($volname);
    $fmt //= 'raw';

    my $full = $scfg->{dataset} . '/' . $zname;
    my $ds = _tn_dataset_get($scfg, $full) // {};
    my $norm = sub {
        my ($v) = @_;
        return 0 if !defined $v;
        return $v if !ref($v);
        return $v->{parsed} // $v->{raw} // 0 if ref($v) eq 'HASH';
        return 0;
    };
    my $bytes = $norm->($ds->{volsize});
    die "volume_size_info: missing volsize for $full\n" if !$bytes;

    return wantarray ? ($bytes, $fmt) : $bytes;
}

# Delete a VM disk: remove iSCSI mapping+extent on TrueNAS, delete zvol, and
# clean up the initiator (flush multipath, rescan, optionally logout if no LUNs remain).
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    die "snapshots not supported on iSCSI zvols\n" if $isBase;
    die "unsupported format '$format'\n" if defined($format) && $format ne 'raw';

    my (undef, $zname, undef, undef, undef, undef, undef, $lun) = $class->parse_volname($volname);
    my $full_ds = $scfg->{dataset} . '/' . $zname;

    # Best-effort: flush local multipath path of this WWID (ignore "not a multipath device")
    if ($scfg->{use_multipath}) {
        eval {
            my ($dev) = $class->path($scfg, $volname, $storeid, undef);
            if ($dev) {
                my $leaf = Cwd::abs_path($dev);
                my $wwid = '';
                eval {
                    PVE::Tools::run_command(
                        ['/lib/udev/scsi_id','-g','-u','-d',$leaf],
                        outfunc => sub { $wwid .= $_[0]; }, errfunc => sub {}
                    );
                };
                chomp($wwid) if $wwid;
                if ($wwid) {
                    eval { PVE::Tools::run_command(['multipath','-f',$wwid], outfunc=>sub{}, errfunc=>sub{}) };
                }
            }
        };
        # ignore any multipath flush errors here
    }

    # Resolve target/extent/mapping on TrueNAS
    my $target_id = _resolve_target_id($scfg);
    my $extents   = _tn_extents($scfg) // [];
    my ($extent)  = grep { ($_->{name}//'') eq $zname } @$extents;
    my $maps      = _tn_targetextents($scfg) // [];
    my ($tx)      = ($extent && $target_id)
                  ? grep { (($_->{target}//-1) == $target_id) && (($_->{extent}//-1) == $extent->{id}) } @$maps
                  : ();

    my $in_use = sub { my ($e)=@_; return ($e && $e =~ /in use/i) ? 1 : 0; };
    my $need_force_logout = 0;

    # 1) Delete targetextent mapping
    if ($tx && defined $tx->{id}) {
        my $id = $tx->{id};
        my $ok = eval {
            _api_call($scfg,'iscsi.targetextent.delete',[ $id ],
                sub { _rest_call($scfg,'DELETE',"/iscsi/targetextent/id/$id",undef) });
            1;
        };
        if (!$ok) {
            my $err = $@ // '';
            if ($scfg->{force_delete_on_inuse} && $in_use->($err)) {
                $need_force_logout = 1;
            } else {
                warn "warning: delete targetextent id=$id failed: $err";
            }
        }
    }

    # 2) Delete extent (may still be mapped if step 1 failed)
    if ($extent && defined $extent->{id}) {
        my $eid = $extent->{id};
        my $ok = eval {
            _api_call($scfg,'iscsi.extent.delete',[ $eid ],
                sub { _rest_call($scfg,'DELETE',"/iscsi/extent/id/$eid",undef) });
            1;
        };
        if (!$ok) {
            my $err = $@ // '';
            if ($scfg->{force_delete_on_inuse} && $in_use->($err)) {
                $need_force_logout = 1;
            } else {
                warn "warning: delete extent id=$eid failed: $err";
            }
        }
    }

    # 3) If TrueNAS reported "in use" and force_delete_on_inuse=1, temporarily logout → retry
    if ($need_force_logout) {
        _logout_target_all_portals($scfg);

        # Retry mapping delete
        if ($tx && defined $tx->{id}) {
            my $id = $tx->{id};
            eval {
                _api_call($scfg,'iscsi.targetextent.delete',[ $id ],
                    sub { _rest_call($scfg,'DELETE',"/iscsi/targetextent/id/$id",undef) });
            } or warn "warning: delete targetextent (retry) id=$id failed: $@";
        }

        # Retry extent delete (re-query extent by name)
        $extents = _tn_extents($scfg) // [];
        ($extent) = grep { ($_->{name}//'') eq $zname } @$extents;
        if ($extent && defined $extent->{id}) {
            my $eid = $extent->{id};
            eval {
                _api_call($scfg,'iscsi.extent.delete',[ $eid ],
                    sub { _rest_call($scfg,'DELETE',"/iscsi/extent/id/$eid",undef) });
            } or warn "warning: delete extent (retry) id=$eid failed: $@";
        }
    }

    # 4) Delete the zvol dataset (recursive/force as safety)
    eval {
        my $id = URI::Escape::uri_escape($full_ds);
        my $payload = { recursive => JSON::true, force => JSON::true };
        _api_call($scfg,'pool.dataset.delete',[ $full_ds, $payload ],
            sub { _rest_call($scfg,'DELETE',"/pool/dataset/id/$id",$payload) });
    } or warn "warning: delete dataset $full_ds failed: $@";

    # 5) Re-login & refresh (only if we did the forced logout)
    if ($need_force_logout) {
        _login_target_all_portals($scfg);
    } else {
        eval { PVE::Tools::run_command(['iscsiadm','-m','session','-R'], outfunc=>sub{}) };
        if ($scfg->{use_multipath}) {
            eval { PVE::Tools::run_command(['multipath','-r'], outfunc=>sub{}) };
        }
        eval { PVE::Tools::run_command(['udevadm','settle'], outfunc=>sub{}) };
    }

    # Optional: logout if no LUNs remain for this target on this node
    if ($scfg->{logout_on_free}) {
        eval {
            if (_session_has_no_luns($scfg)) {
                _logout_target_all_portals($scfg);
            }
        };
        warn "warning: logout_on_free check failed: $@" if $@;
    }

    return undef;
}

# Heuristic: returns true if our target session shows no "Attached SCSI devices" with LUNs.
# Conservative: we only logout if we see a session for the IQN AND there are zero LUNs listed.
sub _session_has_no_luns {
    my ($target_iqn) = @_;
    my $buf = '';
    eval {
        run_command(
            ['iscsiadm','-m','session','-P','3'],
            outfunc => sub { $buf .= $_[0]; }, errfunc => sub {}
        );
    };
    return 0 if $@; # if we cannot inspect, do nothing
    my @stanzas = split(/\n\s*\n/s, $buf);
    for my $s (@stanzas) {
        next unless $s =~ /Target:\s*\Q$target_iqn\E\b/s;
        # If any "Lun:" lines remain, do not logout
        return 0 if $s =~ /Lun:\s*\d+/;
        # If section exists and shows no Lun lines, safe to logout
        return 1;
    }
    # No session for this target found => nothing to logout
    return 0;
}

# ======== List VM disks for the storage (GUI/CLI content) ========
# Returns an arrayref of hashes: { volid, size, format, vmid? }
# Respects $vmid (owner filter) and $vollist (explicit include list).
sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = [];

    # ---- cache TrueNAS state for this call chain ----
    my $extents = $cache->{tn_extents} //= (_tn_extents($scfg) // []);
    my $maps    = $cache->{tn_targetextents} //= (_tn_targetextents($scfg) // []);
    my $target_id = _resolve_target_id($scfg);

    # Index extents by id for quick lookups
    my %extent_by_id = map { ($_->{id} // -1) => $_ } @$extents;

    # Optional include filter (vollist is "<storeid>:<volname>" entries)
    my %want;
    if ($vollist && ref($vollist) eq 'ARRAY' && @$vollist) {
        %want = map { $_ => 1 } @$vollist;
    }

    # Normalizer for volsize/typed fields ({parsed}|{raw}|scalar)
    my $norm = sub {
        my ($v) = @_;
        return 0 if !defined $v;
        return $v if !ref($v);
        return $v->{parsed} // $v->{raw} // 0 if ref($v) eq 'HASH';
        return 0;
    };

    # Walk all mappings for our shared target; each mapping -> one LUN for an extent
    MAPPING: for my $tx (@$maps) {
        next MAPPING unless (($tx->{target} // -1) == $target_id);

        my $eid = $tx->{extent};
        my $e   = $extent_by_id{$eid} // next MAPPING;

        # We name extents with the zvol name (e.g., vm-<vmid>-disk-<n>)
        my $zname = $e->{name} // '';
        next MAPPING if !$zname;

        # Optional: constrain to our dataset by verifying zvol exists under dataset
        my $ds_full = "$scfg->{dataset}/$zname";

        # Determine assigned LUN id
        my $lun = $tx->{lunid};
        next MAPPING if !defined $lun;

        # Owner (vmid) from our naming convention
        my $owner;
        $owner = $1 if $zname =~ /^vm-(\d+)-/;

        # Honor $vmid filter if owner is known
        if (defined $vmid && defined $owner && $owner != $vmid) {
            next MAPPING;
        }

        # Compose plugin volname + volid
        my $volname = "vol-$zname-lun$lun";
        my $volid   = "$storeid:$volname";

        # Honor explicit include filter
        if (%want && !$want{$volid}) {
            next MAPPING;
        }

        # Ask TrueNAS for the zvol to get current size (bytes)
        my $ds = eval { _tn_dataset_get($scfg, $ds_full) } // {};
        my $size = $norm->($ds->{volsize}); # bytes (0 if missing)

        # Format is always raw for block iSCSI zvols
        my %entry = (
            volid  => $volid,
            size   => $size,
            format => 'raw',
        );
        $entry{vmid} = int($owner) if defined $owner;

        push @$res, \%entry;
    }

    return $res;
}


# ======== status(): report dataset capacity correctly ========
# total = quota (if set) else (written/used + available)
# avail = (quota - written/used) when quota present, else dataset available
# used  = dataset "written" (preferred), fallback to "used"
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    my $active = 1;
    my ($total, $avail, $used) = (0,0,0);

    eval {
        my $ds = _tn_dataset_get($scfg, $scfg->{dataset});

        my $norm = sub {
            my ($v) = @_;
            return 0 if !defined $v;
            return $v if !ref($v);
            return $v->{parsed} // $v->{raw} // 0 if ref($v) eq 'HASH';
            return 0;
        };

        my $quota     = $norm->($ds->{quota});        # bytes; 0 = no quota
        my $available = $norm->($ds->{available});    # bytes
        $used = $norm->($ds->{written});
        $used = $norm->($ds->{used}) if !$used;

        if ($quota && $quota > 0) {
            $total = $quota;
            my $free = $quota - $used;
            $avail = $free > 0 ? $free : 0;
        } else {
            $avail = $available;
            $total = $used + $avail;
        }
    };

    if ($@) {
        # Conservative fallback to avoid blocking VM starts if stats fail
        $total ||= 1024*1024*1024*1024; # 1 TiB
        $avail ||= 900*1024*1024*1024;  # 900 GiB
        $used  ||= $total - $avail;
    }

    return ($total, $avail, $used, $active);
}

sub activate_storage   { return 1; }
sub deactivate_storage { return 1; }

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    die "snapshots not supported" if $snapname;
    _iscsi_login_all($scfg);
    if ($scfg->{use_multipath}) { run_command(['multipath','-r'], outfunc => sub {}); }
    run_command(['udevadm','settle'], outfunc => sub {});
    usleep(150_000);
    return 1;
}
sub deactivate_volume { return 1; }

sub volume_snapshot           { die "snapshot not supported"; }
sub volume_snapshot_delete    { die "snapshot not supported"; }
sub volume_snapshot_rollback  { die "snapshot not supported"; }
sub clone_image               { die "clone not supported"; }
sub create_base               { die "base images not supported"; }

1;
