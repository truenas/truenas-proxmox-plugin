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
        content => [ { images => 1, none => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],
        'sensitive-properties' => { api_key => 1, chap_password => 1 },
        select_existing => 1,
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
    my ($class, $scfg, $feature, @more) = @_;
    # Enable disk grow for raw iSCSI-backed images
    return 1 if defined($feature) && $feature eq 'resize';
    return undef;
}

# --- implement grow-only resize ---
sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $new_kib, @rest) = @_;

    # 1) Parse current volume identity
    my (undef, $zname, undef, undef, undef, undef, $fmt, $lun) = $class->parse_volname($volname);
    die "only raw is supported\n" if defined($fmt) && $fmt ne 'raw';

    my $full = $scfg->{dataset} . '/' . $zname;

    # 2) Discover current volsize and volblocksize (bytes)
    my $ds = _tn_dataset_get($scfg, $full); # may return { volsize => {...}, volblocksize => {...} }
    my $norm = sub {
        my ($v) = @_;
        return 0 if !defined $v;
        return $v if !ref($v);
        return $v->{parsed} // $v->{raw} // 0 if ref($v) eq 'HASH';
        return 0;
    };
    my $cur_bytes = $norm->($ds->{volsize});
    my $bs_bytes  = $norm->($ds->{volblocksize});
    $bs_bytes = 0 if !$bs_bytes; # if unknown, we’ll skip alignment check

    # 3) Calculate desired new size (bytes) from KiB, enforce grow-only & alignment
    my $req_bytes = int($new_kib) * 1024;
    die "shrink not supported (current=$cur_bytes requested=$req_bytes)\n"
        if $req_bytes <= $cur_bytes;

    # Align up to volblocksize if available
    if ($bs_bytes && $bs_bytes > 0) {
        my $rem = $req_bytes % $bs_bytes;
        $req_bytes += ($bs_bytes - $rem) if $rem;
    }

    # 4) Grow the zvol on TrueNAS
    _tn_dataset_resize($scfg, $full, $req_bytes);

    # 5) Refresh initiator view: rescan iSCSI session(s) and multipath (if enabled)
    _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan failed");
    if ($scfg->{use_multipath}) {
        _try_run(['multipath','-r'], "multipath map reload failed");
    }
    run_command(['udevadm','settle'], outfunc => sub { });
    Time::HiRes::usleep(250_000);

    return $new_kib; # Proxmox expects KiB back
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

# ======== Target resolution (IQN or short Target Name) ========
sub _resolve_target_id {
    my ($scfg) = @_;
    my $want = $scfg->{target_iqn} // die "target_iqn not set\n";
    my $short = $want; $short =~ s/^.*://;
    my $targets = _tn_get_target($scfg);
    if (!ref($targets) || !@$targets) {
        my $g = eval { _tn_global($scfg) } // {};
        my $basename = $g->{basename} // '(unknown)';
        my $portal = $scfg->{discovery_portal} // '(unset)';
        die
          "TrueNAS API returned no iSCSI targets.\n".
          " - iSCSI Base Name: $basename\n".
          " - Configured discovery portal: $portal\n".
          "Next steps:\n".
          " 1) On TrueNAS, ensure the iSCSI service is RUNNING.\n".
          " 2) In Shares → Block (iSCSI) → Portals, add/listen on $portal (or 0.0.0.0:3260).\n".
          " 3) From this Proxmox node, run: iscsiadm -m discovery -t sendtargets -p $portal\n";
    }
    my ($t) = grep { defined($_->{name}) && ( $_->{name} eq $want || $_->{name} eq $short ) } @$targets;
    $t //= (grep { defined($_->{iqn}) && $_->{iqn} eq $want } @$targets)[0];
    if (!$t) {
        my @names = map { $_->{name} // '(unnamed)' } @$targets;
        die "Target '$want' not found. Available targets: ".join(', ', @names)."\n";
    }
    return $t->{id};
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
sub parse_volname {
    my ($class, $volname) = @_;
    if ($volname =~ m!^vol-([a-zA-Z0-9._\-]+)-lun(\d+)$!) {
        my ($zname, $lun) = ($1, int($2));
        return ('images', $zname, undef, undef, undef, undef, 'raw', $lun);
    }
    die "unable to parse truenas volume name '$volname'\n";
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

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size_kib) = @_;
    die "only raw is supported" if defined($fmt) && $fmt ne 'raw';

    my $zname = _zvol_name($vmid, $name);
    my $full  = $scfg->{dataset} . '/' . $zname;

    # 1) Create zvol (bytes + thin toggle)
    _tn_dataset_create($scfg, $full, $size_kib, $scfg->{zvol_blocksize});

    # 2) Create extent for the zvol
    my $extent = _tn_extent_create($scfg, $zname, $full);
    my $extent_id = ref($extent) eq 'HASH' && exists $extent->{id} ? $extent->{id} : $extent;

    # 3) Map to shared target at next free LUN
    my $target_id = _resolve_target_id($scfg);
    my $maps = _tn_targetextents($scfg);
    my %used = map { (($_->{lunid} // -1) => 1) } grep { $_->{target} == $target_id } @$maps;
    my $lun; for my $cand (0..4095) { if (!$used{$cand}) { $lun = $cand; last; } }
    die "No free LUN on target id=$target_id" if !defined $lun;
    _tn_targetextent_create($scfg, $target_id, $extent_id, $lun);

    return "vol-$zname-lun$lun";
}

# Return ($size_bytes, $format)
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    # Parse zvol identity from our encoded volname "vol-<zname>-lun<N>"
    my (undef, $zname, undef, undef, undef, undef, $fmt, undef) =
        $class->parse_volname($volname);
    $fmt //= 'raw';

    # Query TrueNAS for zvol attributes: volsize is in bytes (may be in a hash with parsed/raw)
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

    return ($bytes, $fmt);
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{dataset} . '/' . $zname;

    my $target_id;
    eval { $target_id = _resolve_target_id($scfg); };

    my $extents = _tn_extents($scfg);
    my ($extent) = grep { $_->{name} && $_->{name} eq $zname } @$extents;
    my $extent_id = $extent ? $extent->{id} : undef;

    if (defined $target_id && defined $extent_id) {
        my $maps = _tn_targetextents($scfg);
        my ($tx) = grep { $_->{target} == $target_id && (($_->{extent} // -1) == $extent_id) } @$maps;
        _tn_targetextent_delete($scfg, $tx->{id}) if $tx && defined $tx->{id};
    }

    _tn_extent_delete($scfg, $extent_id) if defined $extent_id;
    _tn_dataset_delete($scfg, $full);
    return 1;
}

# ======== List VM disks for the storage (GUI/CLI content) ========
# Returns an arrayref of entries: { volid, size (bytes), format, vmid? }.
sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache, $errors) = @_;

    my $out = [];

    # Optional filter: allow-list of specific volids
    my %want = ();
    if (defined $vollist && ref($vollist) eq 'ARRAY') {
        %want = map { $_ => 1 } @$vollist;
    }

    my $norm_bytes = sub {
        my ($v) = @_;
        return 0 if !defined $v;
        return $v if !ref($v);
        return $v->{parsed} // $v->{raw} // 0 if ref($v) eq 'HASH';
        return 0;
    };

    my $target_id = eval { _resolve_target_id($scfg) };
    if ($@) {
        push(@$errors, "target resolution failed: $@")
            if defined($errors) && ref($errors) eq 'ARRAY';
        return $out;
    }

    # extent_id -> LUN for our shared target
    my $maps = _tn_targetextents($scfg) // [];
    my %lun_for_ext = map { $_->{extent} => ($_->{lunid} // 0) }
                      grep { ($_->{target} // -1) == $target_id } @$maps;

    # All extents; filter to zvols under our dataset and mapped to our target
    my $extents = _tn_extents($scfg) // [];
  EXT: for my $e (@$extents) {
        next EXT if ($e->{type} // '') ne 'DISK';

        my $disk = $e->{disk} // '';  # "zvol/<dataset>/<zname>"
        next EXT if $disk !~ m{^zvol/\Q$scfg->{dataset}\E/};

        my $zname     = $e->{name} // next EXT;
        my $extent_id = $e->{id};
        my $lun       = $lun_for_ext{$extent_id};
        next EXT if !defined $lun; # not mapped to our target

        # STRICT filter: only include real VM disks "vm-<id>-..."
        next EXT if $zname !~ /^vm-(\d+)-/;
        my $vid = int($1);
        if (defined $vmid && $vid != $vmid) { next EXT; }

        my $volname = "vol-$zname-lun$lun";
        if (%want && !$want{"$storeid:$volname"}) { next EXT; }

        # Fetch capacity (bytes) from the zvol dataset
        my $full_ds = "$scfg->{dataset}/$zname";
        my $ds = eval { _tn_dataset_get($scfg, $full_ds) } // {};
        my $size = $norm_bytes->($ds->{volsize}) || 0;

        # Register the volume
        push @$out, {
            volid  => "$storeid:$volname",
            size   => $size,
            format => 'raw',
            vmid   => $vid,
        };
    }

    return $out;
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
