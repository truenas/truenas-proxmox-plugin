package RateLimit::Harness;
use strict;
use warnings;
use Exporter 'import';
use POSIX qw(strftime mktime);
use Time::HiRes qw(time sleep);
use Time::Piece;
use JSON::PP;

# Plugin's WS code writes to a possibly-dead persistent socket. Default Perl
# delivery for SIGPIPE is process termination, which masks the underlying
# error and aborts the test before the harness's retry loop can run. Ignore
# the signal so syswrite returns EPIPE and the plugin/harness can recover.
$SIG{PIPE} = 'IGNORE';

# Lazy-load the plugin so this module parses on hosts without PVE
# (e.g. dev workstation syntax-check). The first call to any helper
# that needs the plugin will load it.
sub _load_plugin {
    return if $INC{'PVE/Storage/Custom/TrueNASPlugin.pm'};
    require PVE::Storage::Custom::TrueNASPlugin;
}

our @EXPORT_OK = qw(
    env_require env_get
    now_iso epoch_iso
    drain_limiter
    new_audit_conn count_logins
    test_scfg
    qm_create_with_disk qm_destroy
    pvesm_status pvesh_status_async
    reap_orphans
    say_diag
);

# ---------------- environment ----------------

sub env_require {
    my ($name) = @_;
    my $v = $ENV{$name};
    die "Missing required env var: $name\n" unless defined $v && length $v;
    return $v;
}

sub env_get {
    my ($name, $default) = @_;
    return defined $ENV{$name} && length $ENV{$name} ? $ENV{$name} : $default;
}

# ---------------- time helpers ----------------

sub now_iso { return strftime('%Y-%m-%dT%H:%M:%S', gmtime(time())); }
sub epoch_iso { return strftime('%Y-%m-%dT%H:%M:%S', gmtime($_[0])); }

# Convert ISO 'YYYY-MM-DDTHH:MM:SS' (UTC) -> epoch seconds.
sub _iso_to_epoch {
    my ($iso) = @_;
    my $t = Time::Piece->strptime($iso, '%Y-%m-%dT%H:%M:%S');
    return $t->epoch;
}

# ---------------- limiter drain ----------------
# Sleep long enough that the TN per-IP-per-method counter for
# `auth.login_with_api_key` resets (60s since last_reset, plus margin).
sub drain_limiter {
    my $secs = env_get('DRAIN_SECS', 90);
    say_diag("draining limiter for ${secs}s");
    sleep $secs + 0;
}

# ---------------- storage cfg ----------------
# Build a minimal $scfg from the PVE storage config so the plugin's
# WS helpers can talk to TN. Reads /etc/pve/storage.cfg via PVE::Cluster
# if available, otherwise asks pvesh.
sub test_scfg {
    my $sid = env_require('STORAGE_ID');
    my $json = `pvesh get /storage/$sid --output-format json 2>/dev/null`;
    die "pvesh get /storage/$sid failed: $?\n" if $? != 0;
    my $cfg = decode_json($json);
    # Re-key as the plugin expects under $scfg. Different plugin branches read
    # different key names (legacy api_*, tn-prefixed tn_api_*). Emit both so
    # this harness drives either branch without modification.
    my $host = $cfg->{tn_api_host} // $cfg->{api_host} // env_require('TN_HOST');
    my $key  = env_require('TN_API_KEY');  # never trust storage.cfg to expose key
    my $scheme   = $cfg->{tn_api_scheme}   // $cfg->{api_scheme}   // 'wss';
    my $insecure = $cfg->{tn_api_insecure} // $cfg->{api_insecure} // 0;
    my $port     = $cfg->{tn_api_port}     // $cfg->{api_port};
    my $ipv4     = $cfg->{tn_prefer_ipv4}  // $cfg->{prefer_ipv4}  // 1;
    my %scfg = (
        type           => $cfg->{type},
        storage_id     => $sid,
        # Legacy keys (broker-service / pre-rename plugins)
        api_host       => $host,
        api_key        => $key,
        api_scheme     => $scheme,
        api_insecure   => $insecure,
        api_port       => $port,
        prefer_ipv4    => $ipv4,
        # tn_-prefixed keys (fix/rate-limit-connection-reuse and later)
        tn_api_host    => $host,
        tn_api_key     => $key,
        tn_api_scheme  => $scheme,
        tn_api_insecure=> $insecure,
        tn_api_port    => $port,
        tn_prefer_ipv4 => $ipv4,
        tn_pool        => $cfg->{tn_pool},
        target         => $cfg->{target},
        transport      => $cfg->{transport},
    );
    return \%scfg;
}

# ---------------- audit-based login counter ----------------

my $audit_conn;

sub new_audit_conn {
    # Open one long-lived WS to TN, dedicated to audit polling.
    # This is one login at suite start; tests subtract their own windows.
    my $scfg = test_scfg();
    $audit_conn = $scfg;  # plugin WS helpers operate on $scfg directly
    # Prime the persistent connection so the first audit query doesn't
    # land inside a test window.
    _load_plugin();
    eval { PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, 'system.version', []) };
    die "audit conn prime failed: $@" if $@;
    say_diag("audit connection primed");
    return $audit_conn;
}

# Returns count of `auth.login_with_api_key` (or auth.login_ex) calls
# observed at TN during [$start_iso, $end_iso] from any source IP.
# Window strings are ISO UTC ('YYYY-MM-DDTHH:MM:SS').
sub count_logins {
    my ($start_iso, $end_iso) = @_;
    my $scfg = $audit_conn || new_audit_conn();
    my $method = env_get('TN_LOGIN_COUNT_METHOD', 'audit');

    if ($method eq 'audit') {
        return _count_logins_audit($scfg, $start_iso, $end_iso);
    } elsif ($method eq 'journal') {
        return _count_logins_journal($start_iso, $end_iso);
    } else {
        die "Unknown TN_LOGIN_COUNT_METHOD: $method\n";
    }
}

sub _count_logins_audit {
    my ($scfg, $start_iso, $end_iso) = @_;
    _load_plugin();

    # TN stores message_timestamp as Unix epoch seconds (int), not ISO.
    # Convert our ISO window endpoints to epoch for the filter.
    my $start_epoch = _iso_to_epoch($start_iso);
    my $end_epoch   = _iso_to_epoch($end_iso);

    # TN 25.10.x audit.query takes a single dict argument with
    # `query-filters` and `query-options` keys.
    my $arg = {
        'query-filters' => [
            ['event', '=', 'AUTHENTICATION'],
            ['message_timestamp', '>=', $start_epoch],
            ['message_timestamp', '<=', $end_epoch],
        ],
        'query-options' => {
            select => ['event', 'event_data', 'message_timestamp', 'address'],
            limit  => 10000,
        },
    };

    # Don't reuse a long-lived audit conn. The TN persistent WS can go stale
    # during a long test (qm create + 90s drain easily exceed TN idle
    # timeout), and on failure both this and the plugin's cached entry get
    # dropped, costing two logins to recover. Open a fresh WS for each
    # count_logins call instead — one login per count, no stale risk. The
    # plugin's own %_ws_connections cache is cleared first so we don't
    # accidentally reuse another caller's dead socket.
    my $events;
    my $last_err;
    for my $try (1, 2, 3) {
        {
            no strict 'refs';
            my $cache = \%PVE::Storage::Custom::TrueNASPlugin::_ws_connections;
            for my $k (keys %$cache) {
                my $c = $cache->{$k};
                eval { $c->{sock}->close() if $c && $c->{sock} };
                delete $cache->{$k};
            }
        }
        $events = eval {
            PVE::Storage::Custom::TrueNASPlugin::_api_call(
                $scfg, 'audit.query', [$arg]
            );
        };
        $last_err = $@;
        last unless $last_err;
        warn "[harness] audit.query attempt $try failed: $last_err";
        # If the failure is rate-limit, the 60s counter window is the only
        # thing that will unstick us. Sleep past it. Otherwise short backoff.
        if ($try < 3) {
            if ($last_err =~ /Rate Limit Exceeded|EBUSY|errno\s*16/i) {
                warn "[harness] limiter tripped; sleeping 65s before retry\n";
                sleep 65;
            } else {
                sleep 2;
            }
        }
    }
    if ($last_err) {
        if (env_get('TN_LOGIN_COUNT_FALLBACK_JOURNAL', '') eq '1') {
            warn "[harness] audit.query failed twice; falling back to journal\n";
            return _count_logins_journal($start_iso, $end_iso);
        }
        die "[harness] audit.query failed twice: $last_err";
    }

    my $count = 0;
    for my $e (@{$events || []}) {
        my $ed   = $e->{event_data} || {};
        my $cred = $ed->{credentials} || {};
        my $type = $cred->{credentials}
                // $cred->{type}
                // '';
        my $akid = $cred->{credentials_data}->{api_key_id}
                // $cred->{credentials_data}->{api_key}
                // '';
        # Count any AUTHENTICATION event carrying an API_KEY marker.
        # Matches both nested and flat TN audit shapes.
        $count++ if $type =~ /API_KEY/i || $akid ne '';
    }
    return $count;
}

sub _count_logins_journal {
    my ($start_iso, $end_iso) = @_;
    my $host = env_require('TN_SSH_HOST');
    my $user = env_get('TN_SSH_USER', 'root');
    my $key  = env_get('TN_SSH_KEY', '');
    my @ssh = ('ssh');
    push @ssh, '-i', $key if length $key;
    push @ssh, "$user\@$host",
        "journalctl -u middlewared --no-pager --since '$start_iso UTC' --until '$end_iso UTC' --output=short-iso";
    my $out = `@ssh 2>/dev/null`;
    my $n = 0;
    $n++ for ($out =~ /auth\.login_with_api_key|auth\.login_ex/g);
    return $n;
}

# ---------------- PVE shell helpers ----------------

sub qm_create_with_disk {
    my ($vmid, $sid, $size_gb) = @_;
    $size_gb //= 1;
    # Use the canonical PVE alloc path: qm create with a disk on the storage.
    # PVE handles naming, calls plugin's alloc_image, returns the proper volid.
    my $out = `qm create $vmid --memory 128 --net0 virtio,bridge=vmbr0 --scsi0 $sid:$size_gb 2>&1`;
    my $rc = $? >> 8;
    return ($rc, $out);
}

sub qm_destroy {
    my ($vmid) = @_;
    my $out = `qm destroy $vmid --skiplock --purge 2>&1`;
    return ($? >> 8, $out);
}

sub pvesm_status {
    my ($sid) = @_;
    my $out = `pvesm status --storage $sid 2>&1`;
    return ($? >> 8, $out);
}

# Spawn N parallel `pvesh get /nodes/<node>/storage/<sid>/status`.
# Returns max exit code across children.
sub pvesh_status_async {
    my ($sid, $n) = @_;
    my $node = `hostname -s`; chomp $node;
    my @pids;
    for (1 .. $n) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            exec("pvesh get /nodes/$node/storage/$sid/status --output-format json >/dev/null 2>&1")
                or exit 127;
        }
        push @pids, $pid;
    }
    my $max = 0;
    for my $p (@pids) {
        waitpid($p, 0);
        my $rc = $? >> 8;
        $max = $rc if $rc > $max;
    }
    return $max;
}

# ---------------- orphan reaper ----------------
# Sweep test-range VMs and their volumes. Run before suite starts to
# clean up after prior crashes.
sub reap_orphans {
    my $sid  = env_require('STORAGE_ID');
    my $base = env_get('TEST_VMID_BASE', 99000);
    my $max  = $base + 99;
    my @reaped;

    # 1. Destroy any VMs in the test range (they own the disks).
    my $qmlist = `qm list 2>/dev/null`;
    for my $line (split /\n/, $qmlist) {
        next unless $line =~ /^\s*(\d+)\s/;
        my $vmid = $1;
        next unless $vmid >= $base && $vmid <= $max;
        say_diag("reap orphan VM: $vmid");
        system("qm destroy $vmid --skiplock --purge >/dev/null 2>&1");
        push @reaped, "vm/$vmid";
    }

    # 2. Sweep any stranded volumes on $sid in the test VMID range
    # (created by tests that ran without qm — e.g. raw pvesm alloc).
    my $smlist = `pvesm list $sid 2>/dev/null`;
    for my $line (split /\n/, $smlist) {
        next unless $line =~ /^(\S+)\s+\S+\s+\S+\s+\d+\s+(\d+)/;
        my ($volid, $vmid) = ($1, $2);
        next unless $vmid >= $base && $vmid <= $max;
        say_diag("reap orphan volume: $volid");
        system("pvesm free $volid >/dev/null 2>&1");
        push @reaped, $volid;
    }

    return scalar @reaped;
}

# ---------------- diag ----------------

sub say_diag {
    my $msg = join('', @_);
    print STDERR "# [harness] $msg\n";
}

1;
