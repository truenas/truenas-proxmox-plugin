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

use PVE::Tools qw(run_command trim);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

# ======== Storage plugin identity ========

sub api  { return 11; }                    # storage plugin API version
sub type { return 'truenasplugin'; }       # storage.cfg "type"

sub plugindata {
    return {
        content => [ { images => 1, none => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],
        'sensitive-properties' => { api_key => 1, chap_password => 1 },
        select_existing => 1,
    };
}

# ======== Config schema (only plugin-specific keys here!) ========

sub properties {
    return {
        # Transport & connection
        api_transport => {
            description => "API transport: 'ws' (JSON-RPC) or 'rest'.",
            type        => 'string',
            optional    => 1,
        },
        api_host => {
            description => "TrueNAS hostname or IP.",
            type        => 'string',
            format      => 'pve-storage-server',
        },
        api_key => {
            description => "TrueNAS user-linked API key.",
            type        => 'string',
        },
        api_scheme => {
            description => "wss/ws for WS, https/http for REST (defaults: wss/https).",
            type        => 'string',
            optional    => 1,
        },
        api_port => {
            description => "TCP port (defaults: 443 for wss/https, 80 for ws/http).",
            type        => 'integer',
            optional    => 1,
        },
        api_insecure => {
            description => "Skip TLS certificate verification.",
            type        => 'boolean',
            optional    => 1,
            default     => 0,
        },
        prefer_ipv4 => {
            description => "Prefer IPv4 (A records) when resolving api_host.",
            type        => 'boolean',
            optional    => 1,
            default     => 1,
        },

        # Placement
        dataset => {
            description => "Parent dataset for zvols (e.g. tank/proxmox).",
            type        => 'string',
        },
        zvol_blocksize => {
            description => "ZVOL volblocksize (e.g. 16K, 64K).",
            type        => 'string',
            optional    => 1,
        },

        # iSCSI target & portals
        target_iqn => {
            description => "Shared iSCSI Target IQN on TrueNAS (or target's short name).",
            type        => 'string',
        },
        discovery_portal => {
            description => "Primary SendTargets portal (IP[:port] or [IPv6]:port).",
            type        => 'string',
        },
        portals => {
            description => "Comma-separated additional portals.",
            type        => 'string',
            optional    => 1,
        },

        # Initiator pathing
        use_multipath => { type => 'boolean', optional => 1, default => 1 },
        use_by_path   => { type => 'boolean', optional => 1, default => 0 },
        ipv6_by_path  => {
            description => "Normalize IPv6 by-path names (enable only if using IPv6 portals).",
            type        => 'boolean',
            optional    => 1,
            default     => 0,   # default IPv4 behaviors
        },

        # CHAP (optional)
        chap_user     => { type => 'string', optional => 1 },
        chap_password => { type => 'string', optional => 1 },

        # Thin provisioning toggle (plugin-specific to avoid schema collision)
        tn_sparse => {
            description => "Create thin-provisioned zvols on TrueNAS (maps to TrueNAS 'sparse').",
            type        => 'boolean',
            optional    => 1,
            default     => 1,
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
        target_iqn        => { fixed => 1 },
        discovery_portal  => { fixed => 1 },
        portals           => { optional => 1 },

        # Initiator
        use_multipath => { optional => 1 },
        use_by_path   => { optional => 1 },
        ipv6_by_path  => { optional => 1 },

        # CHAP
        chap_user     => { optional => 1 },
        chap_password => { optional => 1 },

        # Thin toggle
        tn_sparse     => { optional => 1 },
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
    my $port   = $scfg->{api_port} || ($scheme eq 'https' ? 443 : 80);
    return "$scheme://$scfg->{api_host}:$port/api/v2.0";
}

sub _rest_call($scfg, $method, $path, $payload=undef) {
    my $ua  = _ua($scfg);
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
    if (!$scheme)                  { $scheme = 'wss'; }
    elsif ($scheme =~ /^https$/i)  { $scheme = 'wss'; }
    elsif ($scheme =~ /^http$/i)   { $scheme = 'ws';  }

    my $port = $scfg->{api_port} || (($scheme eq 'wss') ? 443 : 80);
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
            PeerHost       => $peer,
            PeerPort       => $port,
            SSL_verify_mode=> $scfg->{api_insecure} ? 0x00 : 0x02,
            SSL_hostname   => $host,
            Timeout        => 15,
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

    my $accept = ($resp =~ /Sec-WebSocket-Accept:\s*(\S+)/i) ? $1 : '';
    my $expect = encode_base64(sha1($key_b64 . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), '');
    die "WebSocket handshake invalid accept key" if lc($accept) ne lc($expect);

    # Authenticate with API key (JSON-RPC)
    my $conn = { sock => $sock, next_id => 1 };
    _ws_rpc($conn, {
        jsonrpc => "2.0", id => $conn->{next_id}++,
        method  => "auth.login_with_api_key",
        params  => [ $scfg->{api_key} ],
    }) or die "TrueNAS auth.login_with_api_key failed";

    return $conn;
}

# ---- WS framing (text only, no compression/fragmentation) ----

# helper: byte-wise XOR masking (no numeric warnings)
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
    my $maskbit    = 0x80; # client must mask

    my $len = length($payload);
    my $hdr = pack('C', $fin_opcode);
    my $lenfield;
    if    ($len <= 125)    { $lenfield = pack('C',     $maskbit | $len); }
    elsif ($len <= 0xFFFF) { $lenfield = pack('C n',   $maskbit | 126, $len); }
    else                   { $lenfield = pack('C Q>',  $maskbit | 127, $len); }

    my $mask   = join '', map { chr(int(rand(256))) } 1..4;
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
    my $masked = ($b2 & 0x80) ? 1 : 0;  # server MUST NOT mask
    my $len = ($b2 & 0x7f);

    if ($len == 126) {
        my $ext; _ws_read_exact($sock, \$ext, 2) or die "WS len16 read fail";
        $len = unpack('n', $ext);
    } elsif ($len == 127) {
        my $ext; _ws_read_exact($sock, \$ext, 8) or die "WS len64 read fail";
        $len = unpack('Q>', $ext);
    }

    my $mask_key = '';
    if ($masked) {
        _ws_read_exact($sock, \$mask_key, 4) or die "WS unexpected mask";
    }

    my $payload = '';
    _ws_read_exact($sock, \$payload, $len) or die "WS payload read fail";

    if ($masked) {
        $payload = _xor_mask($payload, $mask_key);
    }
    return $payload;
}

sub _ws_rpc($conn, $obj) {
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
                jsonrpc => "2.0", id => 1, method => $ws_method, params => $ws_params || [],
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
    return _api_call($scfg, 'iscsi.target.query', [],
        sub { _rest_call($scfg, 'GET', '/iscsi/target') }
    );
}
sub _tn_targetextents($scfg) {
    return _api_call($scfg, 'iscsi.targetextent.query', [],
        sub { _rest_call($scfg, 'GET', '/iscsi/targetextent') }
    );
}
sub _tn_extents($scfg) {
    return _api_call($scfg, 'iscsi.extent.query', [],
        sub { _rest_call($scfg, 'GET', '/iscsi/extent') }
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

# ======== Target resolution (IQN or short Target Name) ========

sub _resolve_target_id {
    my ($scfg) = @_;
    my $want  = $scfg->{target_iqn} // die "target_iqn not set\n";
    my $short = $want; $short =~ s/^.*://;  # tail after last ':'

    my $targets = _tn_get_target($scfg);
    my ($t) = grep { defined($_->{name}) && ( $_->{name} eq $want || $_->{name} eq $short ) } @$targets;
    $t //= (grep { defined($_->{iqn}) && $_->{iqn} eq $want } @$targets)[0];

    if (!$t) {
        my @names = map { $_->{name} // '(unnamed)' } @$targets;
        die "Target '$want' not found. Available targets: ".join(', ', @names)."\n";
    }
    return $t->{id};
}

# ======== Initiator: discovery/login and device resolution ========

sub _normalize_portal($p) {
    $p =~ s/^\s+|\s+$//g;
    return $p if !$p;
    $p =~ /^\[(.+)\]:(\d+)$/ ? "$1:$2" : $p; # strip IPv6 brackets for by-path
}

sub _iscsi_login_all($scfg) {
    my $primary = $scfg->{discovery_portal};
    my @extra   = $scfg->{portals} ? map { _normalize_portal($_) } split(/\s*,\s*/, $scfg->{portals}) : ();

    run_command(['iscsiadm','-m','discovery','-t','sendtargets','-p',$primary],
        errmsg => "iSCSI discovery failed", outfunc => sub {});
    my $iqn = $scfg->{target_iqn};

    my @nodes;
    run_command(['iscsiadm','-m','node','-T',$iqn], errmsg => "iscsiadm nodes failed", outfunc => sub {
        push @nodes, $_[0] if $_[0] =~ /\S/;
    });

    for my $n (@nodes) {
        next unless $n =~ /^(\S+)\s+$iqn$/;
        my $portal = $1;
        run_command(['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.startup','-v','automatic'],
            errmsg => "iscsiadm update failed", outfunc => sub {});
        if ($scfg->{chap_user} && $scfg->{chap_password}) {
            for my $cmd (
                ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.authmethod','-v','CHAP'],
                ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.username','-v',$scfg->{chap_user}],
                ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.password','-v',$scfg->{chap_password}],
            ) { run_command($cmd, errmsg => "iscsiadm CHAP update failed", outfunc => sub {}); }
        }
        run_command(['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'--login'],
            errmsg => "iscsiadm login failed", outfunc => sub {});
    }

    for my $p (@extra) {
        run_command(['iscsiadm','-m','discovery','-t','sendtargets','-p',$p],
            errmsg => "iSCSI discovery failed", outfunc => sub {});
        run_command(['iscsiadm','-m','node','-T',$iqn,'-p',$p,'--login'],
            errmsg => "iSCSI login failed", outfunc => sub {});
    }
}

sub _device_for_lun($scfg, $lun) {
    run_command(['udevadm','settle'], outfunc => sub {});
    my $iqn = $scfg->{target_iqn};

    if ($scfg->{use_multipath} && !$scfg->{use_by_path}) {
        my $mp = '';
        run_command(['multipath','-ll'], outfunc => sub {
            my $line = $_[0];
            if ($line =~ /(dm-\d+)/ && $line =~ /\Q$iqn\E/) { $mp = "/dev/$1"; }
        });
        return $mp if $mp;
    }

    my $pattern = "-iscsi-$iqn-lun-$lun";
    opendir(my $dh, "/dev/disk/by-path") or die "cannot open /dev/disk/by-path\n";
    my @paths = grep { $_ =~ /^ip-.*\Q$pattern\E$/ } readdir($dh);
    closedir($dh);
    die "Could not locate by-path device for LUN $lun (IQN $iqn)\n" if !@paths;
    return "/dev/disk/by-path/$paths[0]";
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
    my (undef, undef, undef, undef, undef, undef, undef, $lun) = $class->parse_volname($volname);
    _iscsi_login_all($scfg);
    my $dev = _device_for_lun($scfg, $lun);
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
    my %used = map { ($_->{lunid} // -1) => 1 } grep { $_->{target} == $target_id } @$maps;
    my $lun; for my $cand (0..4095) { if (!$used{$cand}) { $lun = $cand; last; } }
    die "No free LUN on target id=$target_id" if !defined $lun;

    _tn_targetextent_create($scfg, $target_id, $extent_id, $lun);
    return "vol-$zname-lun$lun";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{dataset} . '/' . $zname;

    # Resolve target id (accept IQN or short name), but continue best-effort if missing
    my $target_id;
    eval { $target_id = _resolve_target_id($scfg); };

    # Find extent id by our zvol name
    my $extents = _tn_extents($scfg);
    my ($extent) = grep { $_->{name} && $_->{name} eq $zname } @$extents;
    my $extent_id = $extent ? $extent->{id} : undef;

    # Remove targetextent association
    if (defined $target_id && defined $extent_id) {
        my $maps = _tn_targetextents($scfg);
        my ($tx) = grep { $_->{target} == $target_id && ($_->{extent} // -1) == $extent_id } @$maps;
        _tn_targetextent_delete($scfg, $tx->{id}) if $tx && defined $tx->{id};
    }

    _tn_extent_delete($scfg, $extent_id) if defined $extent_id;
    _tn_dataset_delete($scfg, $full);

    return 1;
}

sub status { return (0,0,0,1); }
sub activate_storage { return 1; }
sub deactivate_storage { return 1; }

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    die "snapshots not supported" if $snapname;
    _iscsi_login_all($scfg);
    if ($scfg->{use_multipath}) { run_command(['multipath','-r'], outfunc => sub {}); }
    run_command(['udevadm','settle'], outfunc => sub {});
    return 1;
}

sub deactivate_volume { return 1; }

sub volume_snapshot          { die "snapshot not supported"; }
sub volume_snapshot_delete   { die "snapshot not supported"; }
sub volume_snapshot_rollback { die "snapshot not supported"; }
sub clone_image              { die "clone not supported"; }
sub create_base              { die "base images not supported"; }
sub volume_resize            { die "resize not supported"; }
sub volume_has_feature       { return undef; }

1;
