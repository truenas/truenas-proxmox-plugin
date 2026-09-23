package PVE::Storage::Custom::TrueNASPlugin;
use v5.36;
use strict;
use warnings;

# Plugin Version
our $VERSION = '2.1.23~beta5';
# Highest Proxmox storage API version this plugin is validated against.
our $TESTED_APIVER = 15;
use JSON::PP qw(encode_json decode_json);
use URI::Escape qw(uri_escape);
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha1 sha1_hex);
use IO::Socket::INET;
use IO::Socket::SSL;
use IO::Select;
use Time::HiRes qw(usleep);
use POSIX ();
use Socket qw(inet_ntoa);
use Cwd qw(abs_path);
use Sys::Syslog qw(openlog syslog);
use Carp qw(carp croak);
use PVE::Tools qw(run_command trim);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::Storage::Plugin);

# Initialize syslog at compile time
BEGIN {
    openlog('truenasplugin', 'pid', 'daemon');
}

# Null destructor package for fork-safe socket handling
# When a process forks, inherited sockets must not run their DESTROY methods
# as this corrupts the parent's SSL state. Reblessing into this class makes
# DESTROY a no-op, preventing segfaults during child process exit.
package PVE::Storage::Custom::TrueNASPlugin::NullDestructor;
sub DESTROY { }  # Intentionally empty - prevents any cleanup
package PVE::Storage::Custom::TrueNASPlugin;

# Simple cache for API results
my %API_CACHE = ();
my $CACHE_TTL = 60; # seconds
my $STATUS_CAPACITY_TTL_S = 10;
# On-disk (/run/truenas-plugin/status-<key>) capacity-cache TTL. Shared
# across processes so every `pvesm status` doesn't pay the full
# pool.dataset.get_instance round-trip (issue #106). Kept short --
# 15 s -- because tests (disk_discard.pl fill/observe) and users
# expect `pvesm status` to reflect a ~30 s in-guest write, and a
# longer TTL masks that growth. 15 s is still 3-30x fewer TN calls
# than the 10 s in-process cache alone under the cross-node upload
# probe pattern that motivated #106 (PVE::API2::Storage::Status::
# upload's synchronous `ssh peer pvesm status --storage local`
# always misses the in-process cache -- burst probes complete in
# well under one second and reuse the same on-disk stamp).
my $STATUS_CAPACITY_STAMP_TTL_S = 15;
my $TARGET_VISIBLE_SKIP_TTL_S = 60;

# Per-host cache for preflight check results
my %_preflight_last_ok;
my %_target_visible_last_ok;

# Lightweight status-cache counters for tuning/verification
my %_status_capacity_cache_stats = (
    hit => 0,
    miss => 0,
    invalidate => 0,
    stamp_hit => 0,      # on-disk stamp fed a value across processes
    stamp_write => 0,    # freshly-fetched value written to on-disk stamp
    stamp_fail => 0,     # on-disk stamp read/write errored (best-effort)
);

# Per-storage cache for NVMe portal sync (avoids redundant port_subsys.query on every alloc)
my %_portal_sync_last_ok;

# Utility function to normalize TrueNAS API values
# Handles both scalar values and hash structures with parsed/raw fields
# Used throughout the plugin for consistent value extraction
#
# Every value here is decoded from a WebSocket/broker socket read, so under
# Perl taint mode (-T, active in pveproxy/pvedaemon workers) it is tainted no
# matter how it's reshaped in between. Untaint it here via regex capture -
# the one place all 13 call sites funnel through - instead of leaving a
# tainted scalar to later blow up wherever PVE core happens to exec() with it
# (e.g. qemu-img create during clone/move-disk to non-TrueNAS storage; see #71).
sub _normalize_value {
    my ($v) = @_;
    return 0 if !defined $v;
    $v = ($v->{parsed} // $v->{raw} // 0) if ref($v) eq 'HASH';
    return 0 if ref($v) || !defined($v) || $v eq '';
    return $1 if $v =~ /^(\d+)$/;
    die "_normalize_value: unexpected non-numeric value '$v'\n";
}

# Performance and timing constants
# These values are tuned for modern systems and network conditions
use constant {
    # Device settling timeouts (microseconds)
    UDEV_SETTLE_TIMEOUT_US    => 250_000,  # udev settle grace period (250ms)
    DEVICE_READY_TIMEOUT_US   => 100_000,  # device availability check (100ms)
    DEVICE_RESCAN_DELAY_US    => 150_000,  # device rescan stabilization (150ms)

    # Operation delays (seconds)
    DEVICE_SETTLE_DELAY_S     => 1,        # post-connection/logout stabilization
    # NOTE: the following cleanup-timeout constants were tightened after
    # test_run6/truenas-2026-08-13 showed vm_disk_buses hitting the 180 s
    # test-framework limit under cluster load. free_image was eating
    # 20-50 s per destroy (device-verify + dataset-delete-with-retries) and
    # 5 bus subtests * 30 s each blew past 180 s. Tightened defaults get
    # normal-path destroys back to sub-15 s; if TN legitimately needs more
    # for a specific dataset the retries still cover it.
    JOB_POLL_DELAY_S          => 1,        # job status polling interval

    # Job timeouts (seconds)
    SNAPSHOT_DELETE_TIMEOUT_S        => 15,  # snapshot deletion job timeout
    DATASET_DELETE_TIMEOUT_S         => 15,  # dataset deletion job timeout (per-attempt; retries handle transient TN busy)
    DEVICE_CLEANUP_VERIFY_TIMEOUT_S  => 2,   # device cleanup verification timeout (normal path ~200ms)
    DATASET_DELETE_RETRY_COUNT       => 3,   # max retries for dataset deletion on "busy" errors
};

sub _cache_key {
    my ($storage_id, $method) = @_;
    return "${storage_id}:${method}";
}

# Returns the cache host key for a storage config (api_host preferred, storeid fallback)
sub _cache_host_key {
    my ($scfg) = @_;
    return $scfg->{tn_api_host} || $scfg->{storeid} || 'unknown';
}

sub _get_cached {
    my ($storage_id, $method, $ttl_s) = @_;
    my $key = _cache_key($storage_id, $method);
    my $entry = $API_CACHE{$key};
    return unless $entry;

    my $ttl = defined($ttl_s) ? $ttl_s : $CACHE_TTL;
    return unless (time() - $entry->{timestamp}) < $ttl;
    return $entry->{data};
}

sub _set_cache {
    my ($storage_id, $method, $data) = @_;
    my $key = _cache_key($storage_id, $method);
    $API_CACHE{$key} = {
        data => $data,
        timestamp => time()
    };
    return $data;
}

sub _clear_cache {
    my ($storage_id) = @_;
    if ($storage_id) {
        # Clear cache for specific storage (storage_id is api_host)
        delete $API_CACHE{$_} for grep { /^\Q$storage_id\E:/ } keys %API_CACHE;
        delete $_preflight_last_ok{$storage_id};
        delete $_target_visible_last_ok{$storage_id};
    } else {
        # Clear all cache
        %API_CACHE = ();
        %_preflight_last_ok = ();
        %_target_visible_last_ok = ();
    }
    # NOTE: do NOT unlink the /run/truenas-plugin/preflight-<key> stamp
    # here. _clear_cache runs after every extent/targetextent/zvol
    # mutation, which is completely orthogonal to whether the preflight
    # signals (pool ONLINE, service RUNNING, dataset exists, space free)
    # are still valid. Wiping the stamp per-mutation defeats the entire
    # cross-worker cache and forces the next alloc to re-run the 4 TN
    # API calls. The stamp expires by TTL (300 s) or by tmpfs reset on
    # reboot -- that's the correct invalidation surface for preflight
    # state, not "we changed an extent."
    # Keep portal sync cache aligned with the same host scoping
    if ($storage_id) {
        delete $_portal_sync_last_ok{$storage_id};
    } else {
        %_portal_sync_last_ok = ();
    }
}

# Invalidate a specific cache entry without clearing the entire host's cache
sub _invalidate_cache_key {
    my ($host_key, $method) = @_;
    delete $API_CACHE{_cache_key($host_key, $method)};
}

# ======== Helper functions ========
sub _format_bytes {
    my ($bytes) = @_;
    return '0 B' if !defined $bytes || $bytes == 0;

    my @units = qw(B KB MB GB TB PB);
    my $unit_idx = 0;
    my $size = $bytes;

    while ($size >= 1024 && $unit_idx < $#units) {
        $size /= 1024;
        $unit_idx++;
    }

    return sprintf("%.2f %s", $size, $units[$unit_idx]);
}

# Parse ZFS blocksize string (e.g., "128K", "64K", "1M") to bytes
# Returns integer bytes, or 0 if invalid/undefined
sub _parse_blocksize {
    my ($bs_str) = @_;
    return 0 if !defined $bs_str || $bs_str eq '';

    # Match: number followed by optional K/M/G suffix (case-insensitive)
    if ($bs_str =~ /^(\d+)([KMG])?$/i) {
        my ($num, $unit) = ($1, $2 // '');
        my $bytes = int($num);
        $bytes *= 1024 if uc($unit) eq 'K';
        $bytes *= 1024 * 1024 if uc($unit) eq 'M';
        $bytes *= 1024 * 1024 * 1024 if uc($unit) eq 'G';
        return $bytes;
    }
    return 0;  # Invalid format
}

# Debug logging helper - respects debug level from storage config
# Usage: _log($scfg, $level, $priority, $message)
#   $level: 0=always, 1=light debug, 2=verbose debug
#   $priority: syslog priority ('err', 'warning', 'info', 'debug')
sub _log {
    my ($scfg, $level, $priority, $message) = @_;

    # Normalize syslog priority aliases
    $priority = 'warning' if defined($priority) && $priority eq 'warn';
    $priority = 'err' if defined($priority) && $priority eq 'error';

    # Level 0 messages (errors) are always logged
    return syslog($priority, $message) if $level == 0;

    # For level 1+, check debug configuration
    my $debug_level = $scfg->{tn_debug} // 0;
    return if $level > $debug_level;

    syslog($priority, $message);
}

# Normalize blocksize to uppercase format required by TrueNAS 25.10+
# Converts: 16k -> 16K, 128k -> 128K, etc.
# TrueNAS 25.10 requires: '512', '512B', '1K', '2K', '4K', '8K', '16K', '32K', '64K', '128K'
sub _normalize_blocksize {
    my ($blocksize) = @_;
    return undef if !defined $blocksize;

    # Convert to uppercase (16k -> 16K, 64k -> 64K, etc.)
    $blocksize = uc($blocksize);

    return $blocksize;
}

# ======== Error classification helpers ========
sub _is_connection_error {
    my ($error) = @_;
    return 0 if !defined $error;
    # NOTE: do not add /x to this regex. /x strips literal whitespace from
    # the pattern, which silently turns every multi-word alternative
    # ('broken pipe', 'connection reset', 'WS read', ...) into a no-match.
    # That bug existed in fe06ea1 and caused every framing/EPIPE failure
    # to be misclassified as non-retryable, which in turn cascaded into
    # preflight storms (see test_run3/truenas-2026-06-26).
    #
    # `WebSocket.*closed` was previously in the pattern and caused a
    # different misclassification: middlewared's JSON-RPC error payloads
    # include Python object reprs like `RpcWebSocketApp object at 0x...`
    # followed later by `EventLoop ... closed=False`, so any error whose
    # trace mentions those class names + closed=False (e.g. a benign
    # "dataset already exists" from pool.dataset.create) matched
    # WebSocket.*closed and was retried 3 times before finally dying with
    # "Max retries (3) exhausted", wasting seconds on the shared cluster
    # storage lock (cluster_test_run 2026-08-17 3-node run). The WS-
    # specific broker patterns ('WS read', 'WS write', 'WS len',
    # 'WS payload') and the generic timeout / connection reset alternatives
    # already cover every real WS-close failure our broker or upstream
    # emits, so the WebSocket.*closed slot is gone.
    return $error =~ /timeout|timed out|connection refused|connection reset|broken pipe|network is unreachable|host is unreachable|temporary failure|service unavailable|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout|ssl.*error|connection.*failed|WS read|WS write|WS len|WS payload/i;
}

# TrueNAS validates the `disk` / `device_path` field on iscsi.extent.create
# and nvmet.namespace.create by stat'ing the underlying /dev/zvol symlink.
# Right after pool.snapshot.clone or pool.dataset.create returns success on
# the ZFS side, that symlink may still be waiting on udev, so a same-call
# create fails with either:
#   [EINVAL] iscsi_extent_create.disk: Device '/dev/zvol/<ds>' ... does not exist
#   [EINVAL] nvmet_namespace_create.device_path: ZVOL device_path must be a block device: zvol/<ds>
# Both mean "come back in a moment". Match narrowly so a genuinely bad path
# (typo in tn_dataset, deleted zvol) still fails fast.
sub _is_zvol_not_ready_error {
    my ($error) = @_;
    return 0 if !defined $error;
    return 1 if $error =~ /iscsi_extent_create\.disk.*does not exist/i;
    return 1 if $error =~ /nvmet_namespace_create\.device_path.*must be a block device/i;
    return 0;
}

# iSCSI extent name has a TN-side unique constraint. `iscsi.extent.create`
# with a name that already exists returns:
#   [EINVAL] iscsi_extent_create.name: Extent name must be unique
# Callers that get this on a create for a zvol_path they own should look
# up the existing extent by disk path and reuse it (idempotent recovery):
# the collision can arise from a concurrent path that created it, or from
# a retry that self-races with its own already-committed first attempt
# (an _api_call_mutate retry fires on connection errors even when the
# mutation succeeded server-side before the response was lost).
sub _is_extent_name_conflict_error {
    my ($error) = @_;
    return 0 if !defined $error;
    return $error =~ /iscsi_extent_create\.name.*must be unique/i;
}

# Historical create_base extent-rename gap: create_base renamed a zvol
# vm-<vmid>-disk-N -> base-<vmid>-disk-N and rewrote extent.disk, but
# did NOT rename the extent itself. The vm-<vmid>-disk-N-<hash> name
# slot on TN stayed owned by the (now-base) extent. Later VM allocs at
# the same VMID hash to the same extent name and get
# "iscsi_extent_create.name: Extent name must be unique". Fix B looks
# up by name, sees the disk field differs, and correctly refuses to
# reuse (it can't safely redirect this VM's disk to a base zvol).
#
# This helper repairs the stale name in place when the shape matches:
# a same-name extent whose disk is zvol/<dataset>/base-<vmid>-disk-N.
# Renaming the extent to its proper base-*-<hash> name frees the
# vm-*-<hash> slot so the caller's next create can succeed. The rename
# is bookkeeping-only from the initiator side: extent_id, targetextent
# mapping, and naa/serial identifiers are all preserved. Nothing on
# the wire changes; only the TN-side extent name is corrected.
#
# Returns 1 if the stale extent was renamed (caller should retry the
# create). Returns 0 if the shape does not match (genuine hash-slot
# collision -- caller should give up) or the rename call itself failed.
sub _iscsi_extent_recover_stale_base_name {
    my ($scfg, $stale_extent, $expected_zvol_path) = @_;
    my $stale_disk = $stale_extent->{disk} // '';
    my ($stale_zname) = $stale_disk =~ m{/(base-\d+-disk-\d+)$};
    return 0 unless $stale_zname;
    my $proper_name = _generate_extent_name($scfg, $stale_zname);
    return 0 if $proper_name eq ($stale_extent->{name} // '');
    _log($scfg, 0, 'info',
        "[TrueNAS] iSCSI extent id=$stale_extent->{id} name=" .
        ($stale_extent->{name} // '<undef>') .
        " occupies our name slot for $expected_zvol_path but its disk is a " .
        "base zvol ($stale_disk); renaming stale extent to $proper_name " .
        "(create_base extent-rename recovery)");
    eval {
        _api_call_mutate($scfg, 'iscsi.extent.update',
            [ $stale_extent->{id}, { name => $proper_name } ]);
    };
    if ($@) {
        _log($scfg, 0, 'err',
            "[TrueNAS] iSCSI stale-extent rename id=$stale_extent->{id} -> " .
            "$proper_name failed: $@");
        return 0;
    }
    _clear_cache(_cache_host_key($scfg));
    return 1;
}

sub _is_not_found_error {
    my ($error) = @_;
    return 0 if !defined $error;
    return $error =~ /404 Not Found|ENOENT|InstanceNotFound|does not exist|not found/i;
}

# pool.dataset.rename EEXIST classifier. TN returns:
#   [EEXIST] zfs.resource.rename: 'tank/<pool>/base-<vmid>-disk-N' already exists
# When create_base's rename hits this, it usually means a prior template of
# the same VMID left the base dataset on TN. If that base is an orphan (no
# live clones, no children), the plugin can safely delete it and retry.
# See _dataset_orphan_check_and_delete and project_create_base_eexist_gap.
sub _is_dataset_already_exists_error {
    my ($error) = @_;
    return 0 if !defined $error;
    return ($error =~ /ZFSPathAlreadyExistsException|EEXIST/i)
        && ($error =~ /zfs\.resource\.rename|pool\.dataset\.rename/i)
        && ($error =~ /already exists/i);
}

# Check whether $target_dataset is an orphan on TN (no non-snapshot children,
# no linked clones deriving from its @__base__ snapshot). If it is, delete it
# and return 1 so the caller can retry the operation that originally hit the
# EEXIST. Return 0 if the dataset has live children/clones (unsafe to remove),
# or if the query/delete itself failed.
sub _dataset_orphan_check_and_delete {
    my ($scfg, $target_dataset) = @_;
    my $query = eval {
        _api_call($scfg, 'pool.dataset.query',
            [ [[ 'id', '=', $target_dataset ]] ]);
    };
    if (my $err = $@) {
        _log($scfg, 0, 'warning',
            "[TrueNAS] _dataset_orphan_check_and_delete: query $target_dataset failed: $err");
        return 0;
    }
    my $target = $query && ref($query) eq 'ARRAY' ? $query->[0] : undef;
    if (!$target) {
        # Dataset is gone since the EEXIST (another node just cleaned it).
        # Signal caller to retry.
        _log($scfg, 0, 'info',
            "[TrueNAS] $target_dataset gone since the EEXIST; caller can retry");
        return 1;
    }
    my @children = grep {
        ($_->{type} // '') ne 'SNAPSHOT'
    } @{ $target->{children} // [] };
    if (@children) {
        my $child_names = join(', ', map { $_->{name} // $_->{id} } @children);
        _log($scfg, 0, 'err',
            "[TrueNAS] $target_dataset has child dataset(s) [$child_names]; " .
            "cannot delete for orphan recovery");
        return 0;
    }
    # Check for linked clones deriving from the @__base__ snapshot. Any dataset
    # whose origin.parsed points at $target_dataset@__base__ is a live clone
    # and destroying the base would break it.
    my $snap_clones = eval {
        _api_call($scfg, 'pool.dataset.query',
            [ [[ 'origin.parsed', '=', "${target_dataset}\@__base__" ]],
              { select => [ 'id' ] } ]);
    };
    if (!$@ && $snap_clones && ref($snap_clones) eq 'ARRAY' && @$snap_clones) {
        my $clone_names = join(', ', map { $_->{id} // '<undef>' } @$snap_clones);
        _log($scfg, 0, 'err',
            "[TrueNAS] $target_dataset has linked clone(s) [$clone_names] " .
            "deriving from \@__base__; cannot delete for orphan recovery");
        return 0;
    }
    _log($scfg, 0, 'info',
        "[TrueNAS] deleting orphaned $target_dataset (no children, no clones) " .
        "to allow retry of the operation that hit EEXIST");
    eval {
        _api_call_mutate($scfg, 'pool.dataset.delete',
            [ $target_dataset, { recursive => JSON::PP::true, force => JSON::PP::true } ]);
    };
    if (my $err = $@) {
        # A concurrent cleanup may have raced us here -- that's fine, the
        # ENOENT after our query is exactly what the caller wants.
        return 1 if $err =~ /does not exist|ENOENT|InstanceNotFound/i;
        _log($scfg, 0, 'err',
            "[TrueNAS] delete of orphaned $target_dataset failed: $err");
        return 0;
    }
    return 1;
}

sub _is_auth_error {
    my ($error) = @_;
    return 0 if !defined $error;
    # ENOTAUTHENTICATED / "Not authenticated" surface from TrueNAS 25.10+
    # after the middleware silently expires an API-key session at 30
    # days (AA_LEVEL1.max_session_age). Naming them here makes the
    # classification correct in retry/log paths even though the broker
    # liveness check (auth.me, issue #98) is the primary place the
    # condition is detected and handled.
    return $error =~ /401 Unauthorized|403 Forbidden|authentication.*failed|unauthorized|forbidden|invalid.*key|ENOTAUTHENTICATED|Not authenticated/i;
}

# ======== Retry logic with exponential backoff ========
sub _is_retryable_error {
    my ($error) = @_;
    return 0 if !defined $error;

    # Do NOT retry on database integrity errors — check BEFORE connection patterns
    # because FK errors include Python traceback paths containing "connection.py"
    # which would otherwise false-match the /connection.*failed/ pattern below
    return 0 if $error =~ /FOREIGN KEY constraint failed|IntegrityError|constraint failed/i;

    # Do NOT retry on ZFS "already exists" errors -- these are deterministic
    # collisions (auto-increment handles them in the caller). Also gated
    # BEFORE the connection-error check because middlewared's error payload
    # includes a Python traceback whose text may otherwise false-match a
    # retryable pattern.
    return 0 if $error =~ /dataset already exists|EZFS_EXISTS|zfs_create.*failed/i;

    # Retry on transient connection/network errors
    return 1 if _is_connection_error($error);

    # Do NOT retry on authentication, not found, or validation errors
    return 0 if _is_auth_error($error);
    return 0 if _is_not_found_error($error);
    return 0 if $error =~ /validation.*error|invalid.*parameter/i;
    return 0 if $error =~ /EINVAL|Invalid params/i;

    return 0; # Default: don't retry unknown errors
}

sub _retry_with_backoff {
    my ($scfg, $operation_name, $code_ref, $retry_opts) = @_;

    my $max_retries = defined($retry_opts) && exists($retry_opts->{retry_max})
        ? $retry_opts->{retry_max}
        : ($scfg->{tn_api_retry_max} // 3);
    my $initial_delay = defined($retry_opts) && exists($retry_opts->{retry_delay})
        ? $retry_opts->{retry_delay}
        : ($scfg->{tn_api_retry_delay} // 1);

    my $attempt = 0;
    my $last_error;
    my $result;

    while ($attempt <= $max_retries) {
        $result = eval {
            return $code_ref->();
        };

        $last_error = $@;

        # Success - no error, return the result
        return $result if !$last_error;

        $attempt++;

        # Check if error is retryable
        if (!_is_retryable_error($last_error)) {
            _log($scfg, 2, 'debug', "[TrueNAS] Non-retryable error for $operation_name: $last_error");
            die $last_error; # Not retryable, fail immediately
        }

        # Max retries exhausted
        if ($attempt > $max_retries) {
            _log($scfg, 0, 'err', "[TrueNAS] Max retries ($max_retries) exhausted for $operation_name: $last_error");
            die "Operation failed after $max_retries retries: $last_error";
        }

        # Calculate delay with exponential backoff
        my $delay = $initial_delay * (2 ** ($attempt - 1));
        # Add jitter (0-20% random variation) to prevent thundering herd
        my $jitter = $delay * 0.2 * rand();
        $delay += $jitter;

        _log($scfg, 1, 'info', "[TrueNAS] Retry attempt $attempt/$max_retries for $operation_name after ${delay}s delay (error: $last_error)");
        sleep($delay);
    }

    # Should never reach here, but just in case
    die $last_error;
}

# ======== Storage plugin identity ========
# Storage API version - dynamically adapts to PVE version
# Supports PVE 8.x (APIVER 11) through PVE 9.2+ (APIVER 15)
sub api {
    my $tested_apiver = $TESTED_APIVER;  # Latest tested version (PVE 9.x)

    # Get current system API version (safely, as PVE::Storage may not be loaded yet)
    my $system_apiver = eval { require PVE::Storage; PVE::Storage::APIVER() } // 11;
    my $system_apiage = eval { PVE::Storage::APIAGE() } // 2;

    # If system API is within our tested range, return system version
    # This ensures we never claim a higher version than the system supports
    if ($system_apiver >= 11 && $system_apiver <= $tested_apiver) {
        return $system_apiver;
    }

    # If we're within APIAGE of tested version, return tested version
    if ($system_apiver - $system_apiage < $tested_apiver) {
        return $tested_apiver;
    }

    # Fallback for very old systems (shouldn't happen with PVE 7+)
    return 11;
}
sub type { return 'truenasplugin'; } # storage.cfg "type"
sub plugindata {
    return {
        content => [ { images => 1, rootdir => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],
    };
}

# ======== Config schema (only plugin-specific keys) ========
sub properties {
    return {
        # Transport & connection
        tn_api_host => {
            description => "TrueNAS hostname or IP (IPv6 literals must be bracketed, e.g. [fd00:1::1]).",
            type => 'string', format => 'pve-storage-portal-dns',
        },
        tn_api_key => {
            description => "TrueNAS user-linked API key.",
            type => 'string',
        },
        tn_api_scheme => {
            description => "WebSocket scheme: 'wss' (secure) or 'ws' (insecure). Default: wss.",
            type => 'string', optional => 1,
        },
        tn_api_transport => {
            description => "Deprecated legacy transport selector. Ignored; WebSocket is always used.",
            type => 'string', optional => 1,
        },
        tn_api_port => {
            description => "TCP port (defaults: 443 for wss, 80 for ws).",
            type => 'integer', optional => 1,
        },
        tn_api_insecure => {
            description => "Skip TLS certificate verification.",
            type => 'boolean', optional => 1, default => 0,
        },
        tn_prefer_ipv4 => {
            description => "Prefer IPv4 (A records) when resolving tn_api_host.",
            type => 'boolean', optional => 1, default => 1,
        },

        # Placement
        tn_dataset => {
            description => "Parent dataset for zvols (e.g. tank/proxmox).",
            type => 'string',
        },
        tn_zvol_blocksize => {
            description => "ZVOL volblocksize (e.g. 16K, 64K).",
            type => 'string', optional => 1,
        },

        # Transport mode selection
        tn_transport_mode => {
            description => "Storage transport protocol: 'iscsi' or 'nvme-tcp'.",
            type => 'string',
            enum => ['iscsi', 'nvme-tcp'],
            optional => 1,
            default => 'iscsi',
        },

        # iSCSI target & portals
        tn_target_iqn => {
            description => "Shared iSCSI Target IQN on TrueNAS (or target's short name) - required for iSCSI transport.",
            type => 'string',
            optional => 1,
        },
        tn_discovery_portal => {
            description => "Primary SendTargets portal (IP[:port] or [IPv6]:port).",
            type => 'string',
        },
        tn_portals => {
            description => "Comma-separated additional portals.",
            type => 'string', optional => 1,
        },

        # Initiator pathing
        tn_use_multipath => { type => 'boolean', optional => 1, default => 1 },
        tn_force_delete_on_inuse => {
            description => 'Temporarily logout the target on this node to force delete when TrueNAS reports "target is in use".',
            type => 'boolean',
            default => 'false',
        },
        tn_logout_on_free => {
            description => 'After delete, logout the target if no LUNs remain for this node.',
            type => 'boolean',
            default => 'false',
        },
        tn_use_by_path  => { type => 'boolean', optional => 1, default => 0 },
        tn_ipv6_by_path => {
            description => "Normalize IPv6 by-path names (enable only if using IPv6 portals).",
            type => 'boolean', optional => 1, default => 0,
        },

        # Debug level
        tn_debug => {
            description => "Debug level: 0=none (errors only), 1=light (function calls), 2=verbose (full trace)",
            type => 'integer', optional => 1, default => 0, minimum => 0, maximum => 2,
        },

        # CHAP (optional - iSCSI only)
        tn_chap_user     => { type => 'string', optional => 1 },
        tn_chap_password => { type => 'string', optional => 1 },

        # NVMe/TCP parameters
        tn_subsystem_nqn => {
            description => "NVMe subsystem NQN - required for nvme-tcp transport.",
            type => 'string',
            optional => 1,
        },
        tn_hostnqn => {
            description => "NVMe host NQN (optional, auto-generated from /etc/nvme/hostnqn if not specified).",
            type => 'string',
            optional => 1,
        },
        tn_nvme_dhchap_secret => {
            description => "DH-HMAC-CHAP host authentication key (format: DHHC-1:01:...) - optional.",
            type => 'string',
            optional => 1,
        },
        tn_nvme_dhchap_ctrl_secret => {
            description => "DH-HMAC-CHAP controller authentication key for bidirectional auth - optional.",
            type => 'string',
            optional => 1,
        },
        tn_nvme_allow_any_host => {
            description => "Value the plugin writes to the TrueNAS NVMe subsystem's " .
                          "`allow_any_host` attribute on create and on Issue-#12 " .
                          "configfs-resync ping updates. Default: TRUE (the plugin " .
                          "asks TN to accept any host NQN on the subsystem). Set to " .
                          "0/false ONLY when you have populated allowed_hosts on the " .
                          "same subsystem via the TrueNAS UI or API and want the " .
                          "allow-list actually enforced. Two caveats: (a) on TN " .
                          "26.0.0-BETA.2 (and possibly other 26.x betas), a " .
                          "freshly-created subsystem with allow_any_host=false AND " .
                          "empty allowed_hosts is silently not rendered to the " .
                          "kernel configfs at all -- port has no listener, no host " .
                          "can connect. Keep true here unless you have populated " .
                          "the allow-list first. (b) on TN 25.10.x, " .
                          "attr_allow_any_host=1 combined with a populated " .
                          "allowed_hosts aborts the configfs render (issue #90); " .
                          "set this to false in that scenario.",
            type => 'boolean', optional => 1, default => 1,
        },

        # ZFS compression algorithm for new volumes
        tn_compression => {
            description => "ZFS compression algorithm for new volumes. When unset, inherits from parent dataset.",
            type => 'string',
            enum => [qw(OFF LZ4 GZIP GZIP-1 GZIP-9 ZSTD ZSTD-1 ZSTD-3 ZSTD-5 ZSTD-7 ZSTD-9 ZLE LZJB)],
            optional => 1,
        },

        # Thin provisioning toggle (maps to TrueNAS sparse)
        tn_sparse => {
            description => "Create thin-provisioned zvols on TrueNAS (maps to 'sparse').",
            type => 'boolean', optional => 1, default => 1,
        },

        # Live snapshot support
        tn_enable_live_snapshots => {
            description => "Enable live snapshots with VM state storage on TrueNAS.",
            type => 'boolean', optional => 1, default => 1,
        },
        # Volume chains for snapshots (enables vmstate support)
        tn_snapshot_volume_chains => {
            description => "Use volume chains for snapshots (enables vmstate on iSCSI).",
            type => 'boolean', optional => 1, default => 1,
        },
        # vmstate storage location
        tn_vmstate_storage => {
            description => "Storage location for vmstate: 'shared' (TrueNAS iSCSI) or 'local' (node filesystem).",
            type => 'string', optional => 1, default => 'local',
        },

        # Bulk operations for improved performance
        tn_enable_bulk_operations => {
            description => "Enable bulk API operations for better performance (requires WebSocket transport).",
            type => 'boolean', optional => 1, default => 1,
        },

        # Retry configuration
        tn_api_retry_max => {
            description => "Maximum number of API call retries on transient failures.",
            type => 'integer', optional => 1, default => 3,
        },
        tn_api_retry_delay => {
            description => "Initial retry delay in seconds (doubles with each retry).",
            type => 'number', optional => 1, default => 1,
        },
        tn_storage_lock_timeout => {
            description => "Cluster lock timeout in seconds for storage operations. " .
                          "Increase for parallel bulk provisioning. Default: 120. " .
                          "Only relevant when tn_use_cluster_lock=1; the default (bypass) " .
                          "does not acquire the CFS lock at all.",
            type => 'integer', optional => 1, default => 120, minimum => 10, maximum => 600,
        },
        tn_use_cluster_lock => {
            description => "Serialize all storage operations across nodes via the PVE " .
                          "CFS cluster lock (classic PVE behavior). Default: 0 (bypass). " .
                          "TrueNAS's middleware already serializes conflicting mutations " .
                          "internally and the plugin's Fix 1/Fix B/dataset-auto-increment " .
                          "cover any residual PVE-side race, so the CFS lock is redundant " .
                          "and its queue wait under multi-node concurrent load has been " .
                          "measured to push individual allocs past the pveproxy 60 s HTTP " .
                          "read ceiling. Set to 1 only if you observe correctness issues " .
                          "on a nonstandard TN configuration.",
            type => 'boolean', optional => 1, default => 0,
        },
        tn_device_ready_retries => {
            description => "Number of 100ms retries waiting for a block device to appear after connect.",
            type => 'integer', optional => 1, default => 600, minimum => 0, maximum => 1200,
        },
        tn_broker_timeout => {
            description => "Broker Unix-socket round-trip deadline in seconds. Bumped from " .
                          "the previous 30 s default so a single TN op that runs long under " .
                          "concurrent cluster load (large iscsi.extent.query, contended " .
                          "pool.dataset.get_instance) does not trip the deadline and burn a " .
                          "retry. Tune down only if you want failures to surface faster.",
            type => 'integer', optional => 1, default => 60, minimum => 5, maximum => 300,
        },
        tn_nr_io_queues => {
            description => "Number of NVMe/TCP I/O queues per controller. When unset, " .
                          "auto-detected: uses online CPU count when all CPUs are online, " .
                          "or half of possible CPUs when any CPU is offline (avoids kernel " .
                          "queue-to-CPU mapping failures with gapped CPU topologies, " .
                          "see issue #48). Set manually if TrueNAS reports queue limit errors.",
            type => 'integer', optional => 1, minimum => 1, maximum => 256,
        },
        tn_nvme_ctrl_loss_tmo => {
            description => "Seconds the kernel keeps retrying a failed NVMe/TCP controller " .
                          "before giving up and removing it (nvme connect --ctrl-loss-tmo). " .
                          "Use -1 to retry forever. When unset the kernel default of 600 applies, " .
                          "which permanently drops a path whose fabric stays down for over ten " .
                          "minutes. Recommended for multi-portal setups, where silently losing a " .
                          "path is worse than retrying indefinitely.",
            type => 'integer', optional => 1, minimum => -1, maximum => 3600,
        },
        tn_nvme_reconnect_delay => {
            description => "Seconds between reconnect attempts for a failed NVMe/TCP controller " .
                          "(nvme connect --reconnect-delay). Kernel default is 10.",
            type => 'integer', optional => 1, minimum => 1, maximum => 3600,
        },
        tn_nvme_keep_alive_tmo => {
            description => "NVMe/TCP keep-alive timeout in seconds " .
                          "(nvme connect --keep-alive-tmo). Lower values detect a dead path " .
                          "sooner, at the cost of more keep-alive traffic.",
            type => 'integer', optional => 1, minimum => 1, maximum => 3600,
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
        tn_api_host      => { fixed => 1 },
        tn_api_key       => { fixed => 1 },
        tn_api_scheme    => { optional => 1, fixed => 1 },
        tn_api_transport => { optional => 1, fixed => 1 },
        tn_api_port      => { optional => 1, fixed => 1 },
        tn_api_insecure  => { optional => 1, fixed => 1 },
        tn_prefer_ipv4   => { optional => 1 },

        # Placement
        tn_dataset        => { fixed => 1 },
        tn_zvol_blocksize => { optional => 1, fixed => 1 },

        # Transport mode
        tn_transport_mode => { optional => 1, fixed => 1 },

        # iSCSI target & portals
        tn_target_iqn             => { optional => 1, fixed => 1 },
        tn_discovery_portal       => { optional => 1, fixed => 1 },
        tn_portals                => { optional => 1 },
        tn_force_delete_on_inuse  => { optional => 1 },
        tn_logout_on_free         => { optional => 1 },

        # Initiator
        tn_use_multipath => { optional => 1 },
        tn_use_by_path   => { optional => 1 },
        tn_ipv6_by_path  => { optional => 1 },

        # CHAP (iSCSI)
        tn_chap_user     => { optional => 1 },
        tn_chap_password => { optional => 1 },

        # NVMe/TCP parameters
        tn_subsystem_nqn          => { optional => 1, fixed => 1 },
        tn_hostnqn                => { optional => 1 },
        tn_nvme_dhchap_secret     => { optional => 1 },
        tn_nvme_dhchap_ctrl_secret => { optional => 1 },
        tn_nvme_allow_any_host     => { optional => 1 },

        # ZFS tunables
        tn_compression => { optional => 1 },
        tn_sparse => { optional => 1 },

        # Debug
        tn_debug => { optional => 1 },

        # Live snapshots
        tn_enable_live_snapshots => { optional => 1 },
        tn_snapshot_volume_chains => { optional => 1 },
        tn_vmstate_storage => { optional => 1 },

        # Bulk operations
        tn_enable_bulk_operations => { optional => 1 },

        # Retry configuration
        tn_api_retry_max => { optional => 1 },
        tn_api_retry_delay => { optional => 1 },

        # Concurrency
        tn_storage_lock_timeout => { optional => 1 },
        tn_use_cluster_lock => { optional => 1 },

        # Device readiness
        tn_device_ready_retries => { optional => 1 },

        # Broker deadline
        tn_broker_timeout => { optional => 1 },

        # NVMe/TCP queue tuning
        tn_nr_io_queues => { optional => 1 },
        tn_nvme_ctrl_loss_tmo   => { optional => 1 },
        tn_nvme_reconnect_delay => { optional => 1 },
        tn_nvme_keep_alive_tmo  => { optional => 1 },
    };
}

# Force shared storage behavior for cluster migration support
sub check_config {
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;
    my $opts = $class->SUPER::check_config($sectionId, $config, $create, $skipSchemaCheck);

    # Always set shared=1 since this is block-based shared storage (iSCSI or NVMe/TCP)
    $opts->{shared} = 1;

    # Backward compatibility: accept legacy api_transport without breaking config parsing.
    # TrueNAS SCALE API is WebSocket-only in current plugin versions.
    if (defined $opts->{tn_api_transport}) {
        my $legacy_transport = lc($opts->{tn_api_transport} // '');

        if (!defined($opts->{tn_api_scheme}) || $opts->{tn_api_scheme} eq '') {
            if ($legacy_transport eq 'wss') {
                $opts->{tn_api_scheme} = 'wss';
            } else {
                # Legacy api_transport values are deprecated and should not force insecure WS.
                # Default to secure websocket behavior for compatibility.
                $opts->{tn_api_scheme} = 'wss';
            }
        }

        if ($legacy_transport eq 'rest') {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': tn_api_transport=rest is deprecated and unsupported. " .
                "Using WebSocket transport instead (tn_api_scheme=$opts->{tn_api_scheme})."
            );
        } elsif ($legacy_transport eq 'ws') {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': tn_api_transport=ws is deprecated; " .
                "using secure websocket transport instead (tn_api_scheme=$opts->{tn_api_scheme})."
            );
        } else {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': tn_api_transport is deprecated and ignored; " .
                "use tn_api_scheme/tn_api_port if transport tuning is needed."
            );
        }
    }

    # Validate retry configuration parameters
    # ctrl_loss_tmo 0 means "give up on the first error": the controller is
    # removed without a single retry, which is strictly worse than the kernel
    # default of 600 that this option exists to override. -1 (retry forever) and
    # any positive value are the useful settings, so the schema minimum of -1
    # alone is not enough to express it.
    # A dotted quad with a leading-zero octet is read two different ways by the
    # two layers that see it: this plugin normalises 192.000.002.010 to
    # 192.0.2.10 for key matching, while nvme connect hands the raw string to
    # inet_aton, where 010 is octal eight - a different host. The connection
    # would then never match its own configuration and be reconnected forever.
    # Rejecting is right; picking one of the two readings is not.
    for my $portal_key (($opts->{tn_transport_mode} // '') eq 'nvme-tcp'
                        ? qw(tn_discovery_portal tn_portals) : ()) {
        next if !defined $opts->{$portal_key};
        for my $portal (split(/\s*,\s*/, $opts->{$portal_key})) {
            # Trim as _nvme_configured_portals() does, or a leading space on the
            # whole list hides the first entry from this check while the runtime
            # still uses it.
            $portal =~ s/^\s+|\s+$//g;
            next if $portal eq '';
            my ($portal_host) = _nvme_parse_portal($portal);
            next if !defined($portal_host);
            next if $portal_host !~ /^[0-9]+(?:\.[0-9]+){3}$/;
            die "$portal_key: portal '$portal' has a leading-zero octet; write "
              . "the address in plain decimal, since nvme connect would read it "
              . "as octal\n"
                if $portal_host =~ /(?:^|\.)0[0-9]/;
        }
    }

    if (defined($opts->{tn_nvme_ctrl_loss_tmo}) && $opts->{tn_nvme_ctrl_loss_tmo} == 0) {
        die "tn_nvme_ctrl_loss_tmo must be -1 (retry forever) or a positive "
          . "number of seconds; 0 disables reconnection entirely\n";
    }

    if (defined $opts->{tn_api_retry_max}) {
        die "tn_api_retry_max must be between 0 and 10 (got $opts->{tn_api_retry_max})\n"
            if $opts->{tn_api_retry_max} < 0 || $opts->{tn_api_retry_max} > 10;
    }
    if (defined $opts->{tn_api_retry_delay}) {
        die "tn_api_retry_delay must be between 0.1 and 60 seconds (got $opts->{tn_api_retry_delay})\n"
            if $opts->{tn_api_retry_delay} < 0.1 || $opts->{tn_api_retry_delay} > 60;
    }
    if (defined $opts->{tn_broker_timeout}) {
        die "tn_broker_timeout must be between 5 and 300 seconds (got $opts->{tn_broker_timeout})\n"
            if $opts->{tn_broker_timeout} < 5 || $opts->{tn_broker_timeout} > 300;
    }

    # Validate dataset name follows ZFS naming conventions
    if ($opts->{tn_dataset}) {
        # ZFS datasets: alphanumeric, underscore, hyphen, period, slash (for hierarchy)
        if ($opts->{tn_dataset} =~ /[^a-zA-Z0-9_\-\.\/]/) {
            die "dataset name contains invalid characters: '$opts->{tn_dataset}'\n" .
                "  Allowed characters: a-z A-Z 0-9 _ - . /\n";
        }

        # Must not start or end with slash
        if ($opts->{tn_dataset} =~ /^\/|\/$/) {
            die "dataset name must not start or end with '/': '$opts->{tn_dataset}'\n";
        }

        # Must not contain double slashes
        if ($opts->{tn_dataset} =~ /\/\//) {
            die "dataset name must not contain '//': '$opts->{tn_dataset}'\n";
        }

        # Must not be empty after trimming
        if ($opts->{tn_dataset} eq '') {
            die "dataset name cannot be empty\n";
        }
    }

    # Warn if using insecure WebSocket
    if (defined $opts->{tn_api_scheme} && lc($opts->{tn_api_scheme}) eq 'ws') {
        syslog('warning',
            "[TrueNAS] Storage '$sectionId' is using insecure WebSocket (ws://). " .
            "Consider using secure WebSocket (wss://) for API communication."
        );
    }

    # Validate required fields are present
    if (!$opts->{tn_api_host}) {
        die "tn_api_host is required\n";
    }
    if (!$opts->{tn_api_key}) {
        die "tn_api_key is required\n";
    }
    if (!$opts->{tn_dataset}) {
        die "tn_dataset is required\n";
    }

    # Validate transport mode and transport-specific parameters
    my $mode = $opts->{tn_transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        # iSCSI mode requires target_iqn and discovery_portal
        if (!$opts->{tn_target_iqn}) {
            die "tn_target_iqn is required for iSCSI transport\n";
        }
        if (!$opts->{tn_discovery_portal}) {
            die "tn_discovery_portal is required for iSCSI transport\n";
        }

        # Warn if NVMe-specific parameters are set in iSCSI mode
        if ($opts->{tn_subsystem_nqn}) {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': tn_subsystem_nqn is ignored in iSCSI mode"
            );
        }
        if ($opts->{tn_hostnqn}) {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': tn_hostnqn is ignored in iSCSI mode"
            );
        }

    } elsif ($mode eq 'nvme-tcp') {
        # NVMe/TCP mode requires subsystem_nqn
        if (!$opts->{tn_subsystem_nqn}) {
            die "tn_subsystem_nqn is required for nvme-tcp transport\n";
        }

        # Validate NQN format (basic check)
        if ($opts->{tn_subsystem_nqn} !~ /^nqn\.\d{4}-\d{2}\./) {
            die "tn_subsystem_nqn must follow NVMe NQN format (e.g., nqn.2005-10.org.example:identifier)\n";
        }

        # Validate hostnqn format if provided
        if ($opts->{tn_hostnqn} && $opts->{tn_hostnqn} !~ /^nqn\./) {
            die "tn_hostnqn must follow NVMe NQN format\n";
        }

        # Warn if iSCSI-specific parameters are set in NVMe mode
        if ($opts->{tn_target_iqn}) {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': tn_target_iqn is ignored in nvme-tcp mode"
            );
        }
        if ($opts->{tn_chap_user} || $opts->{tn_chap_password}) {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': CHAP parameters are ignored in nvme-tcp mode (use tn_nvme_dhchap_secret instead)"
            );
        }
        if ($opts->{tn_use_by_path}) {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': tn_use_by_path is ignored in nvme-tcp mode (UUID paths used)"
            );
        }

    } else {
        die "Invalid transport_mode '$mode': must be 'iscsi' or 'nvme-tcp'\n";
    }

    return $opts;
}

# ======== DNS/IPv4 helper ========
# Perl 5.40 (Debian Trixie, PVE 9) removed the AUTOLOAD path that let
# Socket::gethostbyname resolve to the core builtin, so the older
# implementation died with "Undefined subroutine Socket::AUTOLOAD" on
# every FQDN tn_api_host (issue #102). Use Socket::inet_aton instead:
# it's the proper Socket export for an A-record lookup, works on every
# supported Perl, and returns the packed 4-byte form directly.
sub _host_ipv4($host) {
    return $host if $host =~ /^\d+\.\d+\.\d+\.\d+$/; # already IPv4 literal
    my $packed = eval { Socket::inet_aton($host) };
    if ($packed) {
        my $ip = inet_ntoa($packed);
        return $ip if $ip;
    }
    return $host; # fallback (could be IPv6 literal or DNS failure)
}

# ======== WebSocket JSON-RPC client ========
# Connect to ws(s)://<host>/api/current; auth via auth.login_with_api_key.
sub _ws_defaults($scfg) {
    my $scheme = $scfg->{tn_api_scheme};
    if (!$scheme) { $scheme = 'wss'; }
    elsif ($scheme =~ /^https$/i) { $scheme = 'wss'; }
    elsif ($scheme =~ /^http$/i)  { $scheme = 'ws';  }
    my $port = $scfg->{tn_api_port} // (($scheme eq 'wss') ? 443 : 80);
    return ($scheme, $port);
}
sub _ws_open($scfg) {
    my ($scheme, $port) = _ws_defaults($scfg);
    my $host = $scfg->{tn_api_host};
    # Normalize bare IPv6 literals to bracketed form (DNS names/IPv4 never contain ':').
    # Keeps PeerHost/SNI-strip/Host-header all working from the same unambiguous form.
    $host = "[$host]" if $host =~ /:/ && $host !~ /^\[/;
    my $peer = ($scfg->{tn_prefer_ipv4} // 1) ? _host_ipv4($host) : $host;
    my $path = '/api/current';
    (my $sni = $host) =~ s/^\[|\]$//g; # SNI/cert-name matching must not include IPv6 brackets

    my $sock;
    if ($scheme eq 'wss') {
        $sock = IO::Socket::SSL->new(
            PeerHost => $peer,
            PeerPort => $port,
            SSL_verify_mode => $scfg->{tn_api_insecure} ? 0x00 : 0x02,
            SSL_hostname    => $sni,
            Timeout => 15,
        ) or die "WebSocket secure connection failed (wss://): $SSL_ERROR\n  Ensure TrueNAS 25.10+ is running and WebSocket service is enabled.\n";
    } else {
        $sock = IO::Socket::INET->new(
            PeerHost => $peer, PeerPort => $port, Proto => 'tcp', Timeout => 15,
        ) or die "WebSocket connection failed (ws://): $!\n  Ensure TrueNAS 25.10+ is running and WebSocket service is enabled.\n";
    }
    # WebSocket handshake
    my $key_raw = join '', map { chr(int(rand(256))) } 1..16;
    my $key_b64 = encode_base64($key_raw, '');
    my $hosthdr = $host.":".$port;
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
    die "WebSocket handshake failed (no HTTP 101 response). Ensure TrueNAS 25.10+ is running with WebSocket API enabled.\n" if $resp !~ m#^HTTP/1\.([01]) 101#;
    my ($accept) = $resp =~ /Sec-WebSocket-Accept:\s*(\S+)/i;
    my $expect = encode_base64(sha1($key_b64 . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), '');
    die "WebSocket handshake invalid: invalid accept key. Ensure TrueNAS 25.10+ is running with WebSocket API enabled.\n" if ($accept // '') ne $expect;
    # Authenticate with API key (JSON-RPC)
    my $conn = { sock => $sock, next_id => 1 };
    _ws_rpc($conn, {
        jsonrpc => "2.0", id => $conn->{next_id}++,
        method  => "auth.login_with_api_key",
        params  => [ $scfg->{tn_api_key} ],
    }) or die "TrueNAS authentication failed: auth.login_with_api_key error. Verify API key is valid for TrueNAS 25.10+.\n";
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
    my $maskbit    = 0x80; # client must mask
    my $len = length($payload);
    my $hdr = pack('C', $fin_opcode);
    my $lenfield;
    if ($len <= 125)       { $lenfield = pack('C',   $maskbit | $len); }
    elsif ($len <= 0xFFFF) { $lenfield = pack('C n', $maskbit | 126, $len); }
    else                   { $lenfield = pack('C Q>',$maskbit | 127, $len); }
    my $mask   = join '', map { chr(int(rand(256))) } 1..4;
    my $masked = _xor_mask($payload, $mask);
    my $frame  = $hdr . $lenfield . $mask . $masked;
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
    my $sel = IO::Select->new($sock);
    while ($got < $want) {
        unless ($sock->pending() || $sel->can_read(30)) {
            return undef;  # socket not readable within 30s - connection stale
        }
        my $r = $sock->sysread($$ref, $want - $got, $got);
        return undef if !defined $r || $r == 0;
        $got += $r;
    }
    return 1;
}
sub _ws_recv_text {
    my $sock = shift;
    my $message = ''; # Accumulator for fragmented messages

    while (1) {
        my $hdr;
        _ws_read_exact($sock, \$hdr, 2) or die "WS read hdr failed";
        my ($b1, $b2) = unpack('CC', $hdr);
        my $fin    = ($b1 & 0x80) ? 1 : 0; # FIN bit
        my $opcode = $b1 & 0x0f;
        my $masked = ($b2 & 0x80) ? 1 : 0; # server MUST NOT mask
        my $len    = ($b2 & 0x7f);

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
        if ($len > 0) {
            _ws_read_exact($sock, \$payload, $len) or die "WS payload read fail";
            if ($masked) { $payload = _xor_mask($payload, $mask_key); }
        }

        # Handle different frame types
        if ($opcode == 0x01) {
            # Text frame (start of message or unfragmented message)
            $message = $payload;
            return $message if $fin; # Complete unfragmented message
            # Otherwise, continue reading continuation frames
        } elsif ($opcode == 0x00) {
            # Continuation frame
            $message .= $payload;
            return $message if $fin; # Complete fragmented message
        } elsif ($opcode == 0x08) {
            # Close frame
            my $code = $len >= 2 ? unpack('n', substr($payload, 0, 2)) : 0;
            my $reason = $len > 2 ? substr($payload, 2) : '';
            die "WS closed by server (code: $code, reason: $reason)";
        } elsif ($opcode == 0x09) {
            # Ping frame - respond with pong
            my $pong_hdr = pack('C', 0x8A); # FIN=1, opcode=0xA
            my $pong_len;
            if ($len <= 125)       { $pong_len = pack('C', $len); }
            elsif ($len <= 0xFFFF) { $pong_len = pack('C n', 126, $len); }
            else                   { $pong_len = pack('C Q>', 127, $len); }
            $sock->syswrite($pong_hdr . $pong_len . $payload);
            # Continue reading next frame
        } elsif ($opcode == 0x0A) {
            # Pong frame - ignore and continue
        } else {
            die "WS: unexpected opcode $opcode";
        }
    }
}
sub _ws_rpc {
    my ($conn, $obj) = @_;

    # Broker-proxied connections: forward the JSON-RPC call over the
    # Unix-socket round trip instead of doing WS framing locally. The
    # broker daemon owns the upstream TLS+WS+auth and pools sessions
    # across every PVE process on this node, eliminating per-process
    # re-authentication (D2).
    return _broker_rpc($conn, $obj) if $conn->{type} && $conn->{type} eq 'broker';

    my $request_id = $obj->{id};
    my $text = encode_json($obj);
    _ws_send_text($conn->{sock}, $text);

    # Read frames until we get a response matching our request ID.
    # TrueNAS may send unsolicited messages (event notifications, subscription
    # events) that desynchronize a naive send-then-read-next-frame approach.
    # JSON-RPC 2.0 uses the id field to match responses to requests.
    my $max_skip = 10;
    for (my $skipped = 0; $skipped <= $max_skip; $skipped++) {
        my $resp = _ws_recv_text($conn->{sock});
        my $decoded = eval { decode_json($resp) };
        if ($@ || !$decoded) {
            my $len = length($resp // '');
            my $preview = substr($resp // '', 0, 200);
            _log(undef, 0, 'err', "[TrueNAS] JSON decode failed (len=$len): $@ Preview: $preview");
            die "JSON-RPC decode failed: $@";
        }

        # Match response to our request by id
        if (defined($request_id) && ref($decoded) eq 'HASH'
            && defined($decoded->{id}) && "$decoded->{id}" eq "$request_id") {
            die "JSON-RPC error: ".encode_json($decoded->{error}) if exists $decoded->{error};
            return $decoded->{result};
        }

        # No id in request (shouldn't happen) — accept the first response
        if (!defined($request_id)) {
            die "JSON-RPC error: ".encode_json($decoded->{error})
                if ref($decoded) eq 'HASH' && exists $decoded->{error};
            return ref($decoded) eq 'HASH' ? $decoded->{result} : $decoded;
        }

        # Non-matching frame — log and continue reading
        my $got_id = ref($decoded) eq 'HASH' ? ($decoded->{id} // 'undef') : 'non-object';
        _log(undef, 1, 'warning',
            "[TrueNAS] _ws_rpc: skipping non-matching frame "
            . "(expected id=$request_id, got id=$got_id)");
    }

    die "JSON-RPC: no matching response after skipping $max_skip frames "
        . "(request id=$request_id, method=$obj->{method})";
}

# ======== Session broker client (D2 mitigation) ========
# When /run/truenas-plugin/broker.sock is present, every plugin process on
# this node funnels JSON-RPC through the broker daemon. The broker holds a
# single authenticated WebSocket per (host, api_key) pair, eliminating the
# per-process re-auth that previously fed the TN login rate limiter.
#
# Wire protocol: newline-delimited JSON over Unix socket, ONE round trip
# per connection. Request envelope keeps the broker's stable `api_*` field
# names; we map this branch's `tn_api_*` scfg keys to that wire shape at
# send time so the broker daemon never needs to know about the rename.
use constant BROKER_SOCKET_PATH => '/run/truenas-plugin/broker.sock';

sub _broker_open_socket {
    return undef unless -S BROKER_SOCKET_PATH;
    require IO::Socket::UNIX;
    my $sock = IO::Socket::UNIX->new(
        Peer => BROKER_SOCKET_PATH,
        Type => 1,    # SOCK_STREAM
    );
    return $sock;
}

# Try to obtain a broker-proxied connection wrapper for this $scfg.
# Returns a connection hashref with type=>'broker' on success, undef on
# failure (caller falls back to direct WS).
sub _broker_try_open($scfg) {
    my $sock = _broker_open_socket() or return undef;
    return { type => 'broker', sock => $sock, scfg => $scfg, next_id => 1 };
}

# Forward one JSON-RPC call through the broker. The broker reads a single
# newline-terminated JSON request, performs the upstream RPC on its pooled
# WS, and returns a single newline-terminated JSON response with either
# `result` or `error`. We then translate to the same return/die contract
# the rest of the plugin expects from _ws_rpc.
sub _broker_rpc {
    my ($conn, $obj) = @_;
    my $scfg = $conn->{scfg};

    # Map this branch's tn_*-prefixed scfg keys to the broker daemon's
    # stable api_* wire field names. The daemon is shared with
    # broker-service which still uses the old key names; keeping the wire
    # form constant means a single broker binary serves both branches.
    my $req = {
        scfg => {
            api_host     => $scfg->{tn_api_host},
            api_key      => $scfg->{tn_api_key},
            api_scheme   => $scfg->{tn_api_scheme}   // 'wss',
            api_port     => $scfg->{tn_api_port},
            api_insecure => $scfg->{tn_api_insecure} // 0,
            prefer_ipv4  => $scfg->{tn_prefer_ipv4}  // 1,
        },
        method => $obj->{method},
        params => $obj->{params} // [],
    };
    my $payload = encode_json($req) . "\n";

    my $sock = $conn->{sock};
    # Deadline-bounded round trip. Without this a wedged broker (stuck
    # upstream WS, lost middlewared, hung systemd unit) blocks every PVE
    # operation indefinitely. The deadline applies to the whole round
    # trip, not per-call to sysread, so a slow-but-progressing TN won't
    # falsely trip it. Tunable via tn_broker_timeout (seconds); default
    # 60 s -- bumped from 30 s after test_run6/truenas-2026-08-13 cluster
    # runs showed pool.dataset.get_instance and iscsi.extent.query hitting
    # the deadline under concurrent 3-node load. 30 s was aligned with the
    # per-WS-frame envelope; the broker deadline covers the whole round
    # trip (queue + upstream + return) so it needs headroom above that.
    my $timeout = $scfg->{tn_broker_timeout} // 60;
    my $deadline = time() + $timeout;
    my $sel = IO::Select->new($sock);

    my $result;
    eval {
        my $written = 0;
        while ($written < length($payload)) {
            my $remaining = $deadline - time();
            die "broker: write timeout after ${timeout}s" if $remaining <= 0;
            my @ready = $sel->can_write($remaining);
            die "broker: write timeout after ${timeout}s" unless @ready;
            my $n = $sock->syswrite(substr($payload, $written));
            die "broker: write failed: $!" unless defined $n && $n > 0;
            $written += $n;
        }

        my $buf = '';
        while (1) {
            my $remaining = $deadline - time();
            die "broker: read timeout after ${timeout}s" if $remaining <= 0;
            my @ready = $sel->can_read($remaining);
            die "broker: read timeout after ${timeout}s" unless @ready;
            my $got = $sock->sysread(my $chunk, 4096);
            die "broker: read failed: $!" unless defined $got;
            die "broker: EOF before complete response" if $got == 0;
            $buf .= $chunk;
            last if index($buf, "\n") >= 0;
        }
        my ($line) = split /\n/, $buf, 2;
        my $decoded = eval { decode_json($line) };
        die "broker: bad response: $@" if $@ || ref($decoded) ne 'HASH';

        die "JSON-RPC error: $decoded->{error}" if exists $decoded->{error};
        $result = $decoded->{result};
    };
    my $err = $@;
    # One round trip per broker Unix-socket connection: close after use.
    eval { $sock->close(); };
    die $err if $err;
    return $result;
}

sub _broker_close($conn) {
    return unless $conn && $conn->{sock};
    eval { $conn->{sock}->close(); };
}

# ======== Persistent WebSocket Connection Management ========
my %_ws_connections; # Global connection cache
my $_ws_creator_pid = $$; # Track PID to detect fork

sub _ws_connection_key($scfg) {
    # Create a unique key for this storage configuration
    my $host = $scfg->{tn_api_host};
    my $key = $scfg->{tn_api_key};
    return "$host:$key";
}

sub _ws_get_persistent($scfg) {
    # Broker fast path: if /run/truenas-plugin/broker.sock exists, every call
    # in this process gets a fresh broker-client wrapper. The broker holds
    # the upstream WS so we never call auth.login_with_api_key here.
    # Broker-conn objects are NOT cached in %_ws_connections — Unix socket
    # connections are cheap (no auth round trip) and avoiding the cache
    # sidesteps the fork-detection/SSL-DESTROY path that follows.
    if (my $bconn = _broker_try_open($scfg)) {
        return $bconn;
    }

    # Broker socket not present. In production, this means the broker service
    # is stopped or was never installed (e.g. plugin copied by hand instead of
    # installed from the .deb). Direct WS mode re-authenticates in every
    # forked PVE process and trips the TN middlewared login rate limiter, so
    # falling back silently produces the D2/D3 failure pattern we ship the
    # broker to prevent (see test_run4 notes-2026-07-13.md).
    #
    # Refuse to proceed by default. The escape hatch is the
    # TRUENAS_PLUGIN_ALLOW_DIRECT_WS=1 env var, intended for developer use
    # against a private TrueNAS where the login limiter is not a concern.
    if (!$ENV{TRUENAS_PLUGIN_ALLOW_DIRECT_WS}) {
        die "[TrueNAS] broker socket missing at " . BROKER_SOCKET_PATH . ".\n" .
            "  The truenas-plugin-broker service is required — direct WS mode\n" .
            "  re-authenticates in every forked PVE process and will trip the\n" .
            "  TrueNAS API login rate limiter. Fix:\n" .
            "    1. Install the plugin from the .deb (dpkg -i truenas-proxmox-plugin_*.deb),\n" .
            "       do not copy TrueNASPlugin.pm by hand.\n" .
            "    2. systemctl enable --now truenas-plugin-broker.service\n" .
            "    3. Verify: ls -l " . BROKER_SOCKET_PATH . "\n" .
            "  For development against a private TrueNAS, set\n" .
            "  TRUENAS_PLUGIN_ALLOW_DIRECT_WS=1 in the environment.\n";
    }

    _log($scfg, 0, 'warning',
        "[TrueNAS] broker socket missing; TRUENAS_PLUGIN_ALLOW_DIRECT_WS is set, " .
        "using direct WS. This bypasses D2/D3 rate-limit protection and is not " .
        "supported in production."
    );

    # Fork detection: if we're in a child process, inherited connections are invalid
    # CRITICAL: When child exits, Perl's global destruction calls DESTROY on all objects,
    # including inherited IO::Socket::SSL sockets. DESTROY calls SSL_free() which corrupts
    # the parent's SSL state (shared via fork).
    #
    # SOLUTION: Rebless inherited sockets into NullDestructor class. This makes DESTROY
    # a complete no-op - no SSL cleanup, no FD close, nothing. The socket will "leak"
    # in the child process, but that's fine:
    # - Child exits soon anyway
    # - OS reclaims all resources on process exit
    # - No corruption can occur because no cleanup code runs
    #
    # IMPORTANT: Do NOT clear %_ws_connections or set sock=undef - that triggers DESTROY!
    # Just rebless and update the PID so new connections get created on next call.
    if ($$ != $_ws_creator_pid) {
        eval { _log($scfg, 2, 'debug', "[TrueNAS] Fork detected (creator PID $_ws_creator_pid, current PID $$), neutering inherited connections"); };
        for my $conn (values %_ws_connections) {
            if ($conn && $conn->{sock}) {
                # Rebless socket into NullDestructor - makes DESTROY a complete no-op
                # This prevents ALL cleanup code from running (SSL, IO::Socket, Perl IO layer)
                bless $conn->{sock}, 'PVE::Storage::Custom::TrueNASPlugin::NullDestructor';
            }
        }
        # Clear the hash so child creates fresh connections, but the neutered socket
        # objects remain in memory until child exits (harmless - OS cleans up)
        %_ws_connections = ();
        $_ws_creator_pid = $$;
    }

    my $key = _ws_connection_key($scfg);
    my $conn = $_ws_connections{$key};

    # Create new connection if needed
    if (!$conn) {
        $conn = _ws_open($scfg);
        $_ws_connections{$key} = $conn if $conn;
    }

    return $conn;
}

sub _ws_cleanup_connections() {
    # Clean up all stored connections (called during shutdown)
    # Fork safety: if we're in a child process, don't close parent's sockets
    if ($$ != $_ws_creator_pid) {
        # Neuter inherited sockets and clear hash (same pattern as _ws_get_persistent)
        for my $conn (values %_ws_connections) {
            if ($conn && $conn->{sock}) {
                bless $conn->{sock}, 'PVE::Storage::Custom::TrueNASPlugin::NullDestructor';
            }
        }
        %_ws_connections = ();
        $_ws_creator_pid = $$;
        return;
    }
    # Normal cleanup in parent process
    for my $key (keys %_ws_connections) {
        my $conn = $_ws_connections{$key};
        if ($conn && $conn->{sock}) {
            eval { $conn->{sock}->close(); };
        }
    }
    %_ws_connections = ();
}

# ======== Bulk Operations Helper ========
sub _api_bulk_call($scfg, $method_name, $params_array, $description = undef) {
    # Use core.bulk to batch multiple calls of the same method
    # $params_array should be an array of parameter arrays

    # Check if bulk operations are enabled (default: enabled)
    my $bulk_enabled = $scfg->{tn_enable_bulk_operations} // 1;
    if (!$bulk_enabled) {
        die "Bulk operations are disabled in storage configuration";
    }

    # Bulk operations are always write operations, use ephemeral connection.
    # The trailing sub { die ... } fallback was aspirational -- _api_call_mutate
    # has an exact 3-arg signature ($scfg, $ws_method, $ws_params) and Perl's
    # native signature enforcement dies with "Too many arguments for
    # subroutine ... (got 4; expected 3)" before the call ever reaches TN.
    # The intended "die if the broker/WS transport is unavailable" behaviour
    # already happens inside _api_call_mutate's own broker/connection paths,
    # so the caller-supplied fallback was redundant even if the signature
    # had accepted it. Issue #77 (WarlockSyno) option 1: drop it.
    return _api_call_mutate($scfg, 'core.bulk', [$method_name, $params_array, $description]);
}

# Bulk snapshot deletion helper
sub _bulk_snapshot_delete($scfg, $snapshot_list) {
    return [] if !$snapshot_list || !@$snapshot_list;

    # Prepare parameter arrays for each snapshot deletion
    my @params_array = map { [$_] } @$snapshot_list;

    my $results = _api_bulk_call($scfg, 'pool.snapshot.delete', \@params_array,
        'Deleting snapshot {0}');

    # Check if results is actually an array reference or a job ID
    if (!ref($results) || ref($results) ne 'ARRAY') {
        # Check if we got a numeric job ID (TrueNAS async operation)
        if (defined $results && $results =~ /^\d+$/) {
            # This is a job ID from an async operation - wait for completion
            _log($scfg, 1, 'info', "[TrueNAS] Bulk snapshot deletion started (job ID: $results)");

            my $job_result = _wait_for_job_completion($scfg, $results, 30); # 30 second timeout for bulk snapshots

            if ($job_result->{success}) {
                _log($scfg, 1, 'info', "[TrueNAS] Bulk snapshot deletion completed successfully");
                return []; # Return empty error list (success)
            } else {
                my $error = "[TrueNAS] Bulk snapshot deletion job failed: " . $job_result->{error};
                _log($scfg, 0, 'err', $error);
                return [$error]; # Return error list
            }
        } else {
            # Unknown response type
            die "Bulk operation returned unexpected result type: " . (ref($results) || 'scalar') .
                " (value: " . (defined $results ? $results : 'undef') . "). " .
                "Try disabling bulk operations by setting enable_bulk_operations=0 in storage config.";
        }
    }

    # Process results and collect any errors
    my @errors;
    for my $i (0 .. $#{$results}) {
        my $result = $results->[$i];
        if ($result->{error}) {
            push @errors, "Failed to delete $snapshot_list->[$i]: $result->{error}";
        }
    }

    return \@errors;
}

# Bulk iSCSI targetextent deletion helper
sub _bulk_targetextent_delete($scfg, $targetextent_ids) {
    return [] if !$targetextent_ids || !@$targetextent_ids;

    # Prepare parameter arrays for each targetextent deletion
    my @params_array = map { [$_] } @$targetextent_ids;

    my $results = _api_bulk_call($scfg, 'iscsi.targetextent.delete', \@params_array,
        'Deleting targetextent {0}');

    # Process results and collect any errors
    my @errors;
    for my $i (0 .. $#{$results}) {
        my $result = $results->[$i];
        if ($result->{error}) {
            push @errors, "Failed to delete targetextent $targetextent_ids->[$i]: $result->{error}";
        }
    }

    return \@errors;
}

# Bulk iSCSI extent deletion helper
sub _bulk_extent_delete($scfg, $extent_ids) {
    return [] if !$extent_ids || !@$extent_ids;

    # Prepare parameter arrays for each extent deletion
    my @params_array = map { [$_] } @$extent_ids;

    my $results = _api_bulk_call($scfg, 'iscsi.extent.delete', \@params_array,
        'Deleting extent {0}');

    # Process results and collect any errors
    my @errors;
    for my $i (0 .. $#{$results}) {
        my $result = $results->[$i];
        if ($result->{error}) {
            push @errors, "Failed to delete extent $extent_ids->[$i]: $result->{error}";
        }
    }

    return \@errors;
}

# Enhanced cleanup helper that can use bulk operations when possible
sub _cleanup_multiple_volumes($scfg, $volume_info_list) {
    # $volume_info_list is array of hashrefs: [{zname, extent_id, targetextent_id}, ...]
    return if !$volume_info_list || !@$volume_info_list;

    my @targetextent_ids = grep { defined } map { $_->{targetextent_id} } @$volume_info_list;
    my @extent_ids = grep { defined } map { $_->{extent_id} } @$volume_info_list;
    my @dataset_names = grep { defined } map { $_->{zname} } @$volume_info_list;

    my @all_errors;
    my $bulk_enabled = $scfg->{tn_enable_bulk_operations} // 1;

    # Delete targetextents - use bulk if enabled and multiple items
    if (@targetextent_ids > 1 && $bulk_enabled) {
        my $errors = eval { _bulk_targetextent_delete($scfg, \@targetextent_ids) };
        if ($@) {
            # Fall back to individual deletion if bulk fails
            foreach my $id (@targetextent_ids) {
                eval {
                    _api_call($scfg, 'iscsi.targetextent.delete', [$id]);
                };
                push @all_errors, "Failed to delete targetextent $id: $@" if $@;
            }
        } else {
            push @all_errors, @$errors if $errors && @$errors;
        }
    } else {
        # Individual deletion for single item or when bulk disabled
        foreach my $id (@targetextent_ids) {
            eval {
                _api_call($scfg, 'iscsi.targetextent.delete', [$id]);
            };
            push @all_errors, "Failed to delete targetextent $id: $@" if $@;
        }
    }

    # Delete extents - use bulk if enabled and multiple items
    if (@extent_ids > 1 && $bulk_enabled) {
        my $errors = eval { _bulk_extent_delete($scfg, \@extent_ids) };
        if ($@) {
            # Fall back to individual deletion if bulk fails
            foreach my $id (@extent_ids) {
                eval {
                    _api_call($scfg, 'iscsi.extent.delete', [$id]);
                };
                push @all_errors, "Failed to delete extent $id: $@" if $@;
            }
        } else {
            push @all_errors, @$errors if $errors && @$errors;
        }
    } else {
        # Individual deletion for single item or when bulk disabled
        foreach my $id (@extent_ids) {
            eval {
                _api_call($scfg, 'iscsi.extent.delete', [$id]);
            };
            push @all_errors, "Failed to delete extent $id: $@" if $@;
        }
    }

    # Datasets are typically deleted individually since they might have different parameters
    for my $dataset (@dataset_names) {
        eval {
            my $full_ds = $scfg->{tn_dataset} . '/' . $dataset;
            my $id = URI::Escape::uri_escape($full_ds);
            my $payload = { recursive => JSON::PP::true, force => JSON::PP::true };
            _api_call($scfg, 'pool.dataset.delete', [$full_ds, $payload]);
            _invalidate_status_capacity_cache(undef, $scfg);
        };
        push @all_errors, "Failed to delete dataset $dataset: $@" if $@;
    }

    return \@all_errors;
}

# Public bulk operations interface for external use (like test scripts)
sub bulk_delete_snapshots {
    my ($class, $scfg, $storeid, $volname, $snapshot_names) = @_;
    return [] if !$snapshot_names || !@$snapshot_names;

    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{tn_dataset} . '/' . $zname;

    # Convert snapshot names to full snapshot names
    my @full_snapshots = map { "$full\@$_" } @$snapshot_names;

    # Use bulk deletion
    return _bulk_snapshot_delete($scfg, \@full_snapshots);
}

# ======== Job completion helper ========
sub _wait_for_job_completion {
    my ($scfg, $job_id, $timeout_seconds) = @_;

    $timeout_seconds //= 60; # Default 60 second timeout

    _log($scfg, 1, 'info', "[TrueNAS] Waiting for job $job_id to complete (timeout: ${timeout_seconds}s)");

    # Fast polling for first 5 seconds (100ms intervals), then 1s intervals
    my $elapsed = 0;
    my $attempt = 0;
    my $consecutive_failures = 0;

    while ($elapsed < $timeout_seconds) {
        $attempt++;

        # Use faster polling for first 5 seconds to catch quick completions
        my $poll_delay = ($elapsed < 5) ? 0.1 : JOB_POLL_DELAY_S;
        select(undef, undef, undef, $poll_delay);
        $elapsed += $poll_delay;

        my $job_status;
        eval {
            # Issue #76 (WarlockSyno, verified against TN 25.10.2.1): TN does
            # not export a 'core.call' method. Calling it produces JSON-RPC
            # code -32601 ("Method does not exist"), so every job-completion
            # poll returns an eval error and _wait_for_job_completion reports
            # a false failure even for jobs that actually completed
            # successfully server-side. Also, the inner params [{ id => ... }]
            # were the wrong shape for 'core.get_jobs' anyway -- like every
            # other .query method it takes a filter array. Fix: call
            # 'core.get_jobs' directly with a real filter.
            $job_status = _api_call($scfg, 'core.get_jobs',
                [[ ["id", "=", int($job_id)] ]]);
        };

        if ($@) {
            $consecutive_failures++;
            _log($scfg, 1, 'warning', "[TrueNAS] Failed to check job status for job $job_id (consecutive failures: $consecutive_failures): $@");

            # Abort if API is consistently failing (likely unreachable)
            if ($consecutive_failures >= 5) {
                _log($scfg, 0, 'err', "[TrueNAS] Job $job_id check failing repeatedly ($consecutive_failures consecutive failures), aborting");
                return { success => 0, error => "API unavailable: $@" };
            }
            next; # Continue trying
        }

        # Reset consecutive failures on successful API call
        $consecutive_failures = 0;

        if ($job_status && ref($job_status) eq 'ARRAY' && @$job_status > 0) {
            my $job = $job_status->[0];
            my $state = $job->{state} // 'UNKNOWN';

            if ($state eq 'SUCCESS') {
                _log($scfg, 1, 'info', "[TrueNAS] Job $job_id completed successfully");
                return { success => 1 };
            } elsif ($state eq 'FAILED') {
                my $error = $job->{error} // $job->{exc_info} // 'Unknown error';
                _log($scfg, 0, 'err', "[TrueNAS] Job $job_id failed: $error");
                return { success => 0, error => $error };
            } elsif ($state eq 'RUNNING' || $state eq 'WAITING') {
                # Job still in progress, continue waiting
                if (int($elapsed) % 10 == 0 && $poll_delay >= 1) { # Log every 10 seconds (but not during fast polling)
                    _log($scfg, 2, 'debug', "[TrueNAS] Job $job_id still $state (" . int($elapsed) . "s elapsed)");
                }
                next;
            } else {
                _log($scfg, 1, 'warning', "[TrueNAS] Job $job_id in unexpected state: $state");
                next;
            }
        } else {
            _log($scfg, 2, 'debug', "[TrueNAS] Could not retrieve status for job $job_id (attempt $attempt)");
            next;
        }
    }

    # Timeout reached
    _log($scfg, 0, 'err', "[TrueNAS] Job $job_id timed out after ${timeout_seconds} seconds");
    return { success => 0, error => "Job timed out after ${timeout_seconds} seconds" };
}

# Helper function to handle potential async job results
sub _handle_api_result_with_job_support {
    my ($scfg, $result, $operation_name, $timeout_seconds) = @_;

    $timeout_seconds //= 60;

    # If result is a job ID (numeric), wait for completion
    if (defined $result && !ref($result) && $result =~ /^\d+$/) {
        _log($scfg, 1, 'info', "[TrueNAS] $operation_name started (job ID: $result)");

        my $job_result = _wait_for_job_completion($scfg, $result, $timeout_seconds);

        if ($job_result->{success}) {
            _log($scfg, 1, 'info', "[TrueNAS] $operation_name completed successfully");
            return { success => 1, result => undef };
        } else {
            my $error = "[TrueNAS] $operation_name job failed: " . $job_result->{error};
            _log($scfg, 0, 'err', $error);
            return { success => 0, error => $error };
        }
    }

    # For non-job results, return as-is (synchronous operation)
    return { success => 1, result => $result };
}

# Helper function to verify kernel devices are disconnected
sub _verify_devices_disconnected {
    my ($scfg, $device_paths, $timeout_s) = @_;
    $timeout_s //= DEVICE_CLEANUP_VERIFY_TIMEOUT_S;

    return 1 unless $device_paths && @$device_paths;  # Nothing to verify

    _log($scfg, 2, 'debug', "[TrueNAS] Verifying " . scalar(@$device_paths) . " device(s) are disconnected");

    # Poll until devices are gone or timeout
    for my $attempt (1..$timeout_s*10) {  # Check every 100ms
        my $all_gone = 1;
        for my $path (@$device_paths) {
            if (-e $path) {
                $all_gone = 0;
                last;
            }
        }
        if ($all_gone) {
            _log($scfg, 2, 'debug', "[TrueNAS] All devices disconnected successfully");
            return 1;
        }
        select(undef, undef, undef, 0.1);  # 100ms delay
    }

    _log($scfg, 1, 'warning', "[TrueNAS] Device disconnect verification timed out after ${timeout_s}s");
    return 0;  # Timeout
}

# Helper function to parse dataset deletion errors
sub _parse_dataset_error {
    my ($error_string) = @_;

    return {
        type => 'not_found',
        retryable => 0,
    } if $error_string =~ /does not exist|ENOENT|InstanceNotFound/i;

    return {
        type => 'busy',
        retryable => 1,
    } if $error_string =~ /busy|in use|mounted|cannot.*delete/i;

    return {
        type => 'other',
        retryable => 0,
    };
}

# Helper function to delete dataset with retry logic on "busy" errors
sub _delete_dataset_with_retry {
    my ($scfg, $full_ds, $max_retries) = @_;
    $max_retries //= DATASET_DELETE_RETRY_COUNT;

    my $id = URI::Escape::uri_escape($full_ds);
    my $payload = { recursive => JSON::PP::true, force => JSON::PP::true };

    for my $attempt (1..$max_retries) {
        eval {
            _log($scfg, 1, 'info', "[TrueNAS] Deleting dataset $full_ds (attempt $attempt/$max_retries)");
            my $result = _api_call_mutate($scfg,'pool.dataset.delete',[ $full_ds, $payload ]);

            my $job_result = _handle_api_result_with_job_support($scfg, $result, "dataset deletion for $full_ds", DATASET_DELETE_TIMEOUT_S);
            if (!$job_result->{success}) {
                die $job_result->{error};
            }
            _invalidate_status_capacity_cache(undef, $scfg);
            _log($scfg, 1, 'info', "[TrueNAS] Successfully deleted dataset $full_ds");
        };

        if (!$@) {
            return;  # Success
        }

        my $err = $@;
        my $error_info = _parse_dataset_error($err);

        # If already gone, treat as success
        if ($error_info->{type} eq 'not_found') {
            _log($scfg, 2, 'debug', "[TrueNAS] Dataset $full_ds already deleted");
            return;
        }

        # If busy and more retries available, wait and retry
        if ($error_info->{type} eq 'busy' && $attempt < $max_retries) {
            my $delay = 2 ** ($attempt - 1);  # Exponential backoff: 1s, 2s, 4s
            _log($scfg, 1, 'info', "[TrueNAS] Dataset busy, retrying in ${delay}s... ($err)");
            sleep($delay);
            next;
        }

        # Otherwise, this is a real error
        die $err;
    }

    # Should not reach here, but if we do, it means all retries failed
    die "Failed to delete dataset $full_ds after $max_retries attempts";
}

# ======== WebSocket API operations ========
# $opts is an optional hashref with:
#   - retry_opts: options passed to _retry_with_backoff
sub _api_call($scfg, $ws_method, $ws_params, $opts = undef) {
    my $retry_opts = $opts && $opts->{retry_opts};

    # Level 2: Verbose - log all API calls with parameters
    if ($ws_params && ref($ws_params) eq 'ARRAY' && @$ws_params) {
        _log($scfg, 2, 'debug', "[TrueNAS] _api_call: method=$ws_method, conn=persistent, params=" . encode_json($ws_params));
    } else {
        _log($scfg, 2, 'debug', "[TrueNAS] _api_call: method=$ws_method, conn=persistent");
    }

    return _retry_with_backoff($scfg, "WS $ws_method", sub {
        my $conn = _ws_get_persistent($scfg);
        my $res = eval {
            _ws_rpc($conn, {
                jsonrpc => "2.0", id => $conn->{next_id}++, method => $ws_method, params => $ws_params // [],
            });
        };
        if (my $err = $@) {
            # On connection errors, invalidate the cached connection so the
            # next retry gets a fresh one instead of re-pinging a dead socket
            if (_is_connection_error($err)) {
                my $key = _ws_connection_key($scfg);
                if ($conn && $conn->{sock}) {
                    eval { $conn->{sock}->close(); };
                }
                delete $_ws_connections{$key};
                _log($scfg, 1, 'info', "[TrueNAS] _api_call: invalidated dead persistent connection for $ws_method");
            }
            die $err;
        }

        # Level 2: Verbose - log API response
        _log($scfg, 2, 'debug', "[TrueNAS] _api_call: response from $ws_method: " . (ref($res) ? encode_json($res) : ($res // 'undef')));

        return $res;
    }, $retry_opts);
}

# Helper identifying API calls that mutate TrueNAS state
sub _api_call_mutate($scfg, $ws_method, $ws_params) {
    return _api_call($scfg, $ws_method, $ws_params);
}

# ======== TrueNAS API ops (WebSocket) ========
sub _tn_get_target($scfg) {
    return _api_call($scfg, 'iscsi.target.query', []);
}
sub _tn_targetextents($scfg) {
    my $storage_id = _cache_host_key($scfg);

    # Try cache first (but with shorter TTL since mappings change more frequently)
    my $cached = _get_cached($storage_id, 'targetextents');
    return $cached if $cached;

    # Cache miss - fetch from API
    my $res = _api_call($scfg, 'iscsi.targetextent.query', []);

    # Cache with shorter TTL for dynamic data
    return _set_cache($storage_id, 'targetextents', $res);
}
sub _tn_extents($scfg) {
    my $storage_id = _cache_host_key($scfg);

    # Try cache first
    my $cached = _get_cached($storage_id, 'extents');
    return $cached if $cached;

    # Cache miss - fetch from API
    my $res = _api_call($scfg, 'iscsi.extent.query', []);

    # Cache and return
    return _set_cache($storage_id, 'extents', $res);
}

sub _tn_snapshots($scfg) {
    return _api_call($scfg, 'pool.snapshot.query', []);
}

# ---------- Narrow-query helpers ----------
# The full-list _tn_extents / _tn_targetextents scans above serialize every
# extent / mapping on the TN side and pull them back over the wire, which
# scales linearly with total volume count on the array. Under concurrent
# multi-node alloc/free load the cache is invalidated on every mutation, so
# hot paths that only need one row (find-my-zvol, look-up-by-name,
# resolve-my-mapping) were paying the full-list cost each time -- observed
# as multi-second lock hold in cluster_test_run 2026-08-14 3-node runs where
# vm_disk_buses and disk_thin_discard hit the pveproxy 60 s / test-suite
# 180 s ceilings. The narrow helpers push the filter to middlewared using
# TN's query-filter syntax (see t/rate-limit/11-alloc-extent-namespace-reuse.t)
# so the response carries at most the row(s) we asked for. They deliberately
# do NOT cache: callers that need a fresh answer (post-mutation lookups,
# Fix B name-conflict recovery, targetextent stale-cache recheck) all fell
# into the invalidate-and-refetch pattern anyway.
sub _tn_extent_query_by_disk($scfg, $zvol_path) {
    return _api_call($scfg, 'iscsi.extent.query', [ [ [ 'disk', '=', $zvol_path ] ] ]);
}
sub _tn_extent_query_by_name($scfg, $name) {
    return _api_call($scfg, 'iscsi.extent.query', [ [ [ 'name', '=', $name ] ] ]);
}
sub _tn_targetextent_query_by_target_extent($scfg, $target_id, $extent_id) {
    return _api_call($scfg, 'iscsi.targetextent.query',
        [ [ [ 'target', '=', $target_id ], [ 'extent', '=', $extent_id ] ] ]);
}
sub _tn_targetextent_query_by_extent($scfg, $extent_id) {
    return _api_call($scfg, 'iscsi.targetextent.query',
        [ [ [ 'extent', '=', $extent_id ] ] ]);
}

sub _tn_global($scfg) {
    return _api_call($scfg, 'iscsi.global.config', []);
}

# Returns the pool record for the dataset's containing pool, or undef.
# Cached for $CACHE_TTL (60s) since pool health changes slowly.
sub _tn_pool_health($scfg) {
    my ($pool_name) = split('/', $scfg->{tn_dataset}, 2);
    return undef if !$pool_name;

    my $host_key = _cache_host_key($scfg);
    my $cached = _get_cached($host_key, "pool_health:$pool_name");
    return $cached if defined $cached;

    my $pools = eval {
        _api_call($scfg, 'pool.query', [[ ["name", "=", $pool_name] ]]);
    };
    return undef if $@ || !$pools || !@$pools;

    return _set_cache($host_key, "pool_health:$pool_name", $pools->[0]);
}

# PVE passes size in KiB; TrueNAS expects bytes (volsize) and supports 'sparse'
sub _tn_dataset_create($scfg, $full, $size_kib, $blocksize) {
    my $bytes = int($size_kib) * 1024;
    # All six of these must be sent explicitly, not omitted: TrueNAS 25.10.4's
    # legacy API shim leaves omitted optional fields as unresolved _NotRequired
    # sentinels instead of real defaults, crashing pool.dataset.create both in
    # validation and in audit-log serialization (#58, #65, #78). special_small_block_size
    # must be 'INHERIT' specifically - 0 fails a ZFS-level check, null fails Pydantic.
    my $payload = {
        name                     => $full,
        type                     => 'VOLUME',
        volsize                  => $bytes,
        sparse                   => ($scfg->{tn_sparse} // 1) ? JSON::PP::true : JSON::PP::false,
        volblocksize             => _normalize_blocksize($blocksize) // '16K',
        snapdev                  => 'INHERIT',
        reservation              => 0,
        refreservation           => 0,
        special_small_block_size => 'INHERIT',
        force_size               => JSON::PP::false,
    };
    my $result = _api_call_mutate($scfg, 'pool.dataset.create', [ $payload ]);
    _invalidate_status_capacity_cache(undef, $scfg);
    return $result;
}
sub _tn_dataset_delete($scfg, $full) {
    my $id = uri_escape($full);

    _log($scfg, 1, 'info', "[TrueNAS] _tn_dataset_delete: deleting $full (recursive=true)");
    my $result = _api_call_mutate($scfg, 'pool.dataset.delete', [ $full, { recursive => JSON::PP::true } ]);

    # Handle potential async job for dataset deletion
    my $job_result = _handle_api_result_with_job_support($scfg, $result, "dataset deletion (helper) for $full", 60);
    if (!$job_result->{success}) {
        die $job_result->{error};
    }

    _invalidate_status_capacity_cache(undef, $scfg);
    _log($scfg, 1, 'info', "[TrueNAS] _tn_dataset_delete: deleted $full");
    return $job_result->{result};
}
sub _tn_dataset_get($scfg, $full, $opts = undef) {
    my $api_opts;
    if ($opts && exists($opts->{retry_max})) {
        $api_opts = { retry_opts => { retry_max => $opts->{retry_max} } };
    }
    if ($opts && exists($opts->{retry_delay})) {
        $api_opts //= { retry_opts => {} };
        $api_opts->{retry_opts}{retry_delay} = $opts->{retry_delay};
    }
    return _api_call($scfg, 'pool.dataset.get_instance', [ $full ], $api_opts);
}
sub _tn_dataset_resize($scfg, $full, $new_bytes) {
    my $payload = { volsize => int($new_bytes) }; # grow-only
    my $result = _api_call_mutate($scfg, 'pool.dataset.update', [ $full, $payload ]);
    _invalidate_status_capacity_cache(undef, $scfg);
    return $result;
}
sub _tn_dataset_clone($scfg, $source_snapshot, $target_dataset) {
    # Clone a ZFS snapshot to create a new dataset
    # source_snapshot: pool/dataset@snapshot
    # target_dataset: pool/new-dataset
    my $payload = {
        snapshot => $source_snapshot,
        dataset_dst => $target_dataset,
    };
    return _api_call_mutate($scfg, 'pool.snapshot.clone', [ $payload ]);
}

# ---- WebSocket-only snapshot rollback (TrueNAS 25.10+) ----
sub _tn_snapshot_rollback($scfg, $snap_full, $force_bool, $recursive_bool) {
    my $FORCE     = $force_bool     ? JSON::PP::true  : JSON::PP::false;
    my $RECURSIVE = $recursive_bool ? JSON::PP::true  : JSON::PP::false;

    # WebSocket-only for snapshot rollback (requires TrueNAS 25.10+)
    # TrueNAS 25.10+ uses: pool.snapshot.rollback(snapshot_name, {force: bool, recursive: bool})
    my $attempt_rollback = sub {
        my $conn = _ws_get_persistent($scfg);
        return _ws_rpc($conn, {
            jsonrpc => "2.0", id => $conn->{next_id}++,
            method  => "pool.snapshot.rollback",
            params  => [ $snap_full, { force => $FORCE, recursive => $RECURSIVE } ],
        });
    };

    eval { $attempt_rollback->(); };
    if ($@) {
        my $err = $@;
        # ZFS constraint: newer snapshots exist on the target dataset.
        # TN < 25.10 surfaces the libzfs message:
        #   "more recent snapshots or bookmarks exist [...] use '-r' to force deletion"
        # TN 25.10+ wraps it via truenas_pylibzfs and surfaces a different string:
        #   "Cannot rollback: more recent snapshots exist. Use recursive=True to destroy them."
        # plus the underlying FileExistsError. Match either shape.
        if ($err =~ /more recent snapshots/i || $err =~ /Failed to rollback.*File exists/i) {
            # If force=1 but recursive=0, and newer snapshots exist, we need recursive=1
            if ($force_bool && !$recursive_bool) {
                # Retry with recursive=1 to delete newer snapshots
                eval {
                    my $conn = _ws_get_persistent($scfg);
                    _ws_rpc($conn, {
                        jsonrpc => "2.0", id => $conn->{next_id}++,
                        method  => "pool.snapshot.rollback",
                        params  => [ $snap_full, { force => $FORCE, recursive => JSON::PP::true } ],
                    });
                };
                return 1 if !$@;
            }
            # Give a more user-friendly error message
            my ($newer_snaps) = $err =~ /use '-r' to force deletion of the following[^:]*:\s*([^\n]+)/;
            die "Cannot rollback to snapshot: newer snapshots exist ($newer_snaps). ".
                "Delete newer snapshots first or enable recursive rollback.\n";
        }
        die "TrueNAS snapshot rollback failed: $err";
    }
    return 1;
}

# Note: vmstate handling is now done through Proxmox's standard volume allocation
# When vmstate_storage is 'shared', Proxmox automatically creates vmstate volumes on this storage
# When vmstate_storage is 'local', Proxmox stores vmstate on local filesystem (better performance)

# Helper function to clean up stale snapshot entries from VM config
sub _cleanup_vm_snapshot_config {
    my ($vmid, $deleted_snaps) = @_;
    return unless $vmid && $deleted_snaps && @$deleted_snaps;

    my $config_file = "/etc/pve/qemu-server/$vmid.conf";
    return unless -f $config_file;

    # Read the current config
    open my $fh, '<', $config_file or die "Cannot read $config_file: $!";
    my @lines = <$fh>;
    close $fh;

    # Filter out stale snapshot sections
    my @new_lines = ();
    my $in_stale_section = 0;
    my $current_section = '';

    for my $line (@lines) {
        chomp $line;

        # Check if this line starts a snapshot section
        if ($line =~ /^\[([^\]]+)\]$/) {
            $current_section = $1;
            $in_stale_section = grep { $_ eq $current_section } @$deleted_snaps;
        }

        # Skip lines that are part of a stale snapshot section
        unless ($in_stale_section) {
            push @new_lines, $line;
        }

        # Reset section tracking on blank lines
        if ($line eq '') {
            $in_stale_section = 0;
            $current_section = '';
        }
    }

    # Write the cleaned config back
    open $fh, '>', $config_file or die "Cannot write $config_file: $!";
    for my $line (@new_lines) {
        print $fh "$line\n";
    }
    close $fh;

    # Note: pve-cluster restart removed as it's not necessary for snapshot cleanup to work
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    # Feature capability check for Proxmox

    my $features = {
        snapshot => { current => 1 },
        # clone:
        #   - snap => 1: clone from any snapshot (including __base__)
        #   - base => 1: clone from a base image (uses its __base__ snapshot)
        # NOT current => 1: we cannot clone a live volume without going
        # through a snapshot. The previous "current => 1" advertisement
        # was a lie that caused clone_image to die "clone not supported
        # without snapshot" when PVE took us at our word.
        clone => { snap => 1, base => 1 },
        copy  => { snap => 1, current => 1, base => 1 },
        # template => 1 enables `qm template <vmid>` which calls
        # create_base on each disk.
        template => { current => 1 },
        discard => { current => 1 },           # ZFS handles secure deletion when zvol is destroyed
        erase => { current => 1 },             # Alternative feature name for secure deletion
        wipe => { current => 1 },              # Another alternative feature name
    };

    # Parse volume information to determine context
    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) = eval { $class->parse_volname($volname) };

    my $key = undef;
    if ($snapname) {
        $key = 'snap';  # Operation on snapshot
    } elsif ($isBase) {
        $key = 'base';  # Operation on base image
    } else {
        $key = 'current';  # Operation on current volume
    }

    my $result = ($features->{$feature} && $features->{$feature}->{$key}) ? 1 : undef;

    return $result;
}

# Grow-only resize of a raw iSCSI-backed zvol, with TrueNAS 80% preflight and initiator rescan.
sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $new_size_bytes, @rest) = @_;
    # Parse our custom volname: "vol-<zname>-lun<N>"
    my (undef, $zname, undef, undef, undef, undef, $fmt, $lun) =
        $class->parse_volname($volname);
    die "only raw is supported\n" if defined($fmt) && $fmt ne 'raw';
    my $full = $scfg->{tn_dataset} . '/' . $zname;

    _log($scfg, 1, 'info', "[TrueNAS] volume_resize: volname=$volname, target_size=$new_size_bytes");

    # Fetch current zvol info from TrueNAS
    my $ds = eval { _tn_dataset_get($scfg, $full) };
    if (my $err = $@) {
        if ($err =~ /does not exist|ENOENT|InstanceNotFound/i) {
            die "volume '$full' does not exist on TrueNAS\n";
        }
        die $err;
    }
    my $cur_bytes = _normalize_value($ds->{volsize});
    my $bs_bytes  = _normalize_value($ds->{volblocksize}); # may be 0/undef

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
    my $pds = eval { _tn_dataset_get($scfg, $scfg->{tn_dataset}) } // {};
    my $avail_bytes = _normalize_value($pds->{available}); # parent dataset/pool available
    my $max_grow    = $avail_bytes ? int($avail_bytes * 0.80) : 0;
    if ($avail_bytes && $delta > $max_grow) {
        my $fmt_g = sub { sprintf('%.2f GiB', $_[0] / (1024*1024*1024)) };
        die sprintf(
            "resize refused by preflight: requested grow %s exceeds TrueNAS ~80%% headroom (%s) on dataset %s.\n".
            "Reduce the grow amount or free space on the backing dataset/pool.\n",
            $fmt_g->($delta), $fmt_g->($max_grow), $scfg->{tn_dataset}
        );
    }
    # ---- End preflight ----

    # Perform the TrueNAS zvol grow
    my $payload = { volsize => int($req_bytes) };
    my $result = _api_call(
        $scfg,
        'pool.dataset.update',
        [ $full, $payload ],
    );

    # Wait for resize job completion before rescanning (prevent race condition)
    my $job_result = _handle_api_result_with_job_support($scfg, $result, "volume resize for $volname", 60);
    if (!$job_result->{success}) {
        _log($scfg, 0, 'err', "[TrueNAS] volume_resize: failed for $volname: " . $job_result->{error});
        die $job_result->{error};
    }

    _invalidate_status_capacity_cache($storeid, $scfg);

    # Initiator-side rescan so Linux sees the new size (transport-specific)
    my $mode = $scfg->{tn_transport_mode} // 'iscsi';
    if ($mode eq 'iscsi') {
        _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan failed");
        if ($scfg->{tn_use_multipath}) {
            _try_run(['multipath','-r'], "multipath map reload failed");
        }
    } elsif ($mode eq 'nvme-tcp') {
        # NVMe namespace size updates automatically when zvol is resized
        # Trigger device rescan to ensure kernel sees updated size
        # Find NVMe controllers connected to our subsystem and rescan them
        my $nqn = $scfg->{tn_subsystem_nqn};
        my $rescanned = 0;

        eval {
            # Find all NVMe controllers for this subsystem
            my $subsys_link = readlink("/sys/class/nvme-subsystem/nvme-subsys*");
            opendir(my $dh, "/sys/class/nvme-subsystem") or die "Cannot open nvme-subsystem: $!";
            while (my $subsys = readdir($dh)) {
                next unless $subsys =~ /^(nvme-subsys\d+)$/;
                $subsys = $1;  # Untaint via capture
                my $subsys_nqn = eval {
                    open my $fh, '<', "/sys/class/nvme-subsystem/$subsys/subsysnqn" or die;
                    my $val = <$fh>;
                    close $fh;
                    chomp($val);
                    $val;
                };
                next unless $subsys_nqn && $subsys_nqn eq $nqn;

                # Found our subsystem, rescan all its controllers
                opendir(my $sdh, "/sys/class/nvme-subsystem/$subsys") or next;
                while (my $entry = readdir($sdh)) {
                    next unless $entry =~ /^(nvme(\d+))$/;
                    $entry = $1;  # Untaint via capture
                    my $ctrl_dev = "/dev/nvme$2";
                    if (-e $ctrl_dev) {
                        eval { _try_run(['nvme', 'ns-rescan', $ctrl_dev], "nvme rescan $ctrl_dev"); };
                        $rescanned++ unless $@;
                    }
                }
                closedir($sdh);
            }
            closedir($dh);
        };

        # Fallback: if we couldn't find/rescan our subsystem, try rescanning all controllers
        if (!$rescanned) {
            eval {
                opendir(my $dh, "/dev") or die "Cannot open /dev: $!";
                while (my $dev = readdir($dh)) {
                    next unless $dev =~ /^(nvme\d+)$/;
                    $dev = $1;  # Untaint via capture
                    eval { _try_run(['nvme', 'ns-rescan', "/dev/$dev"], "nvme rescan /dev/$dev"); };
                }
                closedir($dh);
            };
        }
    }
    run_command(['udevadm','settle'], outfunc => sub {});
    select(undef, undef, undef, 0.25); # ~250ms

    # Proxmox expects KiB as return value
    my $ret_kib = int(($req_bytes + 1023) / 1024);
    _log($scfg, 1, 'info', "[TrueNAS] volume_resize: resized $volname to $ret_kib KiB");
    return $ret_kib;
}

# Create a ZFS snapshot on the TrueNAS zvol backing this volume.
# 'snapname' must be a simple token (PVE passes it).
# Note: vmstate is handled automatically by Proxmox through standard volume allocation
sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname, $vmstate) = @_;

    # PVE's Storage.pm dispatches volume_snapshot, volume_snapshot_delete,
    # and volume_snapshot_rollback WITHOUT wrapping in cluster_lock_storage
    # (Storage.pm:428, 443, 459 -- unlike vdisk_alloc/free/clone/create_base
    # which are wrapped at Storage.pm:1090, 1113, 1170, 1198). Two cluster
    # nodes calling `qm snapshot` on the same volume otherwise race on the
    # TN-side pool.snapshot.create -- name-uniqueness rejects one and can
    # leave inconsistent state. Take a cfs cluster-wide lock here to close
    # the gap Max R. Carrara (Proxmox) flagged in the 2026-08-06 cluster-
    # test writeup ("if you fork() or similar somewhere, you might be
    # circumventing some locks").
    return $class->cluster_lock_storage($storeid, 1, undef, sub {
        my (undef, $zname) = $class->parse_volname($volname);
        my $full = $scfg->{tn_dataset} . '/' . $zname; # pool/dataset/.../vm-<id>-disk-<n>
        my $snap_full = $full . '@' . $snapname;    # full snapshot name for logging

        _log($scfg, 1, 'info', "[TrueNAS] volume_snapshot: creating $snap_full");

        # Create ZFS snapshot for the disk
        my $payload = { dataset => $full, name => $snapname, recursive => JSON::PP::false };
        my $result = _api_call_mutate(
            $scfg, 'pool.snapshot.create', [ $payload ],
        );

        # Handle potential async job for snapshot creation
        my $job_result = _handle_api_result_with_job_support($scfg, $result, "snapshot creation for $snap_full");
        if (!$job_result->{success}) {
            _log($scfg, 0, 'err', "[TrueNAS] volume_snapshot: failed to create $snap_full: " . $job_result->{error});
            die $job_result->{error};
        }

        _log($scfg, 1, 'info', "[TrueNAS] volume_snapshot: created $snap_full");

        # Note: vmstate ($vmstate parameter) is handled automatically by Proxmox:
        # - If vmstate_storage is 'shared': Proxmox creates vmstate volumes on this storage
        # - If vmstate_storage is 'local': Proxmox stores vmstate on local filesystem
        # Our plugin only needs to handle the disk snapshot creation

        return undef;
    });
}

# Delete a ZFS snapshot on the zvol.
# Note: vmstate cleanup is handled automatically by Proxmox
sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    # PVE core does not wrap volume_snapshot_delete in cluster_lock_storage;
    # take the lock here. See the comment on volume_snapshot above.
    return $class->cluster_lock_storage($storeid, 1, undef, sub {
        my (undef, $zname) = $class->parse_volname($volname);
        my $full = $scfg->{tn_dataset} . '/' . $zname; # pool/dataset/.../vm-<id>-disk-<n>
        my $snap_full = $full . '@' . $snapname;    # full snapshot name
        my $id = URI::Escape::uri_escape($snap_full); # '@' must be URL-encoded in path

        _log($scfg, 1, 'info', "[TrueNAS] volume_snapshot_delete: deleting $snap_full");

        # Tear down any ephemeral vzdump snapshot clone before deleting the ZFS
        # snapshot (issue #42). PVE's LXC vzdump path unmounts then calls
        # volume_snapshot_delete directly — it never calls deactivate_volume with a
        # snapname — so the clone would otherwise be orphaned. A clone also holds the
        # snapshot as its origin, blocking the snapshot delete below until removed.
        # Best-effort: _teardown_snapshot_device is idempotent and no-ops when no
        # clone exists.
        if (defined($snapname) && $snapname ne '') {
            eval { $class->_teardown_snapshot_device($scfg, $volname, $snapname) };
            warn "[TrueNAS] volume_snapshot_delete: snapshot clone teardown failed: $@\n" if $@;
        }

        my $result = _api_call_mutate(
            $scfg, 'pool.snapshot.delete', [ $snap_full ],
        );

        # Handle potential async job for snapshot deletion
        my $job_result = _handle_api_result_with_job_support($scfg, $result, "individual snapshot deletion for $snap_full", SNAPSHOT_DELETE_TIMEOUT_S);
        if (!$job_result->{success}) {
            die $job_result->{error};
        }

        _log($scfg, 1, 'info', "[TrueNAS] volume_snapshot_delete: deleted $snap_full");
        return undef;
    });
}

# Roll back the zvol to a specific ZFS snapshot and rescan iSCSI/multipath.
# Now supports restoring VM state for live snapshots.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;

    # ZFS zvol snapshots form a strictly linear chain: a `zfs rollback` to an
    # older snapshot can only proceed by destroying every snapshot taken after
    # it. Mirror the built-in ZFSPoolPlugin and refuse a rollback unless $snap
    # is the most recent snapshot, so PVE blocks it cleanly instead of letting
    # volume_snapshot_rollback() silently delete newer snapshots.
    my $snapshots = $class->volume_snapshot_info($scfg, $storeid, $volname);

    $blockers //= []; # not guaranteed to be set by caller
    my $found;
    for my $snapid (
        sort { $snapshots->{$a}{timestamp} <=> $snapshots->{$b}{timestamp} or $a cmp $b }
        keys %$snapshots
    ) {
        if ($snapid eq $snap) {
            $found = 1;
        } elsif ($found) {
            push @$blockers, $snapid;
        }
    }

    my $volid = "${storeid}:${volname}";

    die "can't rollback, snapshot '$snap' does not exist on '$volid'\n"
        if !$found;

    die "can't rollback, '$snap' is not most recent snapshot on '$volid'\n"
        if scalar(@$blockers) > 0;

    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    # PVE core does not wrap volume_snapshot_rollback in cluster_lock_storage;
    # take the lock here. See the comment on volume_snapshot above. Rollback
    # is especially sensitive to concurrent execution because it destroys
    # newer snapshots as a side effect (recursive=1 below).
    return $class->cluster_lock_storage($storeid, 1, undef, sub {
        my (undef, $zname, $vmid) = $class->parse_volname($volname);
        my $full = $scfg->{tn_dataset} . '/' . $zname;
        my $snap_full = $full . '@' . $snapname;

        _log($scfg, 1, 'info', "[TrueNAS] volume_snapshot_rollback: rolling back to $snap_full");

    # Get list of snapshots that exist BEFORE rollback
    my $pre_rollback_snaps = {};
    if ($vmid) {
        eval {
            my $snap_list = $class->volume_snapshot_info($scfg, $storeid, $volname);
            $pre_rollback_snaps = { %$snap_list };
        };
    }

    # PVE's snapshot-rollback contract: revert to the target snapshot's state.
    # Anything taken AFTER the target is conceptually undone, so any newer
    # snapshots on the same dataset must be destroyed. Pass recursive=1 so TN's
    # rollback removes intermediate snapshots; otherwise TN 25.10 errors with
    # "Cannot rollback: more recent snapshots exist. Use recursive=True to
    # destroy them." and the rollback fails. Verified against TN 25.10
    # snapshot_rollback_impl.py: recursive=True triggers
    # _destroy_newer_snapshots() on the target dataset and does NOT touch
    # clones (controlled by recursive_clones) or child datasets (controlled
    # by recursive_rollback).
    _tn_snapshot_rollback($scfg, $snap_full, 1, 1);

    # Note: vmstate restoration is handled automatically by Proxmox

    # Clean up stale Proxmox VM config entries for deleted snapshots
    if ($vmid && %$pre_rollback_snaps) {
        eval {
            # Get current snapshots from TrueNAS after rollback
            my $post_rollback_snaps = $class->volume_snapshot_info($scfg, $storeid, $volname);

            # Find snapshots that were deleted by the rollback
            my @deleted_snaps = grep { !exists $post_rollback_snaps->{$_} } keys %$pre_rollback_snaps;

            if (@deleted_snaps) {
                # Clean up VM config file by removing stale snapshot entries
                _cleanup_vm_snapshot_config($vmid, \@deleted_snaps);
            }
        };
        warn "Failed to clean up stale snapshot entries: $@" if $@;
    }

    # Refresh initiator view — rescan only this storage's target to avoid disrupting
    # other active iSCSI sessions on unrelated volumes during the rollback
    my $rollback_iqn = $scfg->{tn_target_iqn};
    eval {
        if ($rollback_iqn) {
            PVE::Tools::run_command(['iscsiadm','-m','node','-T',$rollback_iqn,'-R'], outfunc=>sub{});
        } else {
            PVE::Tools::run_command(['iscsiadm','-m','session','-R'], outfunc=>sub{});
        }
    };
    if ($scfg->{tn_use_multipath}) {
        eval { PVE::Tools::run_command(['multipath','-r'], outfunc=>sub{}) };
    }
    eval { PVE::Tools::run_command(['udevadm','settle'], outfunc=>sub{}) };

    _log($scfg, 1, 'info', "[TrueNAS] volume_snapshot_rollback: rolled back to $snap_full");
        return undef;
    });
}

# Return a hash describing available snapshots for this volume.
# Shape: { <snapname> => { id => <snapname>, timestamp => <epoch> }, ... }
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;
    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{tn_dataset} . '/' . $zname;

    _log($scfg, 2, 'debug', "[TrueNAS] volume_snapshot_info: querying snapshots for $full");

    my $list = _api_call($scfg, 'pool.snapshot.query', []) // [];

    my $snaps = {};
    for my $s (@$list) {
        my $name = $s->{name} // next; # "pool/ds@sn"
        next unless $name =~ /^\Q$full\E\@(.+)$/;
        my $snapname = $1;
        my $ts = 0;
        if (my $props = $s->{properties}) {
            if (ref($props->{creation}) eq 'HASH') {
                $ts = int($props->{creation}{rawvalue} // 0);
            } elsif (defined $props->{creation} && !ref($props->{creation}) && $props->{creation} =~ /(\d{10})/) {
                $ts = int($1);
            }
        }
        $snaps->{$snapname} = { id => $snapname, timestamp => $ts };
    }

    return $snaps;
}

# ======== Importing snapshots taken outside PVE ========
#
# Snapshots created on the array - a TrueNAS periodic task, a replication
# job, someone on the TrueNAS UI - are real ZFS snapshots of our zvols, but
# PVE cannot see them: the Snapshots tab renders $conf->{snapshots} from
# /etc/pve/qemu-server/<vmid>.conf (or /etc/pve/lxc/<vmid>.conf for a
# container) and never asks the storage. They are not
# inert, either. One of them being newer than a PVE snapshot makes
# `qm rollback <that snapshot>` fail with "is not most recent snapshot", with
# nothing in the GUI to explain or remove the blocker; and a rollback that
# does go through destroys them, because the rollback is recursive.
#
# `truenas-proxmox-manage import-snapshots <vmid>` - VM or container - writes
# the missing sections so PVE owns what is already on the array: the GUI lists them, `qm
# delsnapshot` removes them, and rollback stops being blocked by something
# invisible.
#
# The rules are deliberately fail-closed, because a bad section is worse than
# no section: one that does not cover every disk pushes the uncovered ones to
# unusedN on rollback, and a name PVE cannot parse breaks every later write of
# that config file. What the importer cannot vouch for, it lists and refuses.

# Names PVE reserves for itself. 'vzdump' is the temporary snapshot of a
# backup (AbstractConfig), 'current' and 'pending' are API/config keywords,
# '__base__' is the template snapshot of a linked clone, and '__replicate_*'
# belongs to pvesr.
#
# Matched case-INSENSITIVELY. PVE's own parser is: write_vm_config dies on
# `lc($snapname) eq 'pending'`, and the config parser recognises the pending
# section with a case-insensitive match - so a ZFS snapshot called `Pending`
# passes pve-configid and then poisons the config file. The other four are
# refused the same way rather than reasoning about which of them PVE happens
# to fold today.
my %TN_RESERVED_SNAPNAMES = map { $_ => 1 } qw(vzdump current pending __base__);

# How far apart the per-disk creation times of one snapshot name may be and
# still be believable as a single capture of one VM. A periodic task
# snapshots every dataset in the same transaction; an hour of drift means two
# unrelated snapshots that happen to share a name, and rolling back to that
# would pair one disk's Monday with the other disk's Tuesday.
my $TN_IMPORT_MAX_SKEW_S = 3600;

# Where the guest configurations live. Package variables so the guest type
# can be decided - and exercised offline - without a container or a VM on the
# node.
our $TN_LXC_CONF_DIR  = '/etc/pve/lxc';
our $TN_QEMU_CONF_DIR = '/etc/pve/qemu-server';

# Which config class owns $vmid, as { kind, class, label }.
#
# The type is decided by which configuration file exists, the same way
# pct/qm/PVE::GuestHelpers do, because nothing in the volume names tells a
# container's zvol apart from a VM's. Only the container case needs a
# positive answer: with no /etc/pve/lxc/<vmid>.conf this is a VM, and if it
# is not a VM either, PVE::QemuConfig->load_config() is the one that says so
# ("Configuration file for '<vmid>' does not exist") - a second, differently
# worded refusal here would only be a copy of it that can drift.
sub _tn_guest_config($vmid) {
    return { kind => 'lxc', class => 'PVE::LXC::Config', label => 'CT' }
        if -e "$TN_LXC_CONF_DIR/$vmid.conf";
    return { kind => 'qemu', class => 'PVE::QemuConfig', label => 'VM' }
        if -e "$TN_QEMU_CONF_DIR/$vmid.conf";

    # Neither file is here. In a cluster that usually means the guest is on
    # another node, and the config file on THIS node is the only thing the
    # importer can lock - so say where it lives instead of letting
    # QemuConfig answer "Configuration file does not exist", which reads
    # like the guest is gone. Best effort: the cluster file system may not
    # be available (a single node, a test), and then the old error is still
    # the right one.
    my $entry = eval {
        require PVE::Cluster;
        # cfs_update() is required in a fresh Perl process. The CLI is
        # always invoked as one (install.sh execs a new perl per call),
        # so without this, get_vmlist() returns an empty hash and the
        # "guest is on node X" hint never fires -- the caller falls
        # through to load_config()'s generic "Configuration file
        # 'nodes/pve/qemu-server/<vmid>.conf' does not exist" instead.
        PVE::Cluster::cfs_update();
        PVE::Cluster::get_vmlist()->{ids}{$vmid};
    };
    if (ref($entry) eq 'HASH' && $entry->{node}) {
        my $type = ($entry->{type} // '') eq 'lxc' ? 'container' : 'VM';
        die "$vmid is a $type on node '$entry->{node}', not on this one; "
          . "run import-snapshots there\n";
    }

    return { kind => 'qemu', class => 'PVE::QemuConfig', label => 'VM' };
}

# undef when $name may be used as a PVE snapshot name, else the reason why
# not. pve-configid is /^[a-z][a-z0-9_-]+$/i with a 40 character maximum
# (PVE::JSONSchema) - hyphens included, verified against pve_verify_configid
# on PVE 9.2.4: `Daily-1` and `auto-2026-09-18_00-00` are accepted, a single
# character is not. This plugin can never rename around a bad name, because
# here the PVE snapshot name IS the ZFS snapshot name.
sub _tn_snapshot_name_problem($name) {
    return 'reserved by PVE'               if $TN_RESERVED_SNAPNAMES{ lc $name };
    return 'reserved by PVE (replication)' if $name =~ /\A__replicate_/i;
    return 'longer than the 40 characters PVE allows' if length($name) > 40;
    # \A and \z, never ^ and $: with $, "Daily-1\n" passes this check and is
    # then written into the config file as a section header plus a stray
    # line. A ZFS snapshot name cannot normally contain a newline, but this
    # validator is the last thing between a name the array reported and a
    # guest configuration, and it may not depend on that.
    return 'not a valid PVE snapshot name (pve-configid)'
        if $name !~ /\A[a-z][a-z0-9_-]+\z/i;
    return undef;
}

# Snapshots of the given datasets, as
# { <dataset> => { <snapname> => { ts => <epoch|undef>, txg => <int|undef> } } }
#
# Unlike volume_snapshot_info() this filters server-side, so importing does not
# pull every snapshot on the array across the wire. An answer that is not the
# array of records the API promises is an ERROR: reporting "no snapshots" for
# a query that never ran would tell an operator their array is clean when it
# is not, and is the same shape of bug as list_images answering "empty" when
# it could not ask. The same applies to a record whose identity is not a
# string - a dataset that arrives as [] is not a dataset with no name.
#
# `ts` is left undef unless the array gave a plain positive integer, and
# `txg` (createtxg, the ZFS transaction group) is the only honest tiebreaker
# between two snapshots taken in the same second. Neither is invented here;
# the planner decides what to do with a missing one.
sub _tn_snapshot_query_datasets($scfg, $fulls) {
    my $res = {};
    return $res if !$fulls || !@$fulls;

    my %wanted = map { $_ => 1 } @$fulls;
    $res->{$_} = {} for @$fulls;

    my $list = _api_call($scfg, 'pool.snapshot.query',
        [ [ [ 'dataset', 'in', [ @$fulls ] ] ],
          { extra => { properties => ['creation'] } } ]);

    die "[TrueNAS] pool.snapshot.query did not return a list of snapshots; "
      . "refusing to treat that as 'no snapshots'\n"
        if !defined($list) || ref($list) ne 'ARRAY';

    for my $s (@$list) {
        die "[TrueNAS] pool.snapshot.query returned a record that is not an "
          . "object; refusing to guess what it meant\n"
            if ref($s) ne 'HASH';

        # A key that is present but is not a usable string is a malformed
        # answer, not a missing one: do not paper over it with the id.
        for my $key (qw(dataset snapshot_name)) {
            next if !exists $s->{$key};
            my $val = $s->{$key};
            die "[TrueNAS] pool.snapshot.query returned a record whose "
              . "'$key' is not a name; refusing to guess what it meant\n"
                if !defined($val) || ref($val) || $val eq '';
        }

        my ($ds, $name) = ($s->{dataset}, $s->{snapshot_name});
        if (!defined($ds) || !defined($name)) {
            my $id = $s->{name} // $s->{id};
            die "[TrueNAS] pool.snapshot.query returned a record without a "
              . "snapshot name; refusing to guess what it meant\n"
                if !defined($id) || ref($id) || $id !~ /^(.+)\@(.+)$/;
            ($ds, $name) = ($1, $2);
        }

        # A filter the middleware did not honour must not smuggle a
        # neighbour's snapshot into this guest's plan.
        next if !$wanted{$ds};

        my ($ts, $txg);
        my $props = $s->{properties};
        if (ref($props) eq 'HASH') {
            my $creation = $props->{creation};
            my $raw = ref($creation) eq 'HASH' ? $creation->{rawvalue}
                    : !ref($creation)          ? $creation
                    :                            undef;
            $ts = $raw + 0 if defined($raw) && !ref($raw) && $raw =~ /^\d+$/ && $raw > 0;
        }
        my $createtxg = $s->{createtxg};
        $txg = $createtxg + 0
            if defined($createtxg) && !ref($createtxg) && $createtxg =~ /^\d+$/;

        $res->{$ds}{$name} = { ts => $ts, txg => $txg };
    }

    return $res;
}

# Decide what may be imported. Pure: no I/O, no PVE, no TrueNAS - which is why
# every rule below is testable offline in t/nvme/19-snapshot-import-plan.t.
#
#   $existing - $conf->{snapshots}
#   $by_volid - { <volid> => { <snapname> => { ts, txg } } } from the array
#   $opts     - { match => <regex string>, only => [ names ],
#                 clone_blocked => { name => 1 } }
#
# Returns { import => [ { name, snaptime, parent } ] oldest first,
#           partial => { name => [ volids missing ] },
#           invalid => { name => reason },
#           present => [ names already in the config ],
#           new_parent => <name> | undef }
sub _plan_snapshot_import($existing, $by_volid, $opts = {}) {
    $existing //= {};
    $opts     //= {};

    my @volids = sort keys %$by_volid;
    die "[TrueNAS] nothing to plan: no volumes\n" if !@volids;

    my $match;
    if (defined($opts->{match}) && $opts->{match} ne '') {
        $match = eval { qr/$opts->{match}/ };
        die "[TrueNAS] --match is not a valid regular expression: $@" if !$match;
    }
    # The allow-list. Either plain names, or - what the CLI passes - records
    # of { name, identity }, where identity pins the snapshot the operator
    # actually saw: its creation time and createtxg on every disk. A name is
    # not an identity. A periodic task can destroy `Daily-1` and create a new
    # `Daily-1` between the listing and the confirmation, and importing THAT
    # one writes a section describing a capture nobody approved.
    my $only;
    if ($opts->{only}) {
        $only = {};
        for my $entry (@{ $opts->{only} }) {
            if (ref($entry) eq 'HASH') {
                $only->{ $entry->{name} } = $entry->{identity};
            } else {
                $only->{$entry} = undef;
            }
        }
    }
    my $blocked = $opts->{clone_blocked} // {};

    my %seen;   # snapname => { volid => { ts, txg } }
    for my $volid (@volids) {
        my $snaps = $by_volid->{$volid} // {};
        $seen{$_}{$volid} = $snaps->{$_} for keys %$snaps;
    }

    my (@present, %partial, %invalid, @candidates);
    for my $name (sort keys %seen) {
        next if defined($match) && $name !~ $match;
        next if $only && !exists $only->{$name};

        # Already ours: never re-examined and never rewritten (R4).
        if (exists $existing->{$name}) {
            push @present, $name;
            next;
        }
        if (my $why = _tn_snapshot_name_problem($name)) {
            $invalid{$name} = $why;
            next;
        }
        # Every non-cdrom volume of the guest must carry this snapshot, or the
        # section would be a partial picture of the VM (R2).
        my @missing = grep { !exists $seen{$name}{$_} } @volids;
        if (@missing) {
            $partial{$name} = [ @missing ];
            next;
        }
        if ($blocked->{$name}) {
            $invalid{$name} = 'has a dependent clone on TrueNAS (could not be deleted from PVE)';
            next;
        }

        # Every disk must carry a usable creation time. One disk having one is
        # not enough: with snaptime taken from whichever disk answered, a
        # snapshot half of which the array cannot date would be imported as
        # if it were a clean capture (R5).
        my (@times, @txgs, $undated, $txg_missing, @identity);
        for my $volid (@volids) {
            my $entry = $seen{$name}{$volid};
            my $ts = ref($entry) eq 'HASH' ? $entry->{ts} : undef;
            if (!defined($ts)) { $undated = 1; last }
            push @times, $ts;
            my $txg = ref($entry) eq 'HASH' ? $entry->{txg} : undef;
            if (defined $txg) { push @txgs, $txg } else { $txg_missing = 1 }
            push @identity, "$volid=$ts/" . ($txg // '-');
        }
        if ($undated) {
            $invalid{$name} = 'no usable creation timestamp from TrueNAS';
            next;
        }

        # What the operator confirmed was this snapshot, not this name.
        my $identity = join(';', @identity);
        if ($only && defined($only->{$name}) && $only->{$name} ne $identity) {
            $invalid{$name} = 'changed on TrueNAS since it was listed; '
                . 'not the snapshot that was confirmed';
            next;
        }

        # Same name on every disk is not the same capture. A periodic task
        # snapshots them in one transaction; hours apart means two unrelated
        # snapshots that happen to share a name.
        my ($min, $max) = (sort { $a <=> $b } @times)[0, -1];
        if ($max - $min > $TN_IMPORT_MAX_SKEW_S) {
            $invalid{$name} = "creation differs by " . ($max - $min)
                . "s between disks; not one capture";
            next;
        }

        # createtxg is a tiebreaker only when EVERY disk reported one. With
        # it taken from whichever disk happened to answer, a half-dated
        # candidate would be ordered against another snapshot as if the
        # array had dated all of it - and an order that is a guess is the
        # one thing this planner refuses to write.
        push @candidates, {
            name     => $name,
            snaptime => $max,
            txg      => ($txg_missing || !@txgs ? undef : (sort { $b <=> $a } @txgs)[0]),
            identity => $identity,
        };
    }

    # Order comes from the array, never from the name. Two snapshots created
    # in the same second are ordered by createtxg, the ZFS transaction group;
    # when that cannot settle it - the other one is a PVE snapshot, which has
    # no txg, or the txgs are equal - the order is unknown, and a section
    # whose place in the chain is a guess is not written.
    my @others = map {
        { name => $_, snaptime => int($existing->{$_}{snaptime} // 0), txg => undef }
    } keys %$existing;

    my @ordered;
    for my $cand (@candidates) {
        my $tied;
        for my $other (@others, @candidates) {
            next if $other->{name} eq $cand->{name};
            next if $other->{snaptime} != $cand->{snaptime};
            next if defined($other->{txg}) && defined($cand->{txg})
                 && $other->{txg} != $cand->{txg};
            $tied = $other->{name};
            last;
        }
        if (defined $tied) {
            $invalid{ $cand->{name} } =
                "same creation time as '$tied' and no createtxg to order them";
            next;
        }
        push @ordered, $cand;
    }

    # Chain by time: each imported snapshot hangs off the newest snapshot
    # older than itself, the ones PVE already has included, and the guest's
    # parent follows only if an imported snapshot is the newest of all (R7).
    my @timeline = ( ( map { { %$_, imported => 0 } } @others ),
                     ( map { { %$_, imported => 1 } } @ordered ) );
    # Deterministic to the last comparison. Two snapshots PVE already has can
    # share a snaptime and have no createtxg at all (PVE never records one),
    # and with the sort ending there their order came from hash order - so
    # the same config planned twice could chain the imports differently. The
    # final `cmp` on the name is arbitrary, but it is arbitrary the SAME way
    # every run, which is what a parent chain needs. It only ever decides
    # between snapshots that are already indistinguishable in time; a
    # candidate tied with anything is refused above, never ordered by name.
    @timeline = sort {
        $a->{snaptime} <=> $b->{snaptime}
            || ($a->{txg} // 0) <=> ($b->{txg} // 0)
            || ($a->{name} cmp $b->{name})
    } @timeline;

    my (@import, $prev);
    for my $entry (@timeline) {
        push @import, {
            name     => $entry->{name},
            snaptime => $entry->{snaptime},
            identity => $entry->{identity},
            parent   => $prev,
        } if $entry->{imported};
        $prev = $entry->{name};
    }

    my $new_parent;
    $new_parent = $timeline[-1]{name} if @timeline && $timeline[-1]{imported};

    return {
        import     => \@import,
        partial    => \%partial,
        invalid    => \%invalid,
        present    => [ sort @present ],
        new_parent => $new_parent,
    };
}

# Which of these ZFS snapshots something else is cloned from. A snapshot with
# a dependent clone cannot be destroyed, so importing it would hand PVE a
# snapshot whose `qm delsnapshot` is guaranteed to fail.
#
# pool.snapshot.query does not surface the `clones` property in the releases
# this plugin targets (see free_image), so the question is asked from the
# dataset side with the same origin.parsed filter used there - one query per
# candidate snapshot, on the handful that survived planning. An `in` filter
# over origin.parsed is *accepted* by the middleware (checked read-only
# against a live array), but with no clone on that array there was nothing to
# prove it actually matches, and an `in` that silently matched nothing would
# read as "no clones". The proven `=` form stays until that can be shown.
#
# A lookup that fails is an error: "no clones" may only be said when it is
# known.
sub _tn_snapshot_clone_blockers($scfg, $ids) {
    my %blocked;
    for my $id (@$ids) {
        my $rows = eval {
            _api_call($scfg, 'pool.dataset.query',
                [ [ [ 'origin.parsed', '=', $id ] ], { select => [ 'id' ] } ]);
        };
        my $err = $@;
        die "[TrueNAS] could not establish whether $id has dependent clones: "
          . ($err || "pool.dataset.query answered with something that is not a list") . "\n"
            if $err || ref($rows) ne 'ARRAY';
        $blocked{$id} = 1 if @$rows;
    }
    return \%blocked;
}

# The guest-level refusals (R3). Called before the query and again inside the
# lock, because all three can appear between the two.
sub _tn_import_check_conf($conf, $vmid, $label = 'VM') {
    die "$label $vmid is a template; its snapshots are not imported\n"
        if $conf->{template};
    die "$label $vmid is locked ($conf->{lock}); refusing to touch its configuration\n"
        if $conf->{lock};
    for my $name (sort keys %{ $conf->{snapshots} // {} }) {
        die "$label $vmid has a snapshot operation in flight ('$name' is in state "
          . "$conf->{snapshots}{$name}{snapstate}); refusing to write its configuration\n"
            if $conf->{snapshots}{$name}{snapstate};
    }
}

# PVE's own answer to "can this guest be snapshotted?", asked before writing
# a section that claims it can.
#
# has_feature() walks every volume of the guest and asks the storage behind
# it; it is 0 when ANY of them cannot snapshot - a CT bind mount, a VM disk
# on a storage without the feature, a raw device. The volume walk above
# already refuses what this plugin can see, but it only knows about volumes
# on THIS plugin, and PVE is the one that will have to run the rollback.
# Asking it directly is the difference between a section PVE can use and a
# section that dies half way through `qm rollback`.
sub _tn_import_check_feature($guest, $conf, $vmid, $storecfg) {
    my $ok = $guest->{class}->has_feature('snapshot', $conf, $storecfg);
    die "$guest->{label} $vmid: PVE reports that this guest cannot be "
      . "snapshotted (has_feature('snapshot') is false), so a section "
      . "written here could never be rolled back or deleted; nothing "
      . "imported\n"
        if !$ok;
}

# The non-cdrom volumes of the guest, as
# [ { key, volid, storeid, scfg, full } ], with every one of them living on
# this plugin. A volume elsewhere is fatal: a section naming it would die half
# way through a rollback, after the other disks were already rolled back.
sub _tn_import_volumes($class, $storecfg, $conf, $vmid, $guest) {
    my @vols;
    my @foreign;
    my @nonvolume;
    my $label = $guest->{label};

    $guest->{class}->foreach_volume($conf, sub {
        my ($key, $vol) = @_;

        my $volid;
        if ($guest->{kind} eq 'lxc') {
            # rootfs and mpN, as classify_mountpoint() typed them. A bind
            # mount (mp1=/mnt/host/data) or a device (/dev/...) is not a
            # storage volume, and for a container that is FATAL, not
            # something to skip: PVE::LXC::Config->has_feature('snapshot')
            # walks every mountpoint and asks PVE::Storage::volume_has_feature
            # about it, which returns undef for a plain path - so PVE itself
            # refuses `pct snapshot` on such a container. Importing a section
            # for it would hand PVE snapshots it cannot use: `pct rollback`
            # dies in PVE::Storage::volume_rollback_is_possible ("rollback
            # file/device is not possible") AFTER the other volumes were
            # already rolled back, and `pct delsnapshot` destroys the rootfs
            # snapshot on the array and then dies on the bind mount, leaving
            # the container in `lock: snapshot-delete`. Both verified against
            # PVE 9.2.4.
            if (($vol->{type} // '') ne 'volume') {
                push @nonvolume, "$key: " . ($vol->{volume} // '?');
                return;
            }
            $volid = $vol->{volume};
        } else {
            return if $vol->{media} && $vol->{media} eq 'cdrom';
            $volid = $vol->{file};
        }
        return if !defined($volid) || $volid eq '' || $volid eq 'none'
               || $volid eq 'cdrom';

        if ($volid =~ m{^/}) {
            push @foreign, "$key ($volid): a host device, not a storage volume";
            return;
        }
        my ($storeid, $volname) = split(/:/, $volid, 2);
        my $scfg = $storecfg->{ids}{$storeid};
        if (!$scfg || ($scfg->{type} // '') ne 'truenasplugin') {
            push @foreign, "$key ($volid): storage '$storeid' is "
                . ($scfg ? "of type $scfg->{type}" : 'not configured here');
            return;
        }

        my (undef, $zname) = $class->parse_volname($volname);
        push @vols, {
            key     => $key,
            volid   => $volid,
            storeid => $storeid,
            scfg    => $scfg,
            full    => $scfg->{tn_dataset} . '/' . $zname,
        };
    });

    die "$label $vmid has bind/device mountpoints (" . join('; ', @nonvolume)
      . "); PVE does not allow snapshots of this container, nothing imported\n"
        if @nonvolume;

    die "$label $vmid has disks outside this plugin, so a snapshot of it could "
      . "never be rolled back as a whole:\n  " . join("\n  ", @foreign) . "\n"
        if @foreign;
    die "$label $vmid has no disks on this plugin\n" if !@vols;

    return \@vols;
}

# Ask each storage about its own datasets and return
# { <volid> => { <snapname> => { ts, txg } } }.
#
# Keyed by storage AND dataset, never by dataset alone: two storages may
# point at the same tn_dataset on two different arrays, and merging their
# answers made a snapshot that exists on one of them look present on both -
# which is exactly the "complete on every disk" claim this import rests on.
sub _tn_import_snapshots_by_volid($class, $vols) {
    my (%fulls_by_store, %scfg_by_store);
    for my $vol (@$vols) {
        push @{ $fulls_by_store{ $vol->{storeid} } }, $vol->{full};
        $scfg_by_store{ $vol->{storeid} } //= $vol->{scfg};
    }

    my %by_key;
    for my $storeid (sort keys %fulls_by_store) {
        my $found = _tn_snapshot_query_datasets($scfg_by_store{$storeid},
            $fulls_by_store{$storeid});
        $by_key{"$storeid|$_"} = $found->{$_} for keys %$found;
    }

    return { map { $_->{volid} => ($by_key{"$_->{storeid}|$_->{full}"} // {}) } @$vols };
}

# Query the array and plan, including the clone lookup for the candidates the
# plan produced. Run once to show the operator, and again inside the lock -
# never reusing the first answer, because a snapshot can be destroyed or
# cloned between the two.
sub _tn_import_plan($class, $vols, $conf, $opts) {
    my $by_volid = $class->_tn_import_snapshots_by_volid($vols);

    my %plan_opts = ( match => $opts->{match}, only => $opts->{only} );
    my $plan = _plan_snapshot_import($conf->{snapshots}, $by_volid, \%plan_opts);

    return $plan if !@{ $plan->{import} };

    my %blocked;
    for my $vol (@$vols) {
        my @ids = map { "$vol->{full}\@$_->{name}" } @{ $plan->{import} };
        my $hits = _tn_snapshot_clone_blockers($vol->{scfg}, \@ids);
        for my $id (keys %$hits) {
            my ($name) = $id =~ /\@(.+)$/;
            $blocked{$name} = 1;
        }
    }
    return $plan if !%blocked;

    $plan_opts{clone_blocked} = \%blocked;
    return _plan_snapshot_import($conf->{snapshots}, $by_volid, \%plan_opts);
}

# Import every snapshot of $vmid that exists on TrueNAS and is safe to adopt.
#
# $opts: { dry_run => 1, match => <regex string>,
#          only => [ names | { name, identity } ] }
# 'only' is an allow-list: nothing outside it is imported, which is how the
# CLI guarantees that what it writes is what the operator confirmed. Given
# identities (the form the CLI uses) it also refuses a snapshot that was
# destroyed and recreated under the same name in the meantime.
#
# Works for VMs and containers alike; the guest type is decided from the
# configuration file that exists.
#
# Returns the plan, plus 'imported' (sections written), 'dropped' (candidates
# that were listed but no longer qualified when the lock was held) and
# 'dry_run'.
sub import_foreign_snapshots($class, $vmid, $opts = {}) {
    $opts //= {};

    # VM or container. Both go through the same AbstractConfig machinery -
    # lock_config/load_config/write_config/__snapshot_copy_config are all
    # inherited, and LXC::Config does not override any of them - so the only
    # differences are the class, the volume keys (rootfs/mpN instead of
    # scsiN/virtioN) and how a volume is spelled inside a mountpoint.
    my $guest = _tn_guest_config($vmid);

    # Required at run time, not compile time: this file is a storage plugin
    # and is loaded on nodes and in tests where qemu-server/pve-container is
    # not present.
    require PVE::Storage;
    if ($guest->{kind} eq 'lxc') {
        require PVE::LXC::Config;
    } else {
        require PVE::QemuConfig;
    }

    my $storecfg = PVE::Storage::config();
    my $conf = $guest->{class}->load_config($vmid);
    _tn_import_check_conf($conf, $vmid, $guest->{label});

    my $vols = $class->_tn_import_volumes($storecfg, $conf, $vmid, $guest);
    _tn_import_check_feature($guest, $conf, $vmid, $storecfg);
    my $log_scfg = $vols->[0]{scfg};

    my $plan = $class->_tn_import_plan($vols, $conf, $opts);
    $plan->{imported} = 0;
    $plan->{dropped}  = [];
    $plan->{dry_run}  = $opts->{dry_run} ? 1 : 0;

    return $plan if $opts->{dry_run};
    return $plan if !@{ $plan->{import} };

    my $origin_ds = $vols->[0]{full};
    my $stamp = POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time()));
    my @listed = map { $_->{name} } @{ $plan->{import} };

    my $written = $guest->{class}->lock_config($vmid, sub {
        # Everything is re-established inside the lock: the config may have
        # gained a lock, a template flag, a snapshot or a different disk, and
        # the array may have lost or cloned a candidate, between the plan
        # above and this line. Nothing from outside the lock is reused except
        # the operator's allow-list.
        my $conf = $guest->{class}->load_config($vmid);
        _tn_import_check_conf($conf, $vmid, $guest->{label});

        my $vols_now = $class->_tn_import_volumes($storecfg, $conf, $vmid, $guest);
        die "$guest->{label} $vmid changed its disks while the import was "
          . "being planned; nothing was written\n"
            if join(',', map { $_->{volid} } @$vols_now)
            ne join(',', map { $_->{volid} } @$vols);

        # Asked again with the lock held, for the same reason everything
        # else is: a disk can be moved to a storage without snapshots, or a
        # bind mount added, between the plan and the write.
        _tn_import_check_feature($guest, $conf, $vmid, $storecfg);

        my $fresh = $class->_tn_import_plan($vols_now, $conf, $opts);

        my %kept = map { $_->{name} => 1 } @{ $fresh->{import} };
        $fresh->{dropped} = [ grep { !$kept{$_} } @listed ];

        # Nothing left to do - the idempotent case, and the case where every
        # candidate vanished. Writing here would rewrite an unchanged config.
        return $fresh if !@{ $fresh->{import} };

        for my $entry (@{ $fresh->{import} }) {
            my $name = $entry->{name};
            my $snap = $conf->{snapshots}{$name} = {};
            $guest->{class}->__snapshot_copy_config($conf, $snap);
            delete $snap->{parent};
            $snap->{parent}   = $entry->{parent} if defined $entry->{parent};
            $snap->{snaptime} = $entry->{snaptime};
            $snap->{description} = "Imported from TrueNAS $origin_ds\@$name on "
                . "$stamp - config as of import, no RAM";
        }
        $conf->{parent} = $fresh->{new_parent} if defined $fresh->{new_parent};

        $guest->{class}->write_config($vmid, $conf);

        return $fresh;
    });

    $written->{imported} = scalar @{ $written->{import} };
    $written->{dropped} //= [];
    $written->{dry_run}  = 0;

    # Level 0: writing a guest configuration is worth a line in syslog even
    # with debugging off - it is how an operator finds out later which run
    # added the sections.
    _log($log_scfg, 0, 'info', "[TrueNAS] import-snapshots: $guest->{label} "
        . "$vmid adopted $written->{imported} snapshot(s) from the array");
    _log($log_scfg, 0, 'warning', "[TrueNAS] import-snapshots: "
        . "$guest->{label} $vmid: "
        . scalar(@{ $written->{dropped} }) . " listed snapshot(s) no longer "
        . "qualified when the lock was held: "
        . join(', ', @{ $written->{dropped} }))
        if @{ $written->{dropped} };

    return $written;
}

# `truenas-proxmox-manage import-snapshots <vmid> [--dry-run] [--yes] [--match REGEX]`
# Returns the process exit code: 0 done, 1 error, 2 cancelled (install.sh's
# EXIT_USER_CANCEL).
sub snapshot_import_cli(@argv) {
    my ($vmid, $dry_run, $yes, $match);

    while (@argv) {
        my $arg = shift @argv;
        if    ($arg eq '--dry-run' || $arg eq '-n') { $dry_run = 1 }
        elsif ($arg eq '--yes'     || $arg eq '-y') { $yes = 1 }
        elsif ($arg eq '--match') {
            $match = shift @argv;
            if (!defined($match) || $match eq '') {
                print STDERR "--match needs a regular expression\n";
                return 1;
            }
        }
        elsif ($arg =~ /^--match=(.*)$/) { $match = $1 }
        elsif ($arg eq '--help' || $arg eq '-h') {
            print "Usage: truenas-proxmox-manage import-snapshots <vmid> "
                . "[--dry-run] [--yes] [--match REGEX]\n";
            return 0;
        }
        elsif ($arg =~ /^(\d+)$/ && !defined($vmid)) { $vmid = $1 }
        else {
            print STDERR "unexpected argument '$arg'\n";
            return 1;
        }
    }

    if (!defined($vmid)) {
        print STDERR "Usage: truenas-proxmox-manage import-snapshots <vmid> "
            . "[--dry-run] [--yes] [--match REGEX]\n";
        return 1;
    }

    my $plan = eval {
        __PACKAGE__->import_foreign_snapshots($vmid, { dry_run => 1, match => $match });
    };
    if (my $err = $@) {
        print STDERR "import-snapshots: $err";
        return 1;
    }

    for my $entry (@{ $plan->{import} }) {
        printf("import   %-40s %s\n", $entry->{name},
            POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime($entry->{snaptime})));
    }
    for my $name (sort keys %{ $plan->{partial} }) {
        printf("partial  %-40s missing on: %s\n", $name,
            join(', ', @{ $plan->{partial}{$name} }));
    }
    for my $name (sort keys %{ $plan->{invalid} }) {
        printf("invalid  %-40s %s\n", $name, $plan->{invalid}{$name});
    }
    for my $name (@{ $plan->{present} }) {
        printf("present  %-40s already in the guest configuration\n", $name);
    }

    # Each entry carries the identity of the snapshot that was printed, not
    # just its name, so the second run can tell "still there" from "a new
    # snapshot wearing the same name".
    my @confirmed = map { { name => $_->{name}, identity => $_->{identity} } }
                    @{ $plan->{import} };
    if (!@confirmed) {
        print "Nothing to import for guest $vmid.\n";
        return 0;
    }
    if ($dry_run) {
        printf("Dry run: %d snapshot(s) would be imported into guest %s.\n",
            scalar(@confirmed), $vmid);
        return 0;
    }

    if (!$yes) {
        # No terminal to ask on. Assuming consent here would let a pipeline
        # write guest configurations nobody looked at, so this is a refusal,
        # and a refusal does not exit 0.
        if (!-t STDIN) {
            print STDERR "import-snapshots: no TTY to confirm on; "
                . "re-run with --yes to import without asking\n";
            return 2;
        }
        printf("Import %d snapshot(s) into the configuration of guest %s? [y/N] ",
            scalar(@confirmed), $vmid);
        my $answer = <STDIN>;
        $answer = '' if !defined($answer);
        chomp($answer);
        if ($answer !~ /^y(es)?$/i) {
            print "Aborted; nothing was written.\n";
            return 2;
        }
    }

    # The allow-list is what was printed above: the run inside the lock plans
    # again against the array, and anything that changed in between is
    # dropped and reported rather than quietly imported.
    my $res = eval {
        __PACKAGE__->import_foreign_snapshots($vmid,
            { match => $match, only => \@confirmed });
    };
    if (my $err = $@) {
        print STDERR "import-snapshots: $err";
        return 1;
    }

    for my $name (@{ $res->{dropped} }) {
        print "skipped  $name: no longer qualified when the configuration "
            . "was locked\n";
    }
    print "Imported $res->{imported} snapshot(s) into guest $vmid.\n";
    return 0;
}

# List TrueNAS iSCSI targets (array of hashes; each has at least {id, name, ...}).
sub _tn_targets {
    my ($scfg) = @_;
    my $storage_id = _cache_host_key($scfg);
    my $cached = _get_cached($storage_id, 'targets');
    return $cached if $cached;
    my $list = _api_call($scfg, 'iscsi.target.query', []);
    return _set_cache($storage_id, 'targets', $list // []);
}

# Find the first free disk name for a VM using a single batch query.
# Replaces the naive loop that called _tn_dataset_get per candidate name.
sub _find_free_disk_name {
    my ($scfg, $vmid) = @_;
    my $dataset = $scfg->{tn_dataset};
    my $prefix = "vm-$vmid-disk-";

    # Single query: fetch all children of the parent dataset matching either
    # the live (vm-) or templated (base-) disk-name prefix for this VMID.
    # Templated disks are excluded from consideration here just as much as
    # live ones do -- otherwise moving a second disk of the same template to
    # this storage picks an index already used by a previously-moved
    # (and by-then-renamed-to-base-) disk, and the later create_base rename
    # collides with it (issue #85).
    # Escape regex special chars in dataset path (TrueNAS uses Python regex)
    (my $dataset_escaped = $dataset) =~ s/([.+*?^()\[\]{}|\\])/\\$1/g;
    my $children = eval {
        _api_call($scfg, 'pool.dataset.query', [
            [["pool", "=", (split('/', $dataset))[0]], ["name", "~", "^${dataset_escaped}/(?:vm|base)-${vmid}-disk-"]]
        ]);
    };
    my %existing;
    if ($children && ref($children) eq 'ARRAY') {
        %existing = map { $_->{id} => 1 } @$children;
    }

    for (my $n = 0; $n < 1000; $n++) {
        my $candidate = "${prefix}$n";
        next if $existing{"$dataset/${prefix}$n"} || $existing{"$dataset/base-$vmid-disk-$n"};
        return $candidate;
    }

    die sprintf(
        "Unable to find free disk name after 1000 attempts (VM %d)\n\n" .
        "This usually indicates:\n" .
        "  1. Too many disks already exist for this VM (max: 1000)\n" .
        "  2. Naming conflicts with existing volumes\n\n" .
        "Dataset: %s\n" .
        "Pattern attempted: vm-%d-disk-0 through vm-%d-disk-999\n\n" .
        "Troubleshooting:\n" .
        "  - Check TrueNAS dataset '%s' for orphaned volumes\n" .
        "  - Verify API connectivity and permissions\n" .
        "  - Check TrueNAS logs: /var/log/middlewared.log\n",
        $vmid, $dataset, $vmid, $vmid, $dataset
    );
}

# Generate a deterministic, globally unique iSCSI extent name.
# Format: "<zname>-<8-char-sha1-hex>" derived from the full dataset path.
# Weight volumes (pve-weight-*) are exempt and keep name == zname.
# TrueNAS constraints: lowercase, [a-z0-9.\-:], max 64 chars.
sub _generate_extent_name($scfg, $zname) {
    # Weight volumes are exempt - keep name unchanged
    return $zname if $zname =~ /^pve-weight-/;

    my $full_path = $scfg->{tn_dataset} . "/" . $zname;
    my $hash8 = substr(sha1_hex($full_path), 0, 8);

    # Enforce TrueNAS naming constraints
    my $base = lc($zname);
    $base =~ s/[^a-z0-9.\-:]//g;

    # Max 64 chars total; suffix is "-" + 8 hex = 9 chars
    my $max_base = 64 - 9;
    if (length($base) > $max_base) {
        $base = substr($base, 0, $max_base);
    }

    return "${base}-${hash8}";
}

# Derive a deterministic, collision-resistant zvol name for an ephemeral
# snapshot clone (issue #42). LXC vzdump snapshot-mode backups call
# activate_volume/path/deactivate_volume with $snapname set; we expose a
# throwaway clone of <zvol>@<snapname> as its own block device.
#
# The same ($zname, $snapname) pair must always map to the same clone name so
# path() can locate the device that activate_volume created, and so
# deactivate_volume can tear down exactly what was exposed. We hash the
# source pair to guarantee a unique, name-constraint-safe suffix.
use constant SNAPSHOT_CLONE_PREFIX => 'vzdump-';

sub _snapshot_clone_zname {
    my ($scfg, $zname, $snapname) = @_;
    my $hash8 = substr(sha1_hex("$zname\@$snapname"), 0, 8);
    my $base  = lc(SNAPSHOT_CLONE_PREFIX . "$zname-$snapname");
    # Match TrueNAS zvol name constraints (mirror _generate_extent_name):
    # lowercase alphanumerics plus '.', '-'. Drop everything else.
    $base =~ s/[^a-z0-9.\-]//g;
    my $max_base = 63 - 9;   # leave room for '-' + 8 hex chars (<= 63 total)
    $base = substr($base, 0, $max_base) if length($base) > $max_base;
    return "${base}-${hash8}";
}

sub _snapshot_clone_paths {
    my ($scfg, $zname, $snapname) = @_;
    my $clone_zname = _snapshot_clone_zname($scfg, $zname, $snapname);
    my $clone_full = $scfg->{tn_dataset} . '/' . $clone_zname;
    return ($clone_zname, $clone_full, "zvol/$clone_full");
}

sub _is_snapshot_clone_zname {
    my ($zname) = @_;
    return index($zname, SNAPSHOT_CLONE_PREFIX) == 0;
}

# Cloud-init disks must be named exactly "vm-<vmid>-cloudinit" with no
# "vol-" prefix and no transport-metadata suffix (-lun<N> / -ns<uuid>) --
# PVE core's drive_is_cloudinit() pattern-matches the volid and only
# regenerates cloud-init drives on clone/template if it recognizes this
# exact form (issue #84). Because the name can't carry embedded metadata,
# these volumes resolve their transport device dynamically by zvol path
# at path()/activate_volume time instead of from the volname.
sub _is_cloudinit_zname {
    my ($zname) = @_;
    return $zname =~ /^vm-\d+-cloudinit$/;
}

# Resolve an iSCSI extent by its disk (zvol) path instead of by name.
# Returns the first matching extent hashref, or undef if none found.
sub _resolve_extent_by_disk($scfg, $zname) {
    my $zvol_path = "zvol/" . $scfg->{tn_dataset} . "/" . $zname;
    my $matches = _tn_extent_query_by_disk($scfg, $zvol_path) // [];
    return $matches->[0];
}

sub _tn_extent_create($scfg, $zname, $full, $extent_name=undef) {
    my $zvol_path = "zvol/$full";
    my $submitted_name = $extent_name // $zname;
    my $payload = {
        name => $submitted_name, type => 'DISK', disk => $zvol_path, insecure_tpc => JSON::PP::true,
    };
    # Zvol-visibility retry: TN validates iscsi.extent.create by stat'ing
    # /dev/zvol/<ds>; right after pool.snapshot.clone or pool.dataset.create
    # returns, udev may not have materialized the symlink yet. Poll-retry on
    # that specific validator error only, up to ~3 s.
    my $result;
    my $err;
    my $max_zvol_wait_attempts = 15;
    for (my $attempt = 1; $attempt <= $max_zvol_wait_attempts; $attempt++) {
        $result = eval { _api_call_mutate($scfg, 'iscsi.extent.create', [ $payload ]) };
        $err = $@;
        last if !$err;
        last if !_is_zvol_not_ready_error($err);
        _log($scfg, 1, 'info',
            "[TrueNAS] _tn_extent_create: /dev/zvol/$full not visible yet " .
            "(attempt $attempt/$max_zvol_wait_attempts), waiting for udev");
        select(undef, undef, undef, 0.2);
    }
    # Fix B: post-hoc reuse on unique-name conflict. See classifier
    # comment on _is_extent_name_conflict_error above. Look up by NAME
    # (exact known value); reuse only when disk field matches ours; log
    # loudly at level 0 if TN has a same-named extent with a different
    # disk field.
    if ($err && _is_extent_name_conflict_error($err)) {
        _clear_cache(_cache_host_key($scfg));
        my $by_name_matches = _tn_extent_query_by_name($scfg, $submitted_name) // [];
        my $by_name = $by_name_matches->[0];
        if ($by_name) {
            if (($by_name->{disk} // '') eq $zvol_path) {
                _log($scfg, 1, 'info',
                    "[TrueNAS] _tn_extent_create: name-conflict resolved by reuse " .
                    "id=$by_name->{id} name=$submitted_name for $zvol_path (Fix B)");
                $result = $by_name;
                $err = '';
            } elsif (_iscsi_extent_recover_stale_base_name($scfg, $by_name, $zvol_path)) {
                # Historical create_base extent-rename gap. Stale extent
                # renamed to its proper base-*-<hash>; retry our create.
                $result = eval { _api_call_mutate($scfg, 'iscsi.extent.create', [ $payload ]) };
                $err = $@;
                if (!$err) {
                    _log($scfg, 0, 'info',
                        "[TrueNAS] _tn_extent_create: retry after stale-base rename succeeded for $submitted_name");
                }
            } else {
                _log($scfg, 0, 'err',
                    "[TrueNAS] _tn_extent_create: extent name '$submitted_name' " .
                    "already on TN (id=$by_name->{id}) with disk='" .
                    ($by_name->{disk} // '<undef>') . "', we expected disk='$zvol_path'. " .
                    "Refusing to reuse.");
            }
        } else {
            _log($scfg, 0, 'warning',
                "[TrueNAS] _tn_extent_create: TN said name '$submitted_name' is not unique " .
                "but a follow-up iscsi.extent.query does not surface it.");
        }
    }
    die $err if $err;
    # Invalidate cache since extents list has changed
    _clear_cache(_cache_host_key($scfg)) if $result;
    return $result;
}
sub _tn_extent_delete($scfg, $extent_id) {
    my $result = _api_call_mutate($scfg, 'iscsi.extent.delete', [ $extent_id ]);
    # Invalidate cache since extents list has changed
    _clear_cache(_cache_host_key($scfg)) if $result;
    return $result;
}
sub _tn_targetextent_create($scfg, $target_id, $extent_id, $lun) {
    # Check if this mapping already exists (narrow query: 0 or 1 row)
    my $existing_matches = _tn_targetextent_query_by_target_extent($scfg, $target_id, $extent_id) // [];
    my $existing_map = $existing_matches->[0];

    if ($existing_map) {
        # Mapping already exists - idempotent behavior
        _log($scfg, 2, 'debug', "[TrueNAS] Target-extent mapping already exists for extent_id=$extent_id (LUN $existing_map->{lunid})");
        return $existing_map;
    }

    # Mapping doesn't exist, create it
    my $payload = { target => $target_id, extent => $extent_id };
    $payload->{lunid} = $lun if defined $lun;
    my $result = eval { _api_call_mutate($scfg, 'iscsi.targetextent.create', [ $payload ]); };
    my $err = $@;

    if ($err) {
        if ($err =~ /Extent is already in use/i) {
            # Cache may be stale -- narrow-query TN directly to check whether
            # the mapping is now visible (a concurrent cluster node may have
            # created it after our first check). Invalidate the full-list
            # cache too so unrelated readers on this process pick up the
            # new state on their next miss.
            _clear_cache(_cache_host_key($scfg));
            my $fresh_matches = _tn_targetextent_query_by_target_extent($scfg, $target_id, $extent_id) // [];
            my $found = $fresh_matches->[0];
            if ($found) {
                _log($scfg, 2, 'debug', "[TrueNAS] Target-extent mapping already exists (stale cache) for extent_id=$extent_id (LUN $found->{lunid})");
                return $found;
            }
        }
        die $err;
    }

    # Invalidate cache since targetextents list has changed
    _clear_cache(_cache_host_key($scfg)) if $result;
    return $result;
}
sub _tn_targetextent_delete($scfg, $tx_id) {
    my $result = _api_call_mutate($scfg, 'iscsi.targetextent.delete', [ $tx_id ]);
    # Invalidate cache since targetextents list has changed
    _clear_cache(_cache_host_key($scfg)) if $result;
    return $result;
}
sub _handle_fk_stale_extent {
    my ($scfg, $weight_extent_id) = @_;

    _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight extent ID $weight_extent_id is stale (FK constraint failed), deleting to force resync");
    eval { _tn_extent_delete($scfg, $weight_extent_id) };
    if ($@) {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: stale extent delete failed (may already be gone): $@");
    }
    _clear_cache(_cache_host_key($scfg));
}

sub _current_lun_for_zname($scfg, $zname) {
    my $zvol_path = "zvol/$scfg->{tn_dataset}/$zname";
    my $ext_matches = _tn_extent_query_by_disk($scfg, $zvol_path) // [];
    my $extent = $ext_matches->[0];
    return undef if !$extent || !defined $extent->{id};
    my $target_id = _resolve_target_id($scfg);
    my $tx_matches = _tn_targetextent_query_by_target_extent($scfg, $target_id, $extent->{id}) // [];
    my $tx = $tx_matches->[0];
    return defined($tx) ? $tx->{lunid} : undef;
}

# Resolve the LUN to use for a volume: the embedded one if the volname
# carries it, otherwise looked up by zvol path. Cloud-init volumes
# (issue #84) have no embedded metadata and always take the lookup path.
sub _resolve_iscsi_lun($scfg, $zname, $known_lun) {
    return $known_lun if defined $known_lun;
    my $lun = _current_lun_for_zname($scfg, $zname);
    die "Could not locate iSCSI LUN for '$zname' (IQN " . ($scfg->{tn_target_iqn} // '') . ")\n"
        if !defined $lun;
    return $lun;
}

# Pre-flight validation checks before volume allocation
# Returns arrayref of error messages (empty if all checks pass)
# Results are cached for 30 seconds to avoid redundant checks during multi-disk creation.
sub _preflight_check_alloc {
    my ($scfg, $size_bytes) = @_;
    my $api_host_key = _cache_host_key($scfg);

    # Skip redundant preflight checks when allocating multiple disks rapidly.
    # TTL 300 s. Uses BOTH an in-process %_preflight_last_ok hash AND a
    # /run/truenas-plugin/preflight-<key> stamp file so the cache survives
    # across pvedaemon worker respawns (each worker starts fresh in-process,
    # so the in-process cache alone missed the mark: cluster_test_run
    # 2026-08-17 alpha10 TIMING data showed every VM 222 alloc still paying
    # the full 6 s because disk-0 and disk-1 hit different pvedaemon PIDs).
    # All four preflight signals (TN reachable, pool ONLINE, service
    # RUNNING, sufficient space) also surface as clear TN-side errors on
    # the actual pool.dataset.create if they go wrong mid-window -- this
    # cache is a rate-limit on redundant health chatter, not a correctness
    # gate. /run is tmpfs, so a reboot clears the stamps automatically.
    my $stamp_file = _preflight_stamp_path($api_host_key);
    my $stamp_mtime = (stat($stamp_file))[9];
    my $shared_age = defined $stamp_mtime ? time() - $stamp_mtime : undef;
    my $inproc_age = time() - ($_preflight_last_ok{$api_host_key} // 0);
    my $age = defined $shared_age ? ($shared_age < $inproc_age ? $shared_age : $inproc_age) : $inproc_age;
    # TTL bumped 300 -> 3600 s after alpha14 TIMING data showed cache
    # expiring between test bursts (test framework's ~5 min inter-burst
    # gap crossed the 300 s TTL, so every burst's first alloc paid the
    # full 10-13 s preflight and queued the whole 3-node cluster past
    # the pveproxy 60 s ceiling). Preflight's signals (pool ONLINE,
    # service RUNNING, dataset exists) are stable over hour timescales
    # and free-space accounting stays fresh via pvestatd's 10 s status()
    # polling -- the cache is a rate-limit on redundant health chatter,
    # not a correctness gate.
    if ($age < 3600) {
        _log($scfg, 2, 'debug', "[TrueNAS] _preflight_check_alloc: skipping (recently validated ${age}s ago)");
        return [];
    }

    my @errors;
    my $mode = $scfg->{tn_transport_mode} // 'iscsi';

    # Check 1: TrueNAS API is reachable AND we're actually authenticated.
    # 'core.ping' would satisfy reachable-ness but is no_auth_required, so
    # a broker connection whose session has silently expired at 30 days
    # (issue #98) would falsely report the API as healthy. 'auth.me'
    # requires auth, so it fails cleanly if the session is gone -- and
    # the broker's own liveness check on the next call will drop and
    # re-auth the pool entry.
    eval {
        _api_call($scfg, 'auth.me', []);
    };
    if ($@) {
        push @errors, "TrueNAS API is unreachable: $@";
    }

    # Check 2: Pool health (degraded pools are functional but warrant a warning)
    my $pool = _tn_pool_health($scfg);
    if ($pool) {
        my ($pool_name) = split('/', $scfg->{tn_dataset}, 2);
        if (!$pool->{healthy}) {
            _log($scfg, 0, 'warning',
                "[TrueNAS] preflight: pool '$pool_name' is not healthy (status: " .
                ($pool->{status} // 'UNKNOWN') . ")");
        }
        if (($pool->{status} // '') ne 'ONLINE') {
            push @errors, sprintf(
                "ZFS pool '%s' is not ONLINE (status: %s)\n" .
                "  Check pool status in TrueNAS: Storage > Pools",
                $pool_name, $pool->{status} // 'UNKNOWN'
            );
        }
    }

    # Check 3: Service is running (transport-specific)
    if ($mode eq 'iscsi') {
        eval {
            my $services = _api_call($scfg, 'service.query',
                [[ ["service", "=", "iscsitarget"] ]]);

            if (!$services || !@$services) {
                push @errors, "Unable to query iSCSI service status";
            } elsif ($services->[0]->{state} ne 'RUNNING') {
                push @errors, sprintf(
                    "TrueNAS iSCSI service is not running (state: %s)\n" .
                    "  Start the service in TrueNAS: System Settings > Services > iSCSI",
                    $services->[0]->{state} // 'UNKNOWN'
                );
            }
        };
        if ($@) {
            push @errors, "Cannot verify iSCSI service status: $@";
        }
    } elsif ($mode eq 'nvme-tcp') {
        eval {
            my $services = _api_call($scfg, 'service.query',
                [[ ["service", "=", "nvmet"] ]]);

            if (!$services || !@$services) {
                push @errors, "Unable to query NVMe-oF service status";
            } elsif ($services->[0]->{state} ne 'RUNNING') {
                push @errors, sprintf(
                    "TrueNAS NVMe-oF service is not running (state: %s)\n" .
                    "  Start the service in TrueNAS: System Settings > Services > NVMe-oF Target",
                    $services->[0]->{state} // 'UNKNOWN'
                );
            }
        };
        if ($@) {
            push @errors, "Cannot verify NVMe-oF service status: $@";
        }
    }

    # Check 4: Sufficient space available (with 20% overhead)
    if (defined $size_bytes) {
        my $bytes = int($size_bytes);
        my $required = $bytes * 1.2;

        eval {
            my $ds_info = _tn_dataset_get($scfg, $scfg->{tn_dataset});
            if ($ds_info) {
                my $available = _normalize_value($ds_info->{available}) || 0;

                if ($available < $required) {
                    push @errors, sprintf(
                        "Insufficient space on dataset '%s': need %s (with 20%% overhead), have %s available",
                        $scfg->{tn_dataset},
                        _format_bytes($required),
                        _format_bytes($available)
                    );
                }
            }
        };
        if ($@) {
            push @errors, "Cannot verify available space: $@";
        }
    }

    # Check 5: Target/subsystem exists and is configured (transport-specific)
    if ($mode eq 'iscsi') {
        eval {
            my $target_id = _resolve_target_id($scfg);
            if (!defined $target_id) {
                push @errors, sprintf(
                    "iSCSI target not found: %s\n" .
                    "  Verify target exists in TrueNAS: Shares > Block Shares (iSCSI) > Targets",
                    $scfg->{tn_target_iqn}
                );
            }
        };
        if ($@) {
            push @errors, "Cannot verify iSCSI target: $@";
        }
    } elsif ($mode eq 'nvme-tcp') {
        eval {
            my $nqn = $scfg->{tn_subsystem_nqn};
            if (!$nqn) {
                push @errors, "NVMe subsystem NQN not configured in storage.cfg";
                return;
            }

            # Query subsystem to ensure it exists
            my $subsystems = _api_call($scfg, 'nvmet.subsys.query',
                [[ ["subnqn", "=", $nqn] ]]);

            if (!$subsystems || !@$subsystems) {
                push @errors, sprintf(
                    "NVMe subsystem not found: %s\n" .
                    "  Verify subsystem exists in TrueNAS: Sharing > NVMe-oF > Subsystems\n" .
                    "  Or it will be auto-created during first volume allocation",
                    $nqn
                );
            }
        };
        if ($@) {
            # Subsystem query failed - will be auto-created on first allocation
            _log($scfg, 1, 'info', "[TrueNAS] NVMe subsystem pre-flight check skipped (will auto-create): $@");
        }
    }

    # Check 6: Parent dataset exists
    eval {
        my $ds = _tn_dataset_get($scfg, $scfg->{tn_dataset});
        if (!$ds) {
            push @errors, sprintf(
                "Parent dataset does not exist: %s\n" .
                "  Create the dataset in TrueNAS: Storage > Pools",
                $scfg->{tn_dataset}
            );
        }
    };
    if ($@) {
        push @errors, "Cannot verify parent dataset: $@";
    }

    # Cache successful result: touch a stamp file in /run so sibling
    # pvedaemon workers on this node see the pass, and set in-process
    # hash for the fast path in subsequent calls from this worker.
    _log($scfg, 0, 'info', "[TrueNAS] TIMING preflight-end errors=" . scalar(@errors));
    if (!@errors) {
        $_preflight_last_ok{$api_host_key} = time();
        my $stamp_file = _preflight_stamp_path($api_host_key);
        _log($scfg, 0, 'info', "[TrueNAS] TIMING preflight-stamp path=$stamp_file");
        eval {
            my $dir = $stamp_file; $dir =~ s{/[^/]+$}{};
            if (! -d $dir) {
                mkdir($dir, 0755) or die "mkdir($dir): $!";
            }
            my $fh;
            open($fh, '>', $stamp_file) or die "open($stamp_file): $!";
            close($fh);
            utime(undef, undef, $stamp_file) or die "utime: $!";
        };
        if (my $err = $@) {
            _log($scfg, 0, 'warning', "[TrueNAS] TIMING preflight-stamp WRITE FAILED: $err");
        } else {
            _log($scfg, 0, 'info', "[TrueNAS] TIMING preflight-stamp WROTE OK");
        }
    }

    return \@errors;
}

# Filesystem path for the preflight-cache stamp. Keyed on the same
# host+key digest used by the in-process cache, so multiple storages
# pointing at different TN hosts don't false-share the pass.
sub _preflight_stamp_path {
    my ($host_key) = @_;
    my $safe = $host_key;
    $safe =~ s/[^A-Za-z0-9._-]/_/g;
    return "/run/truenas-plugin/preflight-$safe";
}

# Filesystem path for the status()-capacity cache stamp. The stamp
# holds the JSON-encoded pool.dataset.get_instance result so a fresh
# process (i.e. every `pvesm status` invocation) can pick up a recent
# value without hitting TrueNAS again. Keyed on the same host+storeid+
# dataset triple as the in-process cache method so entries don't
# false-share across storages pointing at different TN hosts.
sub _status_stamp_path {
    my ($status_method) = @_;
    my $safe = $status_method;
    $safe =~ s/[^A-Za-z0-9._-]/_/g;
    return "/run/truenas-plugin/status-$safe";
}

# Read the on-disk status stamp for $status_method. Returns the cached
# dataset hashref on hit within $STATUS_CAPACITY_STAMP_TTL_S, undef
# otherwise. Never dies; a corrupt / unreadable stamp is treated as
# a miss (and stats counter bumped so tuning can spot it).
sub _read_status_stamp {
    my ($scfg, $status_method) = @_;
    my $path = _status_stamp_path($status_method);
    my $mtime = (stat($path))[9];
    return undef if !defined $mtime;
    my $age = time() - $mtime;
    return undef if $age < 0 || $age >= $STATUS_CAPACITY_STAMP_TTL_S;
    my $decoded = eval {
        open(my $fh, '<', $path) or die "open: $!";
        local $/;
        my $blob = <$fh>;
        close($fh);
        decode_json($blob);
    };
    if ($@ || ref($decoded) ne 'HASH') {
        $_status_capacity_cache_stats{stamp_fail}++;
        _log($scfg, 2, 'debug', "[TrueNAS] status-cache: stamp read failed at $path: " . ($@ // 'not a hash'));
        return undef;
    }
    return $decoded;
}

# Atomically write the pool.dataset.get_instance result to the on-disk
# status stamp. Uses tmp+rename so a concurrent reader never sees a
# partial JSON blob. Best-effort: filesystem trouble never bubbles up
# to the caller's status() path.
sub _write_status_stamp {
    my ($scfg, $status_method, $ds) = @_;
    my $path = _status_stamp_path($status_method);
    my $rc = eval {
        my $dir = $path;
        $dir =~ s{/[^/]+$}{};
        if (!-d $dir) {
            require File::Path;
            File::Path::make_path($dir, { mode => 0700 });
        }
        my $tmp = "$path.$$";
        open(my $fh, '>', $tmp) or die "open $tmp: $!";
        chmod 0600, $tmp;
        print $fh encode_json($ds);
        close($fh) or die "close $tmp: $!";
        rename($tmp, $path) or die "rename $tmp -> $path: $!";
        1;
    };
    if ($@ || !$rc) {
        $_status_capacity_cache_stats{stamp_fail}++;
        _log($scfg, 2, 'debug', "[TrueNAS] status-cache: stamp write failed at $path: " . ($@ // 'unknown'));
        return;
    }
    $_status_capacity_cache_stats{stamp_write}++;
}

# Remove the on-disk status stamp (best-effort). Called by
# _invalidate_status_capacity_cache so any mutation that already
# invalidates the in-process cache also drops the shared entry.
sub _unlink_status_stamp {
    my ($status_method) = @_;
    my $path = _status_stamp_path($status_method);
    unlink($path);
}

# Robustly resolve the TrueNAS target id for a configured fully-qualified IQN.
# Result is cached per IQN to avoid redundant API calls within the same process.
sub _resolve_target_id {
    my ($scfg) = @_;
    my $want = $scfg->{tn_target_iqn} // die "tn_target_iqn not set in storage.cfg\n";
    my $api_host = _cache_host_key($scfg);

    # Use the TTL-based %API_CACHE (60s) so stale IDs are automatically refreshed
    # and _clear_cache() always invalidates this alongside other cached data.
    my $cached_id = _get_cached($api_host, "target_id:$want");
    if (defined $cached_id) {
        _log($scfg, 2, 'debug', "[TrueNAS] _resolve_target_id: using cached target_id=$cached_id for $want");
        return $cached_id;
    }

    # 1) Get targets; if empty, surface a clear diagnostic
    my $targets = _tn_targets($scfg) // [];
    if (!@$targets) {
        # Try to fetch the base name for a more helpful message
        my $global   = eval { _api_call($scfg, 'iscsi.global.config', []) } // {};
        my $basename = $global->{basename} // '(unknown)';
        my $portal   = $scfg->{tn_discovery_portal} // '(none)';
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
    my $global   = eval { _api_call($scfg, 'iscsi.global.config', []) } // {};
    my $basename = $global->{basename} // '';

    # 3) Try several matching strategies
    my $found;
    for my $t (@$targets) {
        my $name = $t->{name} // '';
        my $full = ($basename && $name) ? "$basename:$name" : undef;
        # Some SCALE builds include 'iqn' per target; prefer exact match if present
        if (defined $t->{iqn} && $t->{iqn} eq $want) { $found = $t; last; }
        # Otherwise compare constructed IQN or target suffix
        if ($full && $full eq $want) { $found = $t; last; }
        if ($name && $want =~ /:\Q$name\E$/) { $found = $t; last; }
    }
    if (!$found) {
        my @available_iqns = map {
            my $name = $_->{name} // 'unnamed';
            my $iqn = $_->{iqn} // ($basename ? "$basename:$name" : $name);
            "  - $iqn (ID: $_->{id})";
        } @$targets;

        die sprintf(
            "Could not resolve iSCSI target ID for configured IQN\n\n" .
            "Configured IQN: %s\n" .
            "TrueNAS base name: %s\n" .
            "Targets found: %d\n\n" .
            "Available targets:\n%s\n\n" .
            "Troubleshooting steps:\n" .
            "  1. Verify target exists in TrueNAS:\n" .
            "     -> GUI: Shares > Block Shares (iSCSI) > Targets\n" .
            "  2. Check target_iqn in storage config matches exactly:\n" .
            "     -> File: /etc/pve/storage.cfg\n" .
            "     -> Current: target_iqn %s\n" .
            "  3. Ensure iSCSI service is running:\n" .
            "     -> GUI: System Settings > Services > iSCSI\n" .
            "  4. Verify API key has 'Sharing' read permissions:\n" .
            "     -> GUI: Credentials > API Keys\n\n" .
            "Note: IQN format is typically: iqn.YYYY-MM.tld.domain:identifier\n",
            $want,
            $basename || '(not set)',
            scalar(@$targets),
            (@available_iqns ? join("\n", @available_iqns) : "  (none)"),
            $want
        );
    }
    return _set_cache($api_host, "target_id:$want", $found->{id});
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
# Check if target sessions are already active
sub _target_sessions_active($scfg) {
    my $iqn = $scfg->{tn_target_iqn};

    # Use eval to safely check for existing sessions
    my @session_lines = eval { _run_lines(['iscsiadm', '-m', 'session']) };
    return 0 if $@; # If command fails (no sessions exist), return false

    # Check if our target has active sessions
    for my $line (@session_lines) {
        return 1 if $line =~ /\Q$iqn\E/;
    }
    return 0;
}

# Check if a specific portal has an active session for this target
sub _portal_connected($scfg, $portal, $session_lines_ref = undef) {
    my $iqn = $scfg->{tn_target_iqn};
    my $norm_portal = _normalize_portal($portal);

    # An FQDN portal in storage.cfg never matches iscsiadm's session
    # line, which always reports the resolved IPv4 (issue #102).
    # Precompute the IP-resolved form so a session on 192.0.2.10:3260
    # still counts as "connected" for a configured portal like
    # storage.example.com:3260. On IP literals _host_ipv4 is a no-op
    # so this costs nothing there. Failures resolve back to the
    # original host (fallback in _host_ipv4), which just falls
    # through to the existing literal-compare path.
    my $ip_portal = $norm_portal;
    if ($norm_portal =~ /^(.+):(\d+)$/) {
        my ($host, $port) = ($1, $2);
        # Skip IPv6 literals ($host still contains ':' after strip)
        if ($host !~ /:/) {
            my $ip = _host_ipv4($host);
            $ip_portal = "$ip:$port" if $ip && $ip ne $host;
        }
    }

    # Get active sessions if not provided
    my @session_lines;
    if ($session_lines_ref && ref($session_lines_ref) eq 'ARRAY') {
        @session_lines = @$session_lines_ref;
    } else {
        @session_lines = eval { _run_lines(['iscsiadm', '-m', 'session']) };
        return 0 if $@;
    }

    # Check if this portal has an active session
    for my $line (@session_lines) {
        # Session line format: tcp: [1] 10.15.14.172:3260,1 iqn.2005-10.org.freenas.ctl:target0
        if ($line =~ /\Q$norm_portal\E.*\Q$iqn\E/) {
            return 1;
        }
        if ($ip_portal ne $norm_portal
            && $line =~ /\Q$ip_portal\E.*\Q$iqn\E/) {
            return 1;
        }
    }
    return 0;
}

# Check if all configured portals have active sessions for this target
sub _all_portals_connected($scfg) {
    my $iqn = $scfg->{tn_target_iqn};

    # Get all configured portals
    my @portals = ();
    push @portals, _normalize_portal($scfg->{tn_discovery_portal}) if $scfg->{tn_discovery_portal};
    push @portals, map { _normalize_portal($_) } split(/\s*,\s*/, $scfg->{tn_portals}) if $scfg->{tn_portals};

    return 0 if !@portals; # No portals configured

    # Get active sessions once for efficiency
    my @session_lines = eval { _run_lines(['iscsiadm', '-m', 'session']) };
    return 0 if $@; # If command fails (no sessions exist), return false

    # Check each portal has an active session
    for my $portal (@portals) {
        return 0 if !_portal_connected($scfg, $portal, \@session_lines);
    }

    return 1; # All portals are connected
}

sub _iscsi_login_all($scfg) {
    # Skip login if all configured portals are already connected
    # This ensures multipath configurations establish sessions to ALL portals
    return if _all_portals_connected($scfg);

    my $primary = _normalize_portal($scfg->{tn_discovery_portal});
    my @extra   = $scfg->{tn_portals} ? map { _normalize_portal($_) } split(/\s*,\s*/, $scfg->{tn_portals}) : ();

    # Preflight reachability
    _probe_portal($primary);
    _probe_portal($_) for @extra;

    # Discovery (don't die on non-zero)
    _try_run(['iscsiadm','-m','discovery','-t','sendtargets','-p',$primary], "iSCSI discovery failed (primary)");
    for my $p (@extra) {
        _try_run(['iscsiadm','-m','discovery','-t','sendtargets','-p',$p], "iSCSI discovery failed ($p)");
    }

    my $iqn = $scfg->{tn_target_iqn};
    my @nodes = _run_lines(['iscsiadm','-m','node','-T',$iqn]);

    # Get current session list once for efficiency
    my @session_lines = eval { _run_lines(['iscsiadm', '-m', 'session']) };

    # Login to all discovered portals for this IQN; ensure node.startup=automatic
    for my $n (@nodes) {
        next unless $n =~ /^(\S+)\s+$iqn$/;
        my $portal = _normalize_portal($1);
        _try_run(['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.startup','-v','automatic'],
                 "iscsiadm update failed (node.startup)");
        if ($scfg->{tn_chap_user} && $scfg->{tn_chap_password}) {
            for my $cmd (
                ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.authmethod','-v','CHAP'],
                ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.username','-v',$scfg->{tn_chap_user}],
                ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.password','-v',$scfg->{tn_chap_password}],
            ) { _try_run($cmd, "iscsiadm CHAP update failed"); }
        }
        # Skip login if this portal is already connected
        next if _portal_connected($scfg, $portal, \@session_lines);
        _try_run(['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'--login'],
                 "iscsiadm login failed ($portal)");
    }
    # attempt direct login for any configured portal not already in -m node.
    # $primary must get the same guaranteed fallback as @extra, otherwise it
    # silently ends up with no session if sendtargets discovery from it alone
    # doesn't produce a matching node record (issue #91).
    for my $p ($primary, @extra) {
        # Skip login if this portal is already connected
        next if _portal_connected($scfg, $p, \@session_lines);
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
    usleep(UDEV_SETTLE_TIMEOUT_US); # modest grace
}

sub _find_by_path_for_lun($scfg, $lun) {
    my $iqn = $scfg->{tn_target_iqn};
    my $pattern = "-iscsi-$iqn-lun-$lun";
    opendir(my $dh, "/dev/disk/by-path") or die "cannot open /dev/disk/by-path\n";
    my @paths = grep { $_ =~ /^ip-.*\Q$pattern\E$/ } readdir($dh);
    closedir($dh);
    if (@paths) {
        # Untaint the path by validating it matches expected format
        if ($paths[0] =~ m{^(ip-[\w.:,\[\]\-]+iscsi-[\w.:,\[\]\-]+lun-\d+)$}) {
            return "/dev/disk/by-path/$1";
        }
    }
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
        # Untaint the device mapper name
        if ($name && $name =~ m{^([\w\-]+)$}) {
            return "/dev/mapper/$1";
        }
        # Untaint dm-N device
        if ($e =~ m{^(dm-\d+)$}) {
            return "/dev/$1";
        }
    }
    closedir($dh);
    return undef;
}

sub _iscsi_repair_empty_node_records {
    my ($iqn) = @_;
    return unless defined $iqn && length $iqn;
    my $base = "/var/lib/iscsi/nodes/$iqn";
    return unless -d $base;
    # Structure: $base/<portal>,<port>,<tpgt>/default
    my @removed;
    if (opendir(my $dh, $base)) {
        while (defined(my $portal = readdir($dh))) {
            next if $portal =~ /^\.\.?$/;
            my $rec = "$base/$portal/default";
            next unless -f $rec;
            my $sz = -s $rec;
            if (defined $sz && $sz == 0) {
                if (unlink $rec) {
                    push @removed, $rec;
                    # Best-effort: drop parent dir if now empty. Next -o new
                    # recreates it.
                    rmdir "$base/$portal";
                }
            }
        }
        closedir $dh;
    }
    if (@removed) {
        syslog('warning',
            "[TrueNAS] iscsi_repair: removed " . scalar(@removed) .
            " empty node-record file(s) under $base (corruption from prior " .
            "iscsiadm -o delete race). Fresh records will be created on -o new.");
    }
    return scalar(@removed);
}

sub _logout_target_all_portals {
    my ($scfg) = @_;
    my $iqn = $scfg->{tn_target_iqn};
    my @portals = ();
    push @portals, _normalize_portal($scfg->{tn_discovery_portal}) if $scfg->{tn_discovery_portal};
    push @portals, map { _normalize_portal($_) } split(/\s*,\s*/, ($scfg->{tn_portals}//''));
    for my $p (@portals) {
        eval { PVE::Tools::run_command(['iscsiadm','-m','node','-p',$p,'--targetname',$iqn,'--logout'], errfunc=>sub{} ) };
        # Do NOT `-o delete` the node record here. The record persists across
        # session logout and is needed for the next login (via -o new + login
        # in _login_target_all_portals, or via activate_volume). Concurrent
        # free_image calls racing this delete with a later --op new leaves
        # empty node-record files at /var/lib/iscsi/nodes/<iqn>/<portal>/default
        # -- observed on 2026-08-14 during test_run6 3-node cluster runs
        # where every subsequent iscsiadm login failed "No records found".
    }
}
sub _login_target_all_portals {
    my ($scfg) = @_;
    my $iqn = $scfg->{tn_target_iqn};
    my @portals = ();
    push @portals, _normalize_portal($scfg->{tn_discovery_portal}) if $scfg->{tn_discovery_portal};
    push @portals, map { _normalize_portal($_) } split(/\s*,\s*/, ($scfg->{tn_portals}//''));

    # Repair corrupted node-record state before touching iscsiadm. An empty
    # /var/lib/iscsi/nodes/<iqn>/<portal>,3260,<tpgt>/default is what the
    # pre-alpha4 `-o delete` race leaves behind (see _logout_target_all_portals
    # comment). `iscsiadm -o new` treats an empty file as an existing record
    # and refuses to overwrite it, so every subsequent --login returns
    # "iscsiadm: No records found" and the plugin busy-loops in the caller's
    # retry harness for minutes. Unlink zero-byte record files first; -o new
    # then creates a fresh, populated one below.
    _iscsi_repair_empty_node_records($iqn);

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
    if ($scfg->{tn_use_multipath}) {
        eval { PVE::Tools::run_command(['multipath','-r'], outfunc=>sub{}) };
        eval { PVE::Tools::run_command(['udevadm','settle'], outfunc=>sub{}) };
    }
}

sub _iscsi_rescan_sd_capacity($scfg) {
    # `iscsiadm -m session -R` discovers new LUNs but does NOT refresh the
    # capacity of existing sdX devices. When a LUN number is recycled
    # (extent at lunid N deleted, new extent created at the same lunid),
    # the kernel keeps the same sdX and reports the OLD capacity until
    # something pokes /sys/block/sdX/device/rescan. qemu-img convert then
    # sees a destination "smaller than input file" and aborts.
    #
    # Walk every iSCSI session for our configured target IQN and write 1
    # to each backing sdX's rescan attribute. Each write is cheap (a
    # single SCSI READ CAPACITY) and idempotent. Errors are logged and
    # ignored — the only callers are deferred best-effort paths.
    my $iqn = $scfg->{tn_target_iqn} // '';
    return unless length $iqn;

    # Each session looks like /sys/class/iscsi_session/session*/
    # We need to traverse session -> device -> target* -> LUN -> block/sdX
    my @sessions = glob '/sys/class/iscsi_session/session*';
    my $rescanned = 0;
    for my $sdir (@sessions) {
        # Filter by IQN: targetname file lists the target IQN
        my $tgt = '';
        if (open(my $fh, '<', "$sdir/targetname")) {
            $tgt = <$fh>;
            close $fh;
            chomp $tgt if defined $tgt;
        }
        next if !defined $tgt || $tgt ne $iqn;

        # Find block devices under this session
        for my $blk (glob "$sdir/device/target*/*/block/sd*") {
            next unless $blk =~ m{/block/(sd[a-z]+)$};
            my $sd = $1;
            my $rescan = "/sys/block/$sd/device/rescan";
            if (open(my $rfh, '>', $rescan)) {
                print $rfh "1\n";
                close $rfh;
                $rescanned++;
            }
        }
    }
    _log($scfg, 2, 'debug', "[TrueNAS] _iscsi_rescan_sd_capacity: rescanned $rescanned sd device(s) for $iqn");
    return $rescanned;
}

# alpha19: verify the sd device backing a specific LUN reports size > 0 after
# rescan. Under 3-node concurrent load with recycled LUNs, the kernel keeps
# the same sdX bound to a LUN number even after TN unmaps + remaps the LUN
# to a new zvol; without a fresh READ CAPACITY the sd stays at size=0 and
# any write fails with EIO. First try rescan on the same sd (cheap). If it
# stays at 0, delete the stale sd and force a session-level --rescan so
# the kernel re-attaches a fresh sd to the current LUN mapping. Die loud
# if we still cannot get a live device — better than letting the caller
# proceed against a zero-length block device.
sub _iscsi_ensure_lun_ready {
    my ($scfg, $lun, $device_path) = @_;
    return unless defined $device_path && -e $device_path;

    my $resolve_sd = sub {
        my $target = readlink($device_path);
        return unless $target;
        return $1 if $target =~ m{/(sd[a-z]+)$};
        return;
    };

    my $sd = $resolve_sd->();
    return unless $sd;  # not an sd device (multipath, direct block, etc.) — caller handles

    my $read_size = sub {
        my $s = shift;
        my $size_file = "/sys/block/$s/size";
        my $sz = 0;
        if (open my $fh, '<', $size_file) {
            my $line = <$fh>;
            close $fh;
            $sz = $line + 0 if defined $line;
        }
        return $sz;
    };

    my $rescan_sd = sub {
        my $s = shift;
        my $rescan_file = "/sys/block/$s/device/rescan";
        if (open my $rfh, '>', $rescan_file) {
            print $rfh "1\n";
            close $rfh;
            return 1;
        }
        return 0;
    };

    # Phase 1: retry rescan on the current sd up to 10 times (~3 s).
    for my $attempt (1..10) {
        my $size = $read_size->($sd);
        if ($size > 0) {
            _log($scfg, 2, 'debug', "[TrueNAS] _iscsi_ensure_lun_ready: LUN $lun sd=$sd ready size=$size (attempt=$attempt)")
                if $attempt > 1;
            return 1;
        }
        $rescan_sd->($sd);
        usleep(300_000);
    }

    # Phase 2: sd is genuinely dead. Delete it, force session rescan,
    # re-resolve the by-path (kernel may attach a new sdY).
    _log($scfg, 1, 'warning', "[TrueNAS] _iscsi_ensure_lun_ready: LUN $lun sd=$sd stuck at size=0 after 10 rescans, purging stale device");
    if (open my $dfh, '>', "/sys/block/$sd/device/delete") {
        print $dfh "1\n";
        close $dfh;
    }
    usleep(500_000);
    _try_run(['iscsiadm','-m','session','--rescan'], "iscsi session rescan after stale-sd purge (LUN $lun)");
    eval { run_command(['udevadm','settle'], outfunc => sub {}) };
    usleep(300_000);

    if (!-e $device_path) {
        die "[TrueNAS] LUN $lun: by-path $device_path vanished after stale-sd purge\n";
    }
    my $new_sd = $resolve_sd->();
    if (!$new_sd) {
        die "[TrueNAS] LUN $lun: by-path $device_path not backed by sd after stale-sd purge\n";
    }
    my $new_size = $read_size->($new_sd);
    if ($new_size > 0) {
        _log($scfg, 1, 'info', "[TrueNAS] _iscsi_ensure_lun_ready: LUN $lun recovered on new sd=$new_sd size=$new_size (was sd=$sd size=0)");
        return 1;
    }
    die "[TrueNAS] LUN $lun: sd=$new_sd still size=0 after stale-sd purge — device unusable\n";
}

sub _device_for_lun($scfg, $lun, $max_retries_override = undef) {
    # Wait briefly for by-path to appear if needed. Callers that want a
    # single non-blocking check (e.g. alloc_image's deferred discovery,
    # which runs its own outer retry loop) pass max_retries_override = 1
    # so we do NOT stack 60 s of internal polling inside their 250-ms
    # outer step. Without this, an 8-attempt outer loop x 60 s inner
    # timeout = 480 s worst case, blowing past the pveproxy 60 s window
    # and cascading into cross-cluster VM-config lock timeouts
    # (cluster_test_run 2026-08-17 3-node vm_additional_disk_vtpm).
    my $by;
    my $max_retries = $max_retries_override // $scfg->{tn_device_ready_retries} // 600;
    for (my $i = 1; $i <= $max_retries; $i++) {
        $by = _find_by_path_for_lun($scfg, $lun);
        last if $by && -e $by;
        run_command(['udevadm','settle'], outfunc => sub {});
        if ($i == 10 || $i == 20 || $i == 35 || $i == 60 || $i == 100 || $i == 150) {
            _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan");
            run_command(['udevadm','settle'], outfunc => sub {});
        }
        usleep(DEVICE_READY_TIMEOUT_US);
    }
    if (!$by || !-e $by) {
        my $iqn = $scfg->{tn_target_iqn} // '';
        my @sessions = _run_lines(['iscsiadm','-m','session']);
        my $session_text = @sessions ? join('; ', @sessions) : 'none';

        my @paths;
        eval {
            opendir(my $dh, "/dev/disk/by-path") or die "open by-path failed";
            if ($iqn) {
                @paths = grep { /iscsi-\Q$iqn\E/ } readdir($dh);
            } else {
                @paths = grep { /iscsi-/ } readdir($dh);
            }
            closedir($dh);
        };
        my $paths_text = @paths ? join(', ', @paths) : 'none';

        die "Could not locate by-path device for LUN $lun (IQN $iqn, retries $max_retries). Sessions: $session_text. by-path: $paths_text\n";
    }

    # Multipath preference
    if ($scfg->{tn_use_multipath} && !$scfg->{tn_use_by_path}) {
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

# ======== NVMe/TCP Helper Functions ========

# Return the JSON boolean to use for a subsystem's `allow_any_host`
# attribute per the storage's tn_nvme_allow_any_host setting. Default
# is FALSE: the plugin no longer forces a subsystem to accept any
# host, because doing so silently defeats a host-NQN allow-list and
# actively breaks configfs when an allow-list is populated (issue
# #90). See _nvme_create_subsystem and the Issue #12 configfs-sync
# workaround sites for the callers.
#
# `attr_allow_any_host = 1` and a populated `allowed_hosts/` are
# mutually exclusive in the kernel; nvmet's config-writer aborts the
# whole render on the first symlink into `allowed_hosts/` when
# `allow_any_host = true`, so port-subsys, port and namespace
# symlinks never get written and the TCP listener never opens. When
# a user with an existing allow-list installs the plugin, that alone
# was enough to take the entire NVMe/TCP target offline silently.
sub _nvme_allow_any_host_flag($scfg) {
    # Default TRUE to match TN 26.0.0-BETA.2's create-time render
    # requirement (a fresh subsys with allow_any_host=false AND empty
    # allowed_hosts is not rendered to configfs at all). Users on TN
    # 25.10.x whose allowed_hosts is populated should set
    # tn_nvme_allow_any_host=0 in storage.cfg to fix the opposite
    # bug in that version (attr_allow_any_host=1 + populated
    # allow-list aborts render). See the property description above
    # for the full trade-off; issue #90.
    return ($scfg->{tn_nvme_allow_any_host} // 1) ? JSON::PP::true : JSON::PP::false;
}

# Get or read host NQN from /etc/nvme/hostnqn
sub _nvme_get_hostnqn {
    my ($scfg) = @_;

    # If explicitly configured, use that
    return $scfg->{tn_hostnqn} if $scfg->{tn_hostnqn};

    # Otherwise read from /etc/nvme/hostnqn
    my $hostnqn_file = '/etc/nvme/hostnqn';
    if (-f $hostnqn_file) {
        if (open my $fh, '<', $hostnqn_file) {
            my $nqn = <$fh>;
            close $fh;
            chomp $nqn if $nqn;
            return $nqn if $nqn;
        }
    }

    die "Could not determine host NQN: /etc/nvme/hostnqn not found and hostnqn not configured\n";
}

# Check if nvme-cli is installed
sub _nvme_check_cli {
    eval {
        run_command(['nvme', 'version'], outfunc => sub {}, errfunc => sub {});
    };
    if ($@) {
        die "nvme-cli is not installed. Please install it: apt-get install nvme-cli\n";
    }
}

# Parse portal string into (host, port)
sub _nvme_parse_portal {
    my ($portal) = @_;

    # Handle IPv6: [addr]:port or addr:port
    if ($portal =~ /^\[([^\]]+)\]:(\d+)$/) {
        return ($1, $2);
    } elsif ($portal =~ /^([^:]+):(\d+)$/) {
        return ($1, $2);
    } elsif ($portal =~ /^\[([^\]]+)\]$/) {
        return ($1, 4420);  # Default NVMe/TCP port
    } else {
        return ($portal, 4420);
    }
}

sub _nvme_untaint_cli_host {
    my ($value) = @_;

    die "Invalid NVMe portal host: missing value\n"
        if !defined($value) || $value eq '';

    if ($value =~ /^((?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))$/) {
        return $1;
    }

    if ($value =~ /^([0-9A-Fa-f:.]+)$/) {
        my $ipv6 = $1;
        return $ipv6 if $ipv6 =~ /:/;
    }

    if ($value =~ /^((?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*)$/) {
        return $1;
    }

    die "Invalid NVMe portal host '$value'\n";
}

sub _nvme_untaint_cli_port {
    my ($value) = @_;

    die "Invalid NVMe portal port: missing value\n"
        if !defined($value) || $value eq '';

    if ($value =~ /^([1-9]\d{0,4})$/) {
        my $port = $1;
        return $port if $port <= 65535;
    }

    die "Invalid NVMe portal port '$value'\n";
}

# Untaint a signed integer destined for the nvme(1) command line. $min bounds the
# value: ctrl-loss-tmo accepts -1 (retry forever), the other options do not.
sub _nvme_untaint_cli_int {
    my ($value, $label, $min) = @_;
    $label //= 'NVMe integer option';
    $min   //= 0;

    die "Invalid $label: missing value\n"
        if !defined($value) || $value eq '';

    if ($value =~ /^(-?\d{1,7})$/) {
        my $n = $1;
        return $n if $n >= $min;
    }

    die "Invalid $label '$value' (minimum $min)\n";
}

sub _nvme_untaint_cli_nqn {
    my ($value, $label, $require_identifier) = @_;
    $label //= 'NVMe NQN';
    $require_identifier //= 1; # subsystem NQNs require it per NVMe-oF spec; host NQNs don't (#44)

    die "Invalid $label: missing value\n"
        if !defined($value) || $value eq '';

    my $identifier = $require_identifier
        ? qr/:[A-Za-z0-9][A-Za-z0-9._:-]*/
        : qr/(?::[A-Za-z0-9][A-Za-z0-9._:-]*)?/;

    if ($value =~ /^(nqn\.\d{4}-\d{2}\.[A-Za-z0-9.-]+(?:$identifier))$/) {
        return $1;
    }

    die "Invalid $label '$value'\n";
}

sub _nvme_untaint_cli_secret {
    my ($value, $label) = @_;
    return undef if !defined($value) || $value eq '';

    $label //= 'NVMe DH-HMAC secret';

    if ($value =~ /^([A-Za-z0-9+\/=:_-]+)$/) {
        return $1;
    }

    die "Invalid $label\n";
}

# Check if connected to a subsystem (any live path at all).
# Thin view over _nvme_controller_portals(), so controller state is read from
# sysfs in exactly one place in this file.
sub _nvme_is_connected {
    my ($scfg) = @_;
    my $ctrl = _nvme_controller_portals($scfg);
    return (grep { $_ eq 'live' } values %$ctrl) ? 1 : 0;
}

# Count CPUs listed in a sysfs range file (e.g. /sys/devices/system/cpu/online).
# The file contains comma-separated ranges like "0-3,5,7-9".
# Returns the total CPU count, or undef on read failure.
sub _read_cpu_count {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    chomp $line;
    my $count = 0;
    for my $part (split /,/, $line) {
        if ($part =~ /^(\d+)-(\d+)$/) {
            $count += $2 - $1 + 1;
        } elsif ($part =~ /^(\d+)$/) {
            $count += 1;
        }
    }
    return $count || undef;
}

# ======== NVMe/TCP portal reconciliation ========
#
# Reconciling per portal means we can end up talking to a portal that is down.
# Two things make that expensive, and both have to be defused before any hot
# call site is allowed to reconcile:
#
#   * talking to a portal that is black-holing packets costs a real round trip.
#     Measured on 6.8 with nvme-cli 2.8, the write to /dev/nvme-fabrics gives up
#     on its own after roughly three seconds with ETIMEDOUT - nvme-tcp applies
#     its own connect timeout well before the TCP SYN retry window would expire.
#     Three seconds is cheap next to a stalled connect, but it is not free, and
#     a VM start is the wrong place to spend it.
#   * a controller that exists but is not 'live' is already being retried by the
#     kernel. Issuing a second connect for it achieves nothing.
#
# Per-portal backoff: "<host key>|<portal>" => epoch of the last failed attempt.
# In-process only, deliberately. pvestatd is long-lived and is what drives the
# repeated repair attempts, so that is where suppression actually matters. PVE
# task workers are forked per operation and start from an inherited copy, which
# is harmless here: these are plain timestamps, unlike %_ws_connections which
# holds file descriptors and therefore needs its PID guard. The worst a fresh
# worker can pay is one bounded connect attempt per dead portal.
my %_nvme_portal_backoff;
my %_nvme_degraded_last_log;
my %_nvme_host_addr_cache;

use constant {
    NVME_PORTAL_BACKOFF_S     => 60,   # do not retry a dead portal faster than this
    NVME_CONNECT_TMO_S        => 15,   # hard cap on `nvme connect`. Measured:
                                       # a black-holed portal fails on its own
                                       # in ~3s (ETIMEDOUT from the fabrics
                                       # write), so this only ever fires if the
                                       # TCP handshake succeeds and the NVMe one
                                       # then hangs.
    NVME_DEGRADED_LOG_S       => 300,  # throttle for the "reduced redundancy" warning
    NVME_HOST_ADDR_TTL_S      => 300,  # memoize portal hostname lookups
    NVME_HOST_ADDR_FAIL_TTL_S => 10,   # ...but do not cache a failure that long
};

# Canonical form of a transport address, for use as a hash key only.
# IPv6 gets pton/ntop'd because the kernel's textual form need not match the one
# in storage.cfg (2001:db8:0:0:0:0:0:1 vs 2001:db8::1).
sub _nvme_normalize_addr {
    my ($addr) = @_;
    return undef if !defined($addr) || $addr eq '';
    $addr =~ s/^\[//;
    $addr =~ s/\]$//;
    $addr =~ s/%.*$//;                       # drop IPv6 zone index
    # Order matters: the /:/ test must come first, a second successful match
    # would clobber $1.
    if (index($addr, ':') >= 0 && $addr =~ /^([0-9A-Fa-f:]+)$/) {
        my $packed = eval { Socket::inet_pton(Socket::AF_INET6(), $1) };
        if ($packed) {
            my $canon = eval { Socket::inet_ntop(Socket::AF_INET6(), $packed) };
            return lc($canon) if defined $canon;
        }
    }
    # IPv4 needs canonicalising too: the kernel only ever writes the canonical
    # dotted quad, so a config entry like 192.000.002.010 would otherwise key
    # differently from the identical address in sysfs, leaving a phantom portal
    # reconnected on every poll.
    #
    # Done by hand rather than through inet_aton/inet_pton. inet_pton rejects
    # leading zeros outright; inet_aton is strict on some platforms (undef, so
    # the address falls through unnormalised) and lenient-but-octal on others,
    # where 010 becomes 8 - a different host entirely. Decimal, octet by octet,
    # is the only reading that matches what an operator writing 010 meant.
    if (my @octets = $addr =~ /^0*(\d{1,3})\.0*(\d{1,3})\.0*(\d{1,3})\.0*(\d{1,3})$/) {
        return join('.', map { 0 + $_ } @octets)
            if !grep { $_ > 255 } @octets;
    }
    return lc($addr);
}

sub _nvme_portal_key {
    my ($addr, $port) = @_;
    my $norm = _nvme_normalize_addr($addr);
    return undef if !defined $norm;
    return $norm . ':' . (0 + ($port // 4420));
}

# Every key a configured portal may legitimately appear under in sysfs. The
# kernel only ever stores a numeric traddr - nvme-cli resolves
# a hostname (libnvme hostname2traddr()) before writing to /dev/nvme-fabrics -
# so a portal configured by name never matches its own config string and the
# reconciler reconnects it forever. Resolve here and accept any address the
# resolver returns, which is as close as we can get to what nvme-cli picked.
#
# Resolution feeds MATCHING ONLY. The connect command keeps the configured host
# string, so nothing here reaches exec() and _nvme_untaint_cli_host() remains the
# sole guard on the command line.
sub _nvme_portal_keys {
    my ($host, $port, $may_resolve) = @_;

    my @keys;
    my $raw = _nvme_portal_key($host, $port);
    push @keys, $raw if defined $raw;

    # Literals need no lookup, and must not pay for a failing one.
    return \@keys if _nvme_addr_is_literal($host);

    my $now = time();
    my $entry = $_nvme_host_addr_cache{lc $host};
    # A clock step backwards would otherwise freeze the entry until the wall
    # clock caught up again.
    $entry = undef if $entry && $now < $entry->{t};
    my $ttl = ($entry && $entry->{failed})
        ? NVME_HOST_ADDR_FAIL_TTL_S : NVME_HOST_ADDR_TTL_S;

    # $may_resolve is false on the hot path. getaddrinfo is synchronous, and a
    # wedged resolver costs whatever resolv.conf says - typically five seconds
    # per nameserver, which is worse than the connect this code refuses to make
    # here. DNS failure is also correlated with the outage being diagnosed. So
    # the hot path answers from the memo or not at all.
    return \@keys if !$may_resolve && (!$entry || ($now - $entry->{t}) >= $ttl);

    if (!$entry || ($now - $entry->{t}) >= $ttl) {
        my @addrs;
        my ($err, @res) = Socket::getaddrinfo($host, undef,
            { socktype => Socket::SOCK_STREAM() });
        if (!$err) {
            for my $ai (@res) {
                my ($gerr, $a) = Socket::getnameinfo($ai->{addr},
                    Socket::NI_NUMERICHOST(), Socket::NIx_NOSERV());
                next if $gerr || !defined($a);
                push @addrs, $1 if $a =~ /^([0-9A-Fa-f:.%]+)$/;
            }
        }
        # A failed lookup is cached too, or a wedged resolver would be re-queried
        # on every call - but for far less time than a successful one. Caching a
        # transient failure for the full TTL would keep a perfectly live portal
        # unmatchable for five minutes.
        #
        # The last good answer is kept across a failure, because the hot path no
        # longer resolves and would otherwise go blind on a blip. It is not kept
        # forever: once lookups have been failing for a full TTL the address is
        # treated as stale and dropped, so a portal that changed address while
        # the resolver was down stops being matched against an address it no
        # longer has.
        my $failing_since = @addrs ? undef
            : ($entry && $entry->{failing_since} ? $entry->{failing_since} : $now);
        my $keep_stale = defined($failing_since)
            && ($now - $failing_since) < NVME_HOST_ADDR_TTL_S;
        $entry = $_nvme_host_addr_cache{lc $host} =
            { t => $now,
              addrs => (@addrs ? \@addrs
                               : ($keep_stale && $entry ? $entry->{addrs} : [])),
              failing_since => $failing_since,
              failed => (@addrs ? 0 : 1) };
    }

    for my $a (@{$entry->{addrs}}) {
        my $k = _nvme_portal_key($a, $port);
        push @keys, $k if defined $k;
    }

    return \@keys;
}

# Root of the NVMe controller class in sysfs. Overridable so the offline tests
# can point at a fixture tree.
our $NVME_SYSFS_CLASS = '/sys/class/nvme';

# All TCP controllers of our subsystem, keyed "addr:port" => state string.
#
# Read straight from sysfs rather than parsed out of `nvme list-subsys`. That
# buys two things: the subsystem is matched with eq against each controller's
# own subsysnqn attribute, so "...:pve" can never claim the controllers of
# "...:pve-backup"; and nothing is forked, which matters because this runs on
# pvestatd's timer. _nvme_find_controllers_for_subsystem() already reads the
# same tree, so this is the file's established pattern.
#
# Callers need three answers, not two: a portal with a live controller is done;
# a portal whose controller is in any other state is already being retried by
# the kernel and must NOT get a second connect (this is what makes the
# recommended tn_nvme_ctrl_loss_tmo=-1 safe - by design it parks controllers in
# 'connecting' indefinitely); only a portal with no controller at all needs one.
sub _nvme_controller_portals {
    my ($scfg) = @_;
    my $nqn = $scfg->{tn_subsystem_nqn};

    my %ctrl;
    return \%ctrl if !defined($nqn) || $nqn eq '';

    my $slurp = sub {
        my ($path) = @_;
        open(my $fh, '<', $path) or return undef;
        my $val = <$fh>;
        close($fh);
        return undef if !defined $val;
        chomp $val;
        return $val;
    };

    opendir(my $dh, $NVME_SYSFS_CLASS) or return \%ctrl;
    my @entries = grep { /^nvme\d+$/ } readdir($dh);
    closedir($dh);

    for my $entry (@entries) {
        next unless $entry =~ /^(nvme\d+)$/;
        my $ctrl_name = $1;  # untaint
        my $base = "$NVME_SYSFS_CLASS/$ctrl_name";

        # eq, not a regex: this is the whole point of reading sysfs.
        my $ctrl_nqn = $slurp->("$base/subsysnqn");
        next if !defined($ctrl_nqn) || $ctrl_nqn ne $nqn;
        next if ($slurp->("$base/transport") // '') ne 'tcp';

        # The address attribute observed on 6.8 is
        # "traddr=<ip>,trsvcid=<port>,src_addr=<ip>", where src_addr cannot be
        # confused with traddr. \b is defensive: host_traddr= appears when a
        # controller was created with --host-traddr, and would otherwise match
        # here as the target address.
        my $address = $slurp->("$base/address") // '';
        my ($addr) = $address =~ /\btraddr=([^,\s]+)/;
        next if !defined $addr;
        my ($port) = $address =~ /\btrsvcid=(\d+)/;

        my $key = _nvme_portal_key($addr, $port);
        next if !defined $key;

        # Any state other than live still means a controller exists, so no
        # duplicate connect. Portals with no controller at all are absent from
        # this map entirely - that is the case the original bug is about.
        my $state = $slurp->("$base/state") // 'unknown';
        $ctrl{$key} = $state unless ($ctrl{$key} // '') eq 'live';
    }

    return \%ctrl;
}

# One definition of "this is an address, not a name", used by everything that
# has to decide whether a lookup is even meaningful. Two slightly different
# predicates used to disagree on malformed input such as "192.168.1".
sub _nvme_addr_is_literal {
    my ($host) = @_;
    return 0 if !defined($host) || $host eq '';
    return 1 if index($host, ':') >= 0;                  # IPv6
    return 1 if $host =~ /^[0-9]+(?:\.[0-9]+){3}$/;       # dotted quad
    return 0;
}

# True when a portal is configured by name and that name cannot currently be
# turned into an address. Distinguishes "this portal has no controller" from
# "we cannot tell whether it has one".
sub _nvme_portal_unresolved {
    my ($host, $may_resolve) = @_;
    return 0 if !defined($host) || $host eq '';
    return 0 if _nvme_addr_is_literal($host);
    my $keys = _nvme_portal_keys($host, 4420, $may_resolve);
    return scalar(@$keys) <= 1 ? 1 : 0;   # only the raw name, no resolved address
}

# State of the controller serving a configured portal, or undef when that portal
# has no controller at all.
sub _nvme_portal_state {
    my ($ctrl, $host, $port, $may_resolve) = @_;
    for my $key (@{_nvme_portal_keys($host, $port, $may_resolve)}) {
        return $ctrl->{$key} if exists $ctrl->{$key};
    }
    return undef;
}

# Configured portals, de-duplicated and with empty entries dropped (a trailing
# or doubled comma in tn_portals otherwise reaches _nvme_untaint_cli_host and
# kills the whole connect).
sub _nvme_configured_portals {
    my ($scfg) = @_;
    my @raw;
    push @raw, $scfg->{tn_discovery_portal} if $scfg->{tn_discovery_portal};
    push @raw, split(/\s*,\s*/, $scfg->{tn_portals}) if $scfg->{tn_portals};

    # Deduplicate on the normalised key rather than the raw string: "10.0.0.1"
    # and "10.0.0.1:4420" are one portal, and keeping both would connect to it
    # twice and keep two backoff entries for it.
    my (@portals, %seen);
    for my $p (@raw) {
        next if !defined($p);
        $p =~ s/^\s+|\s+$//g;
        next if $p eq '';
        my ($dedup_host, $dedup_port) = _nvme_parse_portal($p);
        my $key = _nvme_portal_key($dedup_host, $dedup_port) // lc($p);
        next if $seen{$key}++;
        push @portals, $p;
    }
    return @portals;
}

# Connect to NVMe/TCP subsystem.
#
# Two modes, because the eleven call sites are not equally hot:
#
#   default (path(), activate_volume(), the recovery paths): make sure the
#       subsystem is usable. If any configured portal has a live controller we
#       are done - one sysfs scan and out. A missing portal is
#       reported, not repaired: re-adding it means an `nvme connect` to a fabric
#       that may be black-holing packets, and a VM start is the wrong place to
#       find that out.
#
#   repair => 1 (status(), i.e. every pvestatd storage poll): actually
#       reconcile portal by portal. Failure there is already non-fatal and
#       logged, and the poll recurs, so a portal that comes back is picked up
#       within one poll interval instead of never - which was the bug this whole
#       change exists to fix.
sub _nvme_connect {
    my ($scfg, %opts) = @_;
    my $repair = $opts{repair} ? 1 : 0;

    _log($scfg, 2, 'debug', "[TrueNAS] nvme_connect: checking subsystem $scfg->{tn_subsystem_nqn}"
        . ($repair ? ' (reconcile)' : ''));

    my $nqn = _nvme_untaint_cli_nqn($scfg->{tn_subsystem_nqn}, 'NVMe subsystem NQN');
    my @portals = _nvme_configured_portals($scfg);

    die "No portals configured for NVMe/TCP storage\n" unless @portals;

    # Pure sysfs read: no process is forked on the healthy path.
    my $ctrl = _nvme_controller_portals($scfg);

    # Only resolve names when reconciling. On the hot path a lookup is answered
    # from the memo or not at all - see _nvme_portal_keys.
    my $may_resolve = $repair;

    my (@missing, @recovering, @unknown);
    my $live = 0;
    for my $portal (@portals) {
        my ($h, $p) = _nvme_parse_portal($portal);
        my $state = _nvme_portal_state($ctrl, $h, $p, $may_resolve);
        if (defined $state) {
            $state eq 'live' ? $live++ : push @recovering, "$portal ($state)";
            next;
        }
        # No controller matched. For a portal configured by name whose lookup we
        # could not make, that is not evidence of absence: it cannot be compared
        # against the numeric traddr sysfs reports at all. Kept separate from
        # @recovering, which means "a controller exists and the kernel is
        # retrying it" - conflating the two turns a total outage into a silent
        # success, since neither would ever be connected.
        if (_nvme_portal_unresolved($h, $may_resolve)) {
            push @unknown, $portal;
            next;
        }
        push @missing, $portal;
    }


    # A name that could not be resolved is only ambiguous while a controller
    # exists that it might be. With none at all for this NQN there is nothing
    # it could match, and upstream always handed the configured string to
    # `nvme connect -a` and let nvme-cli resolve it. Keep doing that: without
    # it a cold start, or the disconnect->connect recovery in a fresh worker
    # (whose memo is empty), would die without ever issuing a connect for a
    # storage whose portals are configured by name.
    if (!$live && !%$ctrl && @unknown) {
        push @missing, @unknown;
        @unknown = ();
    }
    # Healthy: every configured portal has a live controller.
    if (!@missing && !@recovering && !@unknown) {
        _log($scfg, 2, 'debug', "[TrueNAS] nvme_connect: all $live configured portal(s) live");
        return;
    }

    # Keyed by subsystem, not by API host: several storages can share one NAS,
    # and one subsystem's failures must not suppress another's repair.
    my $hostkey = $nqn;
    my $now = time();

    # Degraded but usable, and we are not the reconciler. Say so - throttled,
    # because path() runs once per disk per VM start - and get out of the way.
    if (!$repair && $live) {
        # Keyed per mode: storage_info() calls activate_storage and then status
        # in one process, so a shared key let the hot path's warning demote the
        # reconciler's to debug for the whole window.
        my $logkey = "$hostkey|hot";
        my $last_log = $_nvme_degraded_last_log{$logkey} // 0;
        # A clock step backwards would otherwise suppress the warning for the
        # whole difference.
        $last_log = 0 if $now < $last_log;
        # "live" counts controllers the kernel holds, which is not the same as
        # paths usable for I/O: a controller reports live while its ANA group is
        # inaccessible. Path selection is the kernel's job, so that does not change
        # what needs reconnecting - but this count is controllers, not
        # ANA-accessible paths.
        # Level 0: tn_debug defaults to 0 and _log drops anything above it, so a
        # level 1 warning is invisible on a default install - which would make
        # the loss of redundancy this change exists to surface silent again. The
        # throttle keeps level 0 from being noisy, though note it is per process,
        # not wall-clock: outside pvestatd the effective rate is one warning per
        # operation, since each task worker starts with an empty window.
        #
        # Only warn about portals that could actually be accounted for. The hot
        # path does not resolve, so a portal configured by name always lands in
        # @unknown here - warning on that alone would cry wolf on every VM start
        # of a perfectly healthy storage.
        my $level = (($now - $last_log) >= NVME_DEGRADED_LOG_S
                     && (@missing || @recovering)) ? 0 : 2;
        $_nvme_degraded_last_log{$logkey} = $now if $level == 0;
        _log($scfg, $level, $level == 0 ? 'warning' : 'debug',
            "[TrueNAS] nvme_connect: $live of " . scalar(@portals) . " portal(s) live"
            . (@missing    ? '; missing: '    . join(', ', @missing)    : '')
            . (@recovering ? '; recovering: ' . join(', ', @recovering) : '')
            . (@unknown    ? '; unresolved: ' . join(', ', @unknown)    : '')
            . ' - reduced path redundancy, repair deferred to the status() poll');
        return;
    }

    # Only portals with no controller at all are candidates. A controller in
    # 'connecting'/'resetting' is the kernel already doing this job; a second
    # connect for it is simply refused ("already connected").
    my @connect_list;
    for my $portal (@missing) {
        my $last_fail = $_nvme_portal_backoff{"$hostkey|$portal"};
        # Backoff is bypassed only on the hot path with nothing live: that call
        # is the one deciding whether a VM gets its disk, and it must always try.
        # In repair mode it always applies. status() runs on pvestatd's timer,
        # so without this a target that is entirely down would have every poll
        # attempt every portal, each bounded by NVME_CONNECT_TMO_S, forever -
        # stalling the poll loop for every storage on the node, not just this one.
        # A clock step backwards would otherwise hold the portal off until the
        # wall clock caught up.
        if (defined($last_fail) && $now < $last_fail) {
            delete $_nvme_portal_backoff{"$hostkey|$portal"};
            $last_fail = undef;
        }
        # Bypassed only on the hot path, where this call decides whether a VM
        # gets its disk. In repair mode it always applies.
        if ($repair
            && defined($last_fail) && ($now - $last_fail) < NVME_PORTAL_BACKOFF_S) {
            _log($scfg, 2, 'debug', "[TrueNAS] nvme_connect: portal $portal in backoff ("
                . ($now - $last_fail) . 's of ' . NVME_PORTAL_BACKOFF_S . 's), skipping');
            next;
        }
        push @connect_list, $portal;
    }

    if (!@connect_list) {
        # %$ctrl is every controller the kernel holds for this NQN, whatever the
        # configured portals resolve to. Empty means there is genuinely nothing,
        # so callers that depend on this dying - most of them are not wrapped in
        # eval - must not be told everything is merely "recovering".
        die "Failed to connect to any NVMe/TCP portal for subsystem $nqn\n"
            if !$live && !%$ctrl;
        # No live path, but controllers exist and are mid-recovery. Another
        # connect would be refused with EALREADY; only the kernel (or a
        # disconnect) can move this forward, so make the state visible.
        _log($scfg, 1, 'warning', "[TrueNAS] nvme_connect: no live path yet, "
            . scalar(@recovering) . ' controller(s) recovering: '
            . join(', ', @recovering)) if !$live && @recovering;
        return;
    }

    _log($scfg, 1, 'info', "[TrueNAS] nvme_connect: $live portal(s) live, restoring "
        . scalar(@connect_list) . ' missing path(s)') if $live;

    my $hostnqn = _nvme_untaint_cli_nqn(_nvme_get_hostnqn($scfg), 'NVMe host NQN', 0);
    my $dhchap_secret = _nvme_untaint_cli_secret($scfg->{tn_nvme_dhchap_secret}, 'NVMe DH-HMAC secret');
    my $dhchap_ctrl_secret = _nvme_untaint_cli_secret($scfg->{tn_nvme_dhchap_ctrl_secret}, 'NVMe controller DH-HMAC secret');
    my $connected_count = 0;

    for my $portal (@connect_list) {
        my ($host, $port) = _nvme_parse_portal($portal);
        $host = _nvme_untaint_cli_host($host);
        # Numify first: _nvme_portal_key() already compares ports numerically, so
        # a config entry of "04420" matches its controller and never reaches a
        # connect - until a cold start, where the untainter's ^[1-9] would reject
        # it and die outside the per-portal eval, taking the other portals down.
        $port = _nvme_untaint_cli_port(0 + $port);

        _log($scfg, 2, 'debug', "[TrueNAS] nvme_connect: connecting to $host:$port");

        my @cmd = ('nvme', 'connect', '-t', 'tcp', '-n', $nqn, '-a', $host, '-s', $port);

        # Cap I/O queues to avoid kernel queue-to-CPU mapping failures when CPUs are
        # offlined (issue #48). The kernel maps queue N to CPU N by index; if a CPU in
        # the possible range is offline, connecting with more queues than
        # floor(possible/2) causes EXDEV (-18) because at least one queue has no online
        # CPU in its affinity set. floor(possible/2) guarantees each queue maps to at
        # least 2 possible CPUs, so one offline CPU never orphans a queue.
        # When all CPUs are online (online == possible) we pass nproc, matching the
        # kernel default. tn_nr_io_queues overrides both.
        my $nr_io_queues;
        if (defined $scfg->{tn_nr_io_queues}) {
            $nr_io_queues = $scfg->{tn_nr_io_queues};
        } else {
            my $nr_conf   = _read_cpu_count('/sys/devices/system/cpu/possible');
            my $nr_online = _read_cpu_count('/sys/devices/system/cpu/online');
            $nr_io_queues = ($nr_conf && $nr_online && $nr_online < $nr_conf)
                ? int($nr_conf / 2)
                : $nr_online;
        }
        push @cmd, '--nr-io-queues', $nr_io_queues if $nr_io_queues && $nr_io_queues > 0;

        # Add host NQN if not default
        push @cmd, '--hostnqn', $hostnqn if $hostnqn;

        # Add DH-HMAC-CHAP authentication if configured
        if (defined($dhchap_secret)) {
            push @cmd, '--dhchap-secret', $dhchap_secret;
        }
        if (defined($dhchap_ctrl_secret)) {
            push @cmd, '--dhchap-ctrl-secret', $dhchap_ctrl_secret;
        }

        # Reconnection behaviour. Without these the kernel defaults apply
        # (ctrl_loss_tmo 600s), after which a controller whose fabric stayed down
        # is removed outright and never returns on its own.
        push @cmd, '--ctrl-loss-tmo',
            _nvme_untaint_cli_int($scfg->{tn_nvme_ctrl_loss_tmo}, 'NVMe ctrl-loss timeout', -1)
            if defined $scfg->{tn_nvme_ctrl_loss_tmo};
        push @cmd, '--reconnect-delay',
            _nvme_untaint_cli_int($scfg->{tn_nvme_reconnect_delay}, 'NVMe reconnect delay', 1)
            if defined $scfg->{tn_nvme_reconnect_delay};
        push @cmd, '--keep-alive-tmo',
            _nvme_untaint_cli_int($scfg->{tn_nvme_keep_alive_tmo}, 'NVMe keep-alive timeout', 1)
            if defined $scfg->{tn_nvme_keep_alive_tmo};

        my $connect_stderr = '';
        eval {
            # Backstop for the case the fabrics write's own ~3s failure cannot
            # cover: the portal completes the TCP handshake and the NVMe one
            # then stalls. Without this, run_command waits forever.
            run_command(\@cmd,
                outfunc => sub { _log($scfg, 2, 'debug', "[TrueNAS] nvme connect: " . shift); },
                errfunc => sub { $connect_stderr .= shift; },
                timeout => NVME_CONNECT_TMO_S,
            );
            $connected_count++;
        };
        if ($@) {
            if ($connect_stderr =~ /already connected/i) {
                # Controller exists but may be reconnecting — treat as success
                _log($scfg, 1, 'info', "[TrueNAS] nvme_connect: portal $portal already connected (controller may be recovering)");
                $connected_count++;
            } else {
                my $detail = $connect_stderr ? " (stderr: $connect_stderr)" : '';
                _log($scfg, 1, 'warning', "[TrueNAS] nvme_connect: failed to connect to portal $portal: $@$detail");
                # time() again, not $now: with several dead portals the loop can
                # have been running for tens of seconds by here, which would
                # shorten the effective backoff window.
                $_nvme_portal_backoff{"$hostkey|$portal"} = time();
                delete $_portal_sync_last_ok{_cache_host_key($scfg)};
                next;
            }
        }
        delete $_nvme_portal_backoff{"$hostkey|$portal"};
    }

    die "Failed to connect to any NVMe/TCP portal for subsystem $nqn\n"
        if ($connected_count + $live) == 0 && !%$ctrl;

    # Only pay for udev when something actually attached. With a portal that
    # stays down, every repair attempt fails and the settle plus its 250ms grace
    # buy nothing at all - and `udevadm settle` is not cheap on a busy node.
    if ($connected_count) {
        run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {});
        usleep(UDEV_SETTLE_TIMEOUT_US);
    }

    # Recount from sysfs instead of trusting the attempts: `nvme connect` returns
    # as soon as the controller exists, which may be in 'connecting', and the
    # "already connected" branch counts one never inspected. Counted the same way
    # as $live above - per configured portal - because the denominator is the
    # configured portal count. A plain grep over every controller of the
    # subsystem would include one belonging to a portal since removed from
    # tn_portals, and report 2 of 2 with one path.
    my $total = $live;
    if ($connected_count) {
        my $after = _nvme_controller_portals($scfg);
        $total = 0;
        for my $portal (@portals) {
            my ($h, $p) = _nvme_parse_portal($portal);
            my $st = _nvme_portal_state($after, $h, $p, $may_resolve);
            $total++ if defined($st) && $st eq 'live';
        }
    }
    _log($scfg, 1, 'info', "[TrueNAS] nvme_connect: $total of " . scalar(@portals) .
        " configured portal(s) live (" . scalar(@connect_list) . " connect(s) attempted, "
        . "$connected_count succeeded)");
    # Only warn when every portal could actually be accounted for. On the hot
    # path names are not resolved, so a portal configured by name never counts
    # as live there - warning on that would cry wolf on every VM start.
    if ($total < scalar(@portals) && !@unknown) {
        my $warnkey = "$hostkey|" . ($repair ? 'repair' : 'hot');
        my $last_warn = $_nvme_degraded_last_log{$warnkey} // 0;
        $last_warn = 0 if $now < $last_warn;
        my $wlvl = (time() - $last_warn) >= NVME_DEGRADED_LOG_S ? 0 : 2;
        $_nvme_degraded_last_log{$warnkey} = time() if $wlvl == 0;
        _log($scfg, $wlvl, $wlvl == 0 ? 'warning' : 'debug',
            "[TrueNAS] nvme_connect: only $total of " . scalar(@portals) .
            " portal(s) live - running with reduced path redundancy");
    }
}

# Disconnect from NVMe/TCP subsystem
# Tries controller-specific disconnect first to avoid disrupting other storages
# sharing the same subsystem NQN. Falls back to NQN-wide disconnect if needed.
sub _nvme_disconnect {
    my ($scfg) = @_;
    my $nqn = _nvme_untaint_cli_nqn($scfg->{tn_subsystem_nqn}, 'NVMe subsystem NQN');

    _log($scfg, 1, 'info', "[TrueNAS] nvme_disconnect: disconnecting from subsystem $nqn");

    # Try controller-specific disconnect first
    my @controllers = _nvme_find_controllers_for_subsystem($scfg);
    if (@controllers) {
        my $all_ok = 1;
        for my $ctrl (@controllers) {
            _log($scfg, 1, 'info', "[TrueNAS] nvme_disconnect: disconnecting controller $ctrl");
            eval {
                run_command(['nvme', 'disconnect', '-d', $ctrl],
                    outfunc => sub { _log($scfg, 2, 'debug', "[TrueNAS] nvme disconnect $ctrl: " . shift); },
                    errfunc => sub {}
                );
            };
            if ($@) {
                _log($scfg, 1, 'warning', "[TrueNAS] nvme_disconnect: failed to disconnect $ctrl: $@");
                $all_ok = 0;
            }
        }
        return if $all_ok;
        _log($scfg, 1, 'warning', "[TrueNAS] nvme_disconnect: some controller disconnects failed, falling back to NQN-wide");
    }

    # Fallback: NQN-wide disconnect
    eval {
        run_command(['nvme', 'disconnect', '-n', $nqn],
            outfunc => sub { _log($scfg, 2, 'debug', "[TrueNAS] nvme disconnect: " . shift); },
            errfunc => sub {}
        );
    };
    if ($@) {
        _log($scfg, 1, 'warning', "[TrueNAS] nvme_disconnect: $@");
    }
}

# Rescan NVMe controllers belonging to our subsystem to discover new namespaces
sub _nvme_rescan_subsystem_controllers {
    my ($scfg) = @_;

    my $nqn = $scfg->{tn_subsystem_nqn};

    opendir(my $dh, "/sys/class/nvme-subsystem") or return;
    while (my $subsys = readdir($dh)) {
        next unless $subsys =~ /^(nvme-subsys\d+)$/;
        $subsys = $1;  # Untaint via capture
        my $subsys_nqn = eval {
            open my $fh, '<', "/sys/class/nvme-subsystem/$subsys/subsysnqn" or die;
            my $val = <$fh>;
            close $fh;
            chomp($val);
            $val;
        };
        next unless $subsys_nqn && $subsys_nqn eq $nqn;

        # Rescan all controllers in our subsystem
        opendir(my $sdh, "/sys/class/nvme-subsystem/$subsys") or next;
        while (my $entry = readdir($sdh)) {
            next unless $entry =~ /^(nvme(\d+))$/;
            my $ctrl_dev = "/dev/nvme$2";
            eval { run_command(['nvme', 'ns-rescan', $ctrl_dev], outfunc => sub {}, errfunc => sub {}) };
            _log($scfg, 2, 'debug', "[TrueNAS] nvme_rescan: rescanned $ctrl_dev");
        }
        closedir($sdh);
    }
    closedir($dh);
}

# Find NVMe controllers belonging to our subsystem that match our configured portals.
# Returns list of controller device paths (e.g., /dev/nvme0, /dev/nvme1).
sub _nvme_find_controllers_for_subsystem {
    my ($scfg) = @_;

    my $nqn = $scfg->{tn_subsystem_nqn};
    my @controllers;

    # Build set of portals to match against, using the same key machinery as
    # the reconciler. Comparing the raw configured host against the numeric
    # traddr the kernel stores meant a storage configured by hostname matched
    # nothing at all and this returned an empty list.
    my %portal_set;
    for my $portal_str (_nvme_configured_portals($scfg)) {
        my ($host, $port) = _nvme_parse_portal($portal_str);
        $portal_set{$_} = 1 for @{ _nvme_portal_keys($host, $port) };
    }

    opendir(my $dh, "/sys/class/nvme-subsystem") or return @controllers;
    while (my $subsys = readdir($dh)) {
        next unless $subsys =~ /^(nvme-subsys\d+)$/;
        $subsys = $1;  # Untaint
        my $subsys_nqn = eval {
            open my $fh, '<', "/sys/class/nvme-subsystem/$subsys/subsysnqn" or die;
            my $val = <$fh>;
            close $fh;
            chomp($val);
            $val;
        };
        next unless $subsys_nqn && $subsys_nqn eq $nqn;

        # Find controllers in this subsystem
        opendir(my $sdh, "/sys/class/nvme-subsystem/$subsys") or next;
        while (my $entry = readdir($sdh)) {
            next unless $entry =~ /^(nvme(\d+))$/;
            my $ctrl_name = $1;
            my $ctrl_num = $2;

            # Read controller address to match against our portals
            my $address = eval {
                open my $fh, '<', "/sys/class/nvme/$ctrl_name/address" or die;
                my $val = <$fh>;
                close $fh;
                chomp($val);
                $val;
            };
            next unless $address;

            # Parse traddr=X.X.X.X,trsvcid=YYYY from address string
            # \b matters: the address attribute also carries host_traddr=,
            # which would otherwise match as the target address.
            my ($ctrl_host, $ctrl_port);
            if ($address =~ /\btraddr=([^,\s]+)/) {
                $ctrl_host = $1;
            }
            if ($address =~ /\btrsvcid=(\d+)/) {
                $ctrl_port = $1;
            }
            next unless $ctrl_host;
            $ctrl_port //= 4420;

            # If we have portals configured, only include controllers matching them
            if (%portal_set) {
                my $ctrl_key = _nvme_portal_key($ctrl_host, $ctrl_port);
                next unless defined($ctrl_key) && $portal_set{$ctrl_key};
            }

            push @controllers, "/dev/nvme$ctrl_num";
        }
        closedir($sdh);
    }
    closedir($dh);

    return @controllers;
}

# Find NVMe device by matching subsystem NQN and TrueNAS namespace UUID.
# Returns a structured selector result preserving legacy device/device_count fields
# while exposing explicit outcome, counts, selected path, and mismatch reason.
sub _nvme_selector_result {
    my (%args) = @_;

    return {
        selected_device_path => $args{selected_device_path},
        linux_device_count => $args{linux_device_count} // 0,
        api_namespace_count => $args{api_namespace_count},
        match_tier => $args{match_tier},
        selector_outcome => $args{selector_outcome},
        mismatch_reason => $args{mismatch_reason},
        nguid_contradicted => $args{nguid_contradicted} // 0,
    };
}

my %NVME_SUCCESS_OUTCOMES = map { $_ => 1 } qw(exact_match legacy_single_namespace_fallback);

sub _nvme_selector_outcome_is_success {
    return $NVME_SUCCESS_OUTCOMES{$_[0] // ''} // 0;
}

sub _nvme_selector_selected_device_path {
    my ($result) = @_;

    return undef if !$result || ref($result) ne 'HASH';
    return undef if !_nvme_selector_outcome_is_success($result->{selector_outcome});

    return $result->{selected_device_path};
}

sub _nvme_selector_linux_device_count {
    my ($result) = @_;

    return 0 if !$result || ref($result) ne 'HASH';
    return $result->{linux_device_count} // 0;
}

sub _nvme_publication_mismatch_reason {
    my ($linux_device_count, $api_namespace_count) = @_;

    # alpha23: dropped the raw count-inequality reason
    # 'linux_api_namespace_count_mismatch'. In a shared NVMe-oF subsystem
    # (multi-node PVE cluster), each host's kernel enumerates only the
    # namespaces its controller has been notified of. TN's API returns
    # the TOTAL for the subsystem, which includes namespaces created by
    # ALL nodes. Kernel-count < api-count is the STEADY-STATE norm here,
    # not a fault. The genuine faults are: (a) no linux devices visible
    # at all despite TN reporting namespaces, or (b) a single stale device
    # against a multi-namespace subsystem. Everything else — including
    # "TN reports more than this host sees" — is treated as "not visible
    # yet on this host" and the caller keeps retrying with rescan/reconnect.
    return 'api_namespace_not_visible_in_linux'
        if defined($api_namespace_count) && $api_namespace_count > 0 && $linux_device_count == 0;
    return 'single_visible_device_but_api_reports_multiple_namespaces'
        if defined($api_namespace_count) && $linux_device_count == 1 && $api_namespace_count > 1;
    return 'namespace_metadata_did_not_match_visible_devices';
}

my %NVME_SELECTOR_REASON_LABELS = (
    namespace_metadata_query_failed                       => 'TrueNAS API namespace metadata query failed',
    api_subsystem_not_found                               => 'TrueNAS API did not return the target subsystem',
    namespace_uuid_not_returned                           => 'TrueNAS API did not return the target namespace UUID',
    api_namespace_not_visible_in_linux                    => 'subsystem is connected in TrueNAS but no Linux block devices are visible',
    single_visible_device_but_api_reports_multiple_namespaces => 'one Linux block device is visible but TrueNAS reports multiple namespaces',
    # (Removed alpha23: 'linux_api_namespace_count_mismatch' — count
    # inequality is normal in shared NVMe-oF subsystems, not a fault.)
    namespace_metadata_did_not_match_visible_devices      => 'TrueNAS metadata did not match any visible Linux NVMe namespace device',
    subsystem_not_visible                                 => 'NVMe subsystem is not visible in Linux sysfs',
);

sub _nvme_selector_reason_label {
    my ($reason) = @_;
    return $NVME_SELECTOR_REASON_LABELS{$reason // ''} // 'unknown selector mismatch reason';
}

my %NVME_FAILURE_OUTCOMES = map { $_ => 1 } qw(publication_mismatch metadata_failure);

sub _nvme_selector_failure_detail {
    my ($result, $nqn) = @_;

    return undef if !$result || !$result->{selector_outcome};

    my $selector_outcome = $result->{selector_outcome};
    return undef if !$NVME_FAILURE_OUTCOMES{$selector_outcome}
                  && _nvme_selector_outcome_is_success($selector_outcome);

    my $mismatch_reason = $result->{mismatch_reason} // 'unknown';
    my $linux_device_count = $result->{linux_device_count} // 0;
    my $api_namespace_count = defined($result->{api_namespace_count})
        ? $result->{api_namespace_count}
        : 'unknown';
    my $reason_label = _nvme_selector_reason_label($mismatch_reason);

    my $common_detail =
        "  -> Linux-visible block devices: $linux_device_count\n"
        . "  -> TrueNAS API namespace count: $api_namespace_count\n"
        . "  -> Selector mismatch reason: $mismatch_reason\n"
        . "  -> Detail: $reason_label";

    if ($selector_outcome eq 'publication_mismatch') {
        return "TrueNAS namespace publication mismatch detected.\n" . $common_detail;
    }

    if ($selector_outcome eq 'metadata_failure') {
        return "TrueNAS namespace metadata could not be trusted for UUID matching.\n"
            . $common_detail . "\n"
            . "Verify the namespace still exists and is mapped to subsystem '$nqn'.";
    }

    return "Unrecognized selector outcome '$selector_outcome'.\n" . $common_detail;
}

sub _nvme_get_namespace_selector_metadata {
    my ($scfg, $device_uuid) = @_;

    my $nqn = $scfg->{tn_subsystem_nqn};
    my $result = {
        namespace => undef,
        api_namespace_count => undef,
        metadata_state => 'ok',
        metadata_error => undef,
    };

    eval {
        my $subsystems = _api_call($scfg, 'nvmet.subsys.query', [
            [["subnqn", "=", $nqn]]
        ]);

        if (!$subsystems || !@$subsystems) {
            $result->{metadata_state} = 'subsystem_not_found';
            return 1;
        }

        my $subsys_id = $subsystems->[0]{id};
        my $target_namespaces = _api_call($scfg, 'nvmet.namespace.query', [
            [["device_uuid", "=", $device_uuid]]
        ]) // [];
        # alpha20: TrueNAS 25.10+ returns `subsys` as a nested object; filter
        # on subsys.id, not the object itself. The old ["subsys","=",$id] form
        # silently returned 0 results on 25.10, triggering the publication
        # mismatch check (linux_device_count vs api_namespace_count=0) and
        # failing every NVMe activate_volume with "Could not locate NVMe device".
        my $subsys_namespaces = _api_call($scfg, 'nvmet.namespace.query', [
            [["subsys.id", "=", $subsys_id]]
        ]) // [];

        ($result->{namespace}) = grep {
            my $ns_subsys = $_->{subsys};
            my $ns_subsys_id = ref($ns_subsys) eq 'HASH' ? $ns_subsys->{id} : $ns_subsys;
            defined($_->{device_uuid})
                && $_->{device_uuid} eq $device_uuid
                && defined($ns_subsys_id)
                && $ns_subsys_id == $subsys_id;
        } @$target_namespaces;

        $result->{api_namespace_count} = scalar(@$subsys_namespaces);

        if (!$result->{namespace}) {
            $result->{metadata_state} = 'uuid_not_found';
        }

        return 1;
    } or do {
        $result->{metadata_state} = 'query_failed';
        $result->{metadata_error} = $@;
    };

    return $result;
}

sub _nvme_select_namespace_device {
    my ($scfg, $device_uuid, $devices, $namespace_meta) = @_;

    my $linux_device_count = scalar(@$devices);
    my $api_namespace_count = $namespace_meta->{api_namespace_count};
    my $ns_info = $namespace_meta->{namespace};
    my $usable_nguid = 0;
    my $usable_nsid = 0;
    my $nguid_contradicted = 0;

    if ($ns_info && defined $ns_info->{device_nguid}) {
        my $target_nguid = $ns_info->{device_nguid};

        if ($target_nguid !~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i) {
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_find_device: invalid NGUID format from API: $target_nguid");
        } else {
            $usable_nguid = 1;
            _log($scfg, 2, 'debug', "[TrueNAS] nvme_find_device: attempting NGUID match for $target_nguid");

            for my $dev (@$devices) {
                if ($dev->{nguid} && $dev->{nguid} eq $target_nguid) {
                    _log($scfg, 2, 'debug', "[TrueNAS] nvme_find_device: matched device $dev->{path} by NGUID (NSID: $dev->{nsid}, type: $dev->{type})");
                    return _nvme_selector_result(
                        selected_device_path => $dev->{path},
                        linux_device_count => $linux_device_count,
                        api_namespace_count => $api_namespace_count,
                        match_tier => 'nguid',
                        selector_outcome => 'exact_match',
                    );
                }
                # Track devices with real (non-zero) NGUIDs that don't match — indicates
                # a stale subsystem connection where kernel NGUID data is outdated
                if (!$nguid_contradicted && defined($dev->{nguid}) && $dev->{nguid} ne '') {
                    (my $stripped = $dev->{nguid}) =~ s/[-:]//g;
                    $nguid_contradicted = 1 if $stripped =~ /[1-9a-fA-F]/;
                }
            }

            my $device_nguids = join(', ', map {
                my $ng = $_->{nguid} // 'undef';
                "$_->{name}:$ng"
            } @$devices);
            _log($scfg, 2, 'debug', "[TrueNAS] nvme_find_device: devices with NGUIDs: $device_nguids");
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_find_device: NGUID matching failed - no device matched NGUID $target_nguid");
        }
    }

    if ($ns_info && defined $ns_info->{nsid}) {
        my $target_nsid = $ns_info->{nsid};
        $usable_nsid = 1;
        my $nsid_rejected_by_nguid = 0;
        _log($scfg, 2, 'debug', "[TrueNAS] nvme_find_device: attempting NSID match for NSID $target_nsid");

        for my $dev (@$devices) {
            if (defined $dev->{nsid} && $dev->{nsid} eq $target_nsid) {
                # Cross-validate: if the API provided a valid NGUID and this device
                # has a real (non-zero) NGUID that didn't match, this device belongs
                # to a different namespace — it is stale and must be skipped.
                if ($nguid_contradicted && defined($dev->{nguid}) && $dev->{nguid} ne '') {
                    (my $stripped = $dev->{nguid}) =~ s/[-:]//g;
                    if ($stripped =~ /[1-9a-fA-F]/) {
                        $nsid_rejected_by_nguid = 1;
                        _log($scfg, 1, 'warning',
                            "[TrueNAS] nvme_find_device: NSID $target_nsid matched $dev->{path} "
                            . "but device NGUID $dev->{nguid} contradicts API — skipping stale device");
                        next;
                    }
                }
                _log($scfg, 2, 'debug', "[TrueNAS] nvme_find_device: matched device $dev->{path} by NSID (NSID: $dev->{nsid}, type: $dev->{type})");
                return _nvme_selector_result(
                    selected_device_path => $dev->{path},
                    linux_device_count => $linux_device_count,
                    api_namespace_count => $api_namespace_count,
                    match_tier => 'nsid',
                    selector_outcome => 'exact_match',
                );
            }
        }

        if ($nsid_rejected_by_nguid) {
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_find_device: all NSID-matching devices rejected due to NGUID contradiction — stale subsystem connection");
        } else {
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_find_device: NSID matching failed - no device matched NSID $target_nsid");
        }
    }

    if ($namespace_meta->{metadata_state} ne 'ok') {
        my $mismatch_reason = $namespace_meta->{metadata_state} eq 'query_failed'
            ? 'namespace_metadata_query_failed'
            : $namespace_meta->{metadata_state} eq 'subsystem_not_found'
                ? 'api_subsystem_not_found'
                : 'namespace_uuid_not_returned';

        if ($namespace_meta->{metadata_error}) {
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_find_device: TrueNAS API query failed: $namespace_meta->{metadata_error}");
        } elsif ($mismatch_reason eq 'namespace_uuid_not_returned') {
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_find_device: namespace UUID $device_uuid was not returned by TrueNAS API");
        } elsif ($mismatch_reason eq 'api_subsystem_not_found') {
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_find_device: subsystem $scfg->{tn_subsystem_nqn} was not returned by TrueNAS API");
        }

        return _nvme_selector_result(
            linux_device_count => $linux_device_count,
            api_namespace_count => $api_namespace_count,
            selector_outcome => 'metadata_failure',
            mismatch_reason => $mismatch_reason,
        );
    }

    if ($usable_nguid || $usable_nsid) {
        _log($scfg, 1, 'warning', "[TrueNAS] nvme_find_device: refusing legacy single-device fallback because TrueNAS metadata did not match any visible Linux device");
        my $mismatch_reason = _nvme_publication_mismatch_reason($linux_device_count, $api_namespace_count);
        return _nvme_selector_result(
            linux_device_count => $linux_device_count,
            api_namespace_count => $api_namespace_count,
            selector_outcome => 'publication_mismatch',
            mismatch_reason => $mismatch_reason,
            nguid_contradicted => $nguid_contradicted,
        );
    }

    if ($linux_device_count == 1 && defined($api_namespace_count) && $api_namespace_count == 1) {
        _log($scfg, 1, 'info', "[TrueNAS] nvme_find_device: using single device $devices->[0]{path} as tightly-gated legacy fallback (NSID: $devices->[0]{nsid}, type: $devices->[0]{type})");
        return _nvme_selector_result(
            selected_device_path => $devices->[0]{path},
            linux_device_count => $linux_device_count,
            api_namespace_count => $api_namespace_count,
            match_tier => 'single',
            selector_outcome => 'legacy_single_namespace_fallback',
        );
    }

    my $mismatch_reason = _nvme_publication_mismatch_reason($linux_device_count, $api_namespace_count);
    my $dev_list = join(', ', map { "$_->{name} (NSID: $_->{nsid})" } @$devices);
    _log($scfg, 0, 'err',
        "[TrueNAS] nvme_find_device: publication mismatch for UUID $device_uuid "
        . "(linux devices: $linux_device_count, api namespaces: "
        . (defined($api_namespace_count) ? $api_namespace_count : 'unknown')
        . ", reason: $mismatch_reason). Devices: $dev_list");

    return _nvme_selector_result(
        linux_device_count => $linux_device_count,
        api_namespace_count => $api_namespace_count,
        selector_outcome => 'publication_mismatch',
        mismatch_reason => $mismatch_reason,
        nguid_contradicted => $nguid_contradicted,
    );
}

sub _nvme_find_device_by_subsystem {
    my ($scfg, $device_uuid) = @_;

    my $nqn = $scfg->{tn_subsystem_nqn};

    # Find subsystem matching our NQN
    opendir(my $dh, "/sys/class/nvme-subsystem") or return _nvme_selector_result(
        linux_device_count => 0,
        selector_outcome => 'publication_mismatch',
        mismatch_reason => 'subsystem_not_visible',
    );
    while (my $subsys = readdir($dh)) {
        next unless $subsys =~ /^(nvme-subsys\d+)$/;
        $subsys = $1;  # Untaint via capture

        my $subsys_nqn = eval {
            open my $fh, '<', "/sys/class/nvme-subsystem/$subsys/subsysnqn" or die;
            my $val = <$fh>;
            close $fh;
            chomp($val);
            $val;
        };
        next unless $subsys_nqn && $subsys_nqn eq $nqn;

        # Found our subsystem - collect all namespace devices from /sys/block
        # Controller-specific devices don't appear in subsystem directory
        my @devices;
        opendir(my $bdh, "/sys/block") or next;
        while (my $entry = readdir($bdh)) {
            my $type;

            # Match both nvme3n1 and nvme3c3n1 patterns
            # Note: We no longer parse NSID from device name as it's unreliable
            # Use capture groups to untaint $entry from readdir() for use in system calls
            if ($entry =~ /^(nvme\d+n\d+)$/) {
                $entry = $1;  # Untaint via capture
                $type = 'standard';
            } elsif ($entry =~ /^(nvme\d+c\d+n\d+)$/) {
                $entry = $1;  # Untaint via capture
                $type = 'controller';
            } else {
                next;
            }

            # Verify this device belongs to our subsystem by checking NQN
            my $dev_nqn = eval {
                # For standard devices, check via subsystem link
                if ($type eq 'standard' && -e "/sys/block/$entry/device/subsysnqn") {
                    open my $fh, '<', "/sys/block/$entry/device/subsysnqn" or return undef;
                    my $val = <$fh>;
                    close $fh;
                    chomp($val);
                    return $val;
                }
                # For controller devices, navigate to controller then subsystem
                if ($type eq 'controller' && -e "/sys/block/$entry/device/../subsysnqn") {
                    open my $fh, '<', "/sys/block/$entry/device/../subsysnqn" or return undef;
                    my $val = <$fh>;
                    close $fh;
                    chomp($val);
                    return $val;
                }
                return undef;
            };

            if ($dev_nqn && $dev_nqn eq $nqn) {
                # Read NSID and NGUID from sysfs (reliable sources)
                my $sysfs_nsid = eval {
                    open my $fh, '<', "/sys/block/$entry/nsid" or return undef;
                    my $val = <$fh>;
                    close $fh;
                    chomp($val);
                    return $val;
                };
                my $sysfs_nguid = eval {
                    open my $fh, '<', "/sys/block/$entry/nguid" or return undef;
                    my $val = <$fh>;
                    close $fh;
                    chomp($val);
                    return $val;
                };

                push @devices, {
                    path => "/dev/$entry",
                    nsid => $sysfs_nsid,
                    nguid => $sysfs_nguid,
                    type => $type,
                    name => $entry
                };
            }
        }
        closedir($bdh);

        my $device_count = scalar(@devices);
        _log($scfg, 2, 'debug', "[TrueNAS] nvme_find_device: found $device_count device(s) for subsystem $nqn");
        my $namespace_meta = _nvme_get_namespace_selector_metadata($scfg, $device_uuid);
        my $result = _nvme_select_namespace_device($scfg, $device_uuid, \@devices, $namespace_meta);
        closedir($dh);
        return $result;
    }
    closedir($dh);

    return _nvme_selector_result(
        linux_device_count => 0,
        selector_outcome => 'publication_mismatch',
        mismatch_reason => 'subsystem_not_visible',
    );
}

# Collect /dev/nvmeXnY paths for all block devices belonging to our subsystem NQN
sub _nvme_get_subsystem_device_paths {
    my ($scfg) = @_;

    my $nqn = $scfg->{tn_subsystem_nqn};
    my @paths;

    opendir(my $bdh, "/sys/block") or return @paths;
    while (my $entry = readdir($bdh)) {
        next unless $entry =~ /^(nvme\d+(?:c\d+)?n\d+)$/;
        $entry = $1;  # Untaint

        my $dev_nqn = eval {
            # Standard devices have subsysnqn under device/, controller devices under device/../
            my $nqn_path = -e "/sys/block/$entry/device/subsysnqn"
                ? "/sys/block/$entry/device/subsysnqn"
                : "/sys/block/$entry/device/../subsysnqn";
            open my $fh, '<', $nqn_path or return undef;
            my $val = <$fh>;
            close $fh;
            chomp($val);
            return $val;
        };

        push @paths, "/dev/$entry" if $dev_nqn && $dev_nqn eq $nqn;
    }
    closedir($bdh);

    return @paths;
}

# Check if any of the given device paths are in use by a running process.
# Returns: 1 if any device is in use (unsafe to disconnect), 0 if all clear.
sub _nvme_check_devices_in_use {
    my ($scfg, @device_paths) = @_;
    return 0 unless @device_paths;

    # Fail safe: if fuser not available, assume in use
    if (! -x '/usr/bin/fuser' && ! -x '/bin/fuser') {
        _log($scfg, 1, 'warning', "[TrueNAS] fuser not found, cannot verify device safety");
        return 1;
    }

    # fuser -s: exit 0 = at least one device has active process
    #           exit 1 = none accessed (run_command dies on non-zero)
    eval {
        run_command(['fuser', '-s', @device_paths],
            outfunc => sub {},
            errfunc => sub {},
        );
    };
    return $@ ? 0 : 1;  # $@ set = no processes = not in use
}

# Get device path for namespace by matching subsystem NQN and namespace properties
sub _nvme_device_for_uuid {
    my ($scfg, $device_uuid, %opts) = @_;
    my $allow_reconnect = $opts{allow_reconnect} // 0;

    my $nqn = $scfg->{tn_subsystem_nqn};

    _log($scfg, 2, 'debug', "[TrueNAS] nvme_device_for_uuid: searching for namespace with UUID $device_uuid in subsystem $nqn");

    # Wait for device to appear with progressive backoff (up to 5 seconds)
    my $ever_saw_devices = 0;  # Track if any block devices were ever seen (safety guard for reconnect)
    my $nguid_ever_matched = 0;  # Track if NGUID matching ever succeeded (stale detection)
    my $reconnect_attempted = 0;
    my $last_result;

    # alpha23: 100 → 150 iterations (10s → 15s budget). Still well under
    # pveproxy's 60s cap. The extra headroom absorbs TN configfs-sync
    # lag under sustained 3-node create pressure.
    for (my $i = 0; $i < 150; $i++) {
        # Search for device by subsystem NQN
        my $result = eval { _nvme_find_device_by_subsystem($scfg, $device_uuid) };
        $last_result = $result if $result && ref($result) eq 'HASH';
        my $device = _nvme_selector_selected_device_path($result);
        my $device_count = _nvme_selector_linux_device_count($result);

        $ever_saw_devices = 1 if $device_count > 0;

        my $match_tier = $result ? $result->{match_tier} : undef;
        $nguid_ever_matched = 1 if $match_tier && $match_tier eq 'nguid';

        if ($device && -b $device) {
            _log($scfg, 1, 'info', "[TrueNAS] nvme_device_for_uuid: device ready at $device (match: " . ($match_tier // 'unknown') . ")");
            return $device;
        }

        # alpha22: force nvme ns-rescan every ~500ms (5 iterations at 100ms).
        # Under multi-node concurrent create load, the target namespace may
        # be freshly created on TN while another host's controller has not
        # yet been prodded to rediscover it. The previous fixed-iteration
        # rescan schedule (i==15, i==30 only) left ~1.5s gaps in which the
        # kernel would return the same stale namespace list on every check;
        # activate_volume would then run out its 50-iteration budget and
        # die with "Could not locate NVMe device" even though the
        # namespace was live on TN. nvme ns-rescan is a cheap IOCTL, safe
        # to fire this often.
        if ($i > 0 && $i % 5 == 0) {
            eval { _nvme_rescan_subsystem_controllers($scfg) };
        }

        # Progressive interventions to help device discovery
        if ($i == 5) {
            # Early settle
            eval { run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {}) };
        } elsif ($i == 10 && !$reconnect_attempted && $allow_reconnect
                 && $ever_saw_devices && !$nguid_ever_matched
                 && $last_result && $last_result->{nguid_contradicted}
                 && _nvme_is_connected($scfg)) {
            # Early stale NGUID recovery: devices exist with real NGUIDs that contradict
            # the TrueNAS API within the first 1s. An NGUID contradiction is definitive —
            # the kernel's cached namespace data belongs to a previous TrueNAS state and
            # will never self-resolve without a disconnect/reconnect cycle.
            my @dev_paths = _nvme_get_subsystem_device_paths($scfg);
            if (_nvme_check_devices_in_use($scfg, @dev_paths)) {
                _log($scfg, 1, 'warning',
                    "[TrueNAS] nvme_device_for_uuid: stale NGUIDs detected (early) but "
                    . scalar(@dev_paths) . " device(s) are in use, skipping reconnect");
            } else {
                $reconnect_attempted = 1;
                _log($scfg, 1, 'warning',
                    "[TrueNAS] nvme_device_for_uuid: stale NGUID contradiction detected (early) "
                    . "- " . scalar(@dev_paths) . " devices, none in use, reconnecting");
                eval { _nvme_disconnect($scfg) };
                usleep(500_000);
                eval { _nvme_connect($scfg) };
                if ($@) {
                    _log($scfg, 0, 'err',
                        "[TrueNAS] nvme_device_for_uuid: reconnect failed: $@");
                } else {
                    _log($scfg, 1, 'info',
                        "[TrueNAS] nvme_device_for_uuid: reconnect completed, "
                        . "resuming device discovery");
                }
            }
        } elsif ($i == 15) {
            # Trigger udev and rescan NVMe controllers for our subsystem
            eval { run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {}) };
            eval { _nvme_rescan_subsystem_controllers($scfg) };
        } elsif ($i == 25 && !$reconnect_attempted && !$ever_saw_devices && _nvme_is_connected($scfg)) {
            # No $allow_reconnect check needed: zero devices means no VMs are affected.
            # Stale connection recovery: subsystem shows connected but zero block devices
            # have appeared across all iterations. The TrueNAS target has likely stopped
            # publishing namespaces over this connection. Reconnecting forces re-enumeration.
            # Safe because zero devices means no VMs are using this subsystem.
            $reconnect_attempted = 1;
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_device_for_uuid: stale NVMe connection detected - subsystem connected but 0 devices after 2.5s, reconnecting");
            eval { _nvme_disconnect($scfg) };
            usleep(500_000);  # 500ms for disconnect to settle
            eval { _nvme_connect($scfg) };
            if ($@) {
                _log($scfg, 0, 'err', "[TrueNAS] nvme_device_for_uuid: reconnect failed: $@");
            } else {
                _log($scfg, 1, 'info', "[TrueNAS] nvme_device_for_uuid: reconnect completed, resuming device discovery");
            }
        } elsif ($i == 30) {
            # Another settle with trigger
            eval { run_command(['udevadm', 'trigger'], outfunc => sub {}, errfunc => sub {}) };
            eval { run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {}) };
        } elsif (($i == 75 || $i == 125) && !$reconnect_attempted && $allow_reconnect
                 && _nvme_is_connected($scfg)) {
            # alpha23/24: two-tier reconnect for the "target UUID exists on TN
            # but this host's kernel hasn't seen it" case under multi-node
            # concurrent creates.
            #
            # First tier (i==75, ~7.5s): SAFE — skip if any subsystem device
            # is in use by another process on this host, to avoid disrupting
            # running VMs writing to other namespaces on the shared subsystem.
            # In steady-state cluster testing this gate almost always blocks
            # (there is always some VM using something), so it rarely fires.
            #
            # Second tier (i==125, ~12.5s): LAST RESORT — force reconnect
            # regardless of the fuser check. Rationale: at this point the
            # activate_volume for the target VM is going to fail if we do
            # nothing (~2.5s left of the budget, all previous interventions
            # exhausted). A brief NVMe controller drop causes queued I/O on
            # other VMs — kernel NVMe controller-loss handling normally
            # resumes cleanly on reconnect within a couple of seconds. The
            # trade is "one confirmed activate_volume failure now" vs "a few
            # hundred ms of I/O pause on other VMs, then everything works".
            # The failure is worse than the pause.
            my $tn_has_uuid = 0;
            eval {
                my $q = _api_call($scfg, 'nvmet.namespace.query',
                    [[["device_uuid", "=", $device_uuid]]]);
                $tn_has_uuid = 1 if $q && @$q;
            };
            if ($tn_has_uuid) {
                my $is_last_resort = ($i == 125);
                my @dev_paths = _nvme_get_subsystem_device_paths($scfg);
                my $in_use = _nvme_check_devices_in_use($scfg, @dev_paths);
                if ($in_use && !$is_last_resort) {
                    _log($scfg, 1, 'warning',
                        "[TrueNAS] nvme_device_for_uuid: target $device_uuid confirmed on TN "
                        . "but not visible after ~7.5s; "
                        . scalar(@dev_paths) . " subsystem device(s) in use, "
                        . "deferring reconnect to i==125 last-resort");
                } else {
                    $reconnect_attempted = 1;
                    my $when = $is_last_resort ? 'i==125 last-resort' : 'i==75 halfway';
                    my $note = $in_use ? " (forcing despite $in_use device(s) in use)" : '';
                    _log($scfg, 1, 'warning',
                        "[TrueNAS] nvme_device_for_uuid: $when reconnect for target $device_uuid"
                        . $note);
                    eval { _nvme_disconnect($scfg) };
                    usleep(500_000);
                    eval { _nvme_connect($scfg) };
                    if ($@) {
                        _log($scfg, 0, 'err',
                            "[TrueNAS] nvme_device_for_uuid: $when reconnect failed: $@");
                    } else {
                        _log($scfg, 1, 'info',
                            "[TrueNAS] nvme_device_for_uuid: $when reconnect completed");
                    }
                }
            }
        } elsif ($i == 35 && !$reconnect_attempted && $allow_reconnect
                 && $ever_saw_devices && !$nguid_ever_matched
                 && _nvme_is_connected($scfg)) {
            # Stale NGUID recovery: subsystem connected, devices exist, but NGUID
            # has never matched across 35 iterations (~3.5s). The kernel's cached
            # NGUID data is likely stale from a previous TrueNAS service state.
            # Only safe if no running process (QEMU) has any subsystem device open.
            # Note: inherent TOCTOU window between fuser check and disconnect.
            # CFS lock prevents concurrent plugin operations; manual VM starts
            # during this ~1ms window are the residual (very low) risk.
            my @dev_paths = _nvme_get_subsystem_device_paths($scfg);
            if (_nvme_check_devices_in_use($scfg, @dev_paths)) {
                _log($scfg, 1, 'warning',
                    "[TrueNAS] nvme_device_for_uuid: stale NGUIDs detected but "
                    . scalar(@dev_paths) . " device(s) are in use, skipping reconnect");
            } else {
                $reconnect_attempted = 1;
                _log($scfg, 1, 'warning',
                    "[TrueNAS] nvme_device_for_uuid: stale NGUID connection detected "
                    . "- " . scalar(@dev_paths) . " devices, none in use, reconnecting");
                eval { _nvme_disconnect($scfg) };
                usleep(500_000);
                eval { _nvme_connect($scfg) };
                if ($@) {
                    _log($scfg, 0, 'err',
                        "[TrueNAS] nvme_device_for_uuid: reconnect failed: $@");
                } else {
                    _log($scfg, 1, 'info',
                        "[TrueNAS] nvme_device_for_uuid: reconnect completed, "
                        . "resuming device discovery");
                }
            }
        }

        usleep(DEVICE_READY_TIMEOUT_US);  # 100ms
    }

    # alpha26: emergency reconnect after retry budget exhausted.
    #
    # If we get here, the 150-iteration loop failed to locate the target
    # UUID's device. The most common cause under multi-node concurrent
    # load is stale kernel namespace state — the NVMe controller has
    # cached namespaces from prior VM lifecycles whose NGUIDs no longer
    # match anything TN currently publishes. ns-rescan does not evict
    # dead namespaces; only a full disconnect+reconnect flushes the
    # controller and re-enumerates from scratch.
    #
    # The mid-loop reconnect gates (i==10/25/35 stale-NGUID, i==75
    # halfway, i==125 last-resort) all failed to fire on the failures
    # observed 2026-08-21: earlier gates were blocked by the fuser
    # in-use check, and the i==75/125 gates were held back by their
    # own tn_has_uuid inline query returning empty transiently under
    # TN API load.
    #
    # This block runs unconditionally if allow_reconnect=1 and we
    # haven't already reconnected in the loop. No fuser check (loop is
    # about to fail anyway; the brief NVMe I/O pause on other VMs is
    # the lesser evil). No tn_has_uuid gate (already proved TN
    # metadata was queryable — that's what set $last_result with
    # namespace_meta or reason 'namespace_metadata_did_not_match_visible_devices').
    # alpha28: emergency block ignores reconnect_attempted. Alpha27
    # diagnostic proved that when this block ran under mismatch failures,
    # it ALWAYS skipped with "reconnect_attempted=1" — some earlier
    # mid-loop reconnect (usually i==10 stale-NGUID) had already fired
    # but too early: TN had not yet finished publishing the target
    # namespace when it ran, so the reconnect grabbed a still-stale
    # kernel view. By the time the loop exhausted, TN was ready but
    # kernel needed a SECOND reconnect to see it. The single-reconnect
    # cap was silently killing recovery.
    #
    # The only remaining safety concern with unconditional emergency
    # reconnect: cost is ~500ms NVMe controller drop for other VMs on
    # the shared subsystem, running at the moment the loop exhausts.
    # Trade-off: 500ms I/O pause vs a guaranteed failure. The pause
    # wins.
    if (!$allow_reconnect) {
        _log($scfg, 0, 'warning',
            "[TrueNAS] nvme_device_for_uuid: emergency reconnect SKIPPED "
            . "(allow_reconnect=0) — caller did not opt in");
    } elsif (!_nvme_is_connected($scfg)) {
        _log($scfg, 0, 'warning',
            "[TrueNAS] nvme_device_for_uuid: emergency reconnect SKIPPED "
            . "(_nvme_is_connected=0) — subsystem not currently connected");
    } else {
        # Before the emergency reconnect, sweep orphan namespaces off our
        # subsystem. Under multi-node load the publication-mismatch that
        # brings us here is often caused by an accumulating pile of
        # orphaned namespace records on TN whose backing datasets no
        # longer exist. Reconnecting the kernel does not shrink that
        # pile; TN still publishes the ballooned namespace list and the
        # next device lookup can still mis-match. Reap first, then
        # reconnect -- the reconnect's re-enumeration will then reflect
        # the trimmed namespace set.
        eval {
            my $reaped = _nvme_reap_orphan_namespaces($scfg);
            _log($scfg, 0, 'warning',
                "[TrueNAS] nvme_device_for_uuid: pre-reconnect reap removed $reaped orphan namespace(s)")
                if $reaped;
        };
        my $note = $reconnect_attempted
            ? " (SECOND reconnect — prior mid-loop reconnect fired too early)"
            : "";
        _log($scfg, 0, 'warning',
            "[TrueNAS] nvme_device_for_uuid: EMERGENCY RECONNECT after 150-iteration budget "
            . "exhausted for UUID $device_uuid$note — flushing stale kernel namespace cache");
        eval { _nvme_disconnect($scfg) };
        usleep(500_000);
        eval { _nvme_connect($scfg) };
        if ($@) {
            _log($scfg, 0, 'err',
                "[TrueNAS] nvme_device_for_uuid: emergency reconnect failed: $@");
        } else {
            _log($scfg, 0, 'warning',
                "[TrueNAS] nvme_device_for_uuid: emergency reconnect completed, "
                . "re-scanning for target UUID");
            eval { _nvme_rescan_subsystem_controllers($scfg) };
            eval { run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {}) };
            # Brief post-reconnect retry: ~2s (20 iters × 100ms).
            for (my $j = 0; $j < 20; $j++) {
                my $result = eval { _nvme_find_device_by_subsystem($scfg, $device_uuid) };
                my $device = _nvme_selector_selected_device_path($result);
                if ($device && -b $device) {
                    _log($scfg, 0, 'warning',
                        "[TrueNAS] nvme_device_for_uuid: RECOVERED via emergency reconnect at j=$j, "
                        . "device ready at $device");
                    return $device;
                }
                usleep(DEVICE_READY_TIMEOUT_US);
            }
            _log($scfg, 0, 'warning',
                "[TrueNAS] nvme_device_for_uuid: emergency reconnect completed but target "
                . "UUID still not visible after 2s — falling through to error");
        }
    }

    # Device didn't appear - provide detailed troubleshooting.
    # Include explicit API diagnosis so WebSocket/permission failures are not masked as
    # generic "device did not appear" errors when multiple namespaces exist.
    my $namespace_detail = _nvme_selector_failure_detail($last_result, $nqn);

    if (!$namespace_detail) {
        my ($namespaces, $api_err);
        eval {
            $namespaces = _api_call($scfg, 'nvmet.namespace.query', [
                [["device_uuid", "=", $device_uuid]]
            ]);
            1;
        } or do {
            $api_err = $@;
        };

        if ($api_err) {
            chomp($api_err);
            $namespace_detail =
                "TrueNAS API query for namespace metadata failed.\n" .
                "  -> $api_err\n" .
                "The plugin cannot safely disambiguate this UUID when multiple NVMe namespaces are present.";
        } elsif (!$namespaces || !@$namespaces) {
            $namespace_detail =
                "Namespace UUID was not returned by TrueNAS API.\n" .
                "Verify the namespace still exists and is mapped to subsystem '$nqn'.";
        } else {
            $namespace_detail =
                "The namespace exists on TrueNAS but the matching Linux block device did not appear.\n" .
                "Manual cleanup may be required.";
        }
    }

    my $err_msg = sprintf(
        "Could not locate NVMe device for TrueNAS UUID %s\n" .
        "  Subsystem NQN: %s\n\n" .
        "Troubleshooting steps:\n" .
        "  1. Verify NVMe subsystem connection:\n" .
        "     -> Check: nvme list-subsys | grep -A10 '%s'\n" .
        "  2. Check if namespaces are visible as block devices:\n" .
        "     -> Check: nvme list\n" .
        "  3. Verify TrueNAS NVMe-oF service is running\n" .
        "     -> TrueNAS: System Settings > Services > NVMe-oF Target\n" .
        "  4. Check network connectivity:\n" .
        "     -> Check: ping %s\n" .
        "  5. Review kernel logs for NVMe errors:\n" .
        "     -> Check: dmesg | tail -50 | grep nvme\n\n" .
        "%s",
        $device_uuid,
        $nqn,
        $nqn,
        $scfg->{tn_api_host},
        $namespace_detail,
    );

    die $err_msg;
}

# Sync NVMe portals: ensure all configured portals have port bindings on TrueNAS.
# Handles portals added to storage.cfg after initial subsystem setup (Issue #20).
sub _nvme_sync_portals {
    my ($scfg, $subsys_id) = @_;

    my $sid = _cache_host_key($scfg);
    if (time() - ($_portal_sync_last_ok{$sid} // 0) < $CACHE_TTL) {
        _log($scfg, 2, 'debug', "[TrueNAS] nvme_sync_portals: skipping (recently synced "
            . (time() - $_portal_sync_last_ok{$sid}) . "s ago)");
        return;
    }

    # Collect desired portals from storage config
    my @desired_portals = ();
    push @desired_portals, _nvme_configured_portals($scfg);
    return unless @desired_portals;

    # Query existing port-subsystem bindings
    # TrueNAS 25.10+ uses separate port and port_subsys entities
    my $existing_bindings = eval {
        _api_call($scfg, 'nvmet.port_subsys.query', []);
    } // [];

    # Build lookup of existing "addr:port" for this subsystem
    my %existing_set;
    for my $binding (@{$existing_bindings // []}) {
        next unless $binding->{subsys} && $binding->{subsys}{id} == $subsys_id;
        my $port = $binding->{port};
        next unless $port;
        my $key = lc("$port->{addr_traddr}:$port->{addr_trsvcid}");
        $existing_set{$key} = 1;
    }

    # Create missing ports (TrueNAS 25.10+ requires addr_ prefix and separate port_subsys association)
    my $sync_ok = 1;
    for my $portal (@desired_portals) {
        my ($host, $port) = _nvme_parse_portal($portal);
        my $lookup_key = lc("$host:$port");
        next if $existing_set{$lookup_key};

        _log($scfg, 1, 'info', "[TrueNAS] nvme_sync_portals: creating missing port for $host:$port (subsys_id=$subsys_id)");

        my $port_id;
        eval {
            # Step 1: Create the port
            my $port_result = _api_call_mutate($scfg, 'nvmet.port.create', [{
                addr_trtype => 'TCP',
                addr_traddr => $host,
                addr_trsvcid => int($port),
            }]);
            $port_id = ref($port_result) eq 'HASH' ? $port_result->{id} : $port_result;
        };
        if ($@) {
            my $create_err = $@;
            # Port may already exist (shared across subsystems) — find and reuse it
            if ($create_err =~ /already.*port.*same transport and address/i) {
                _log($scfg, 2, 'debug', "[TrueNAS] nvme_sync_portals: port $host:$port already exists, reusing");
                eval {
                    my $all_ports = _api_call($scfg, 'nvmet.port.query', []);
                    for my $p (@{$all_ports // []}) {
                        if (lc($p->{addr_traddr}) eq lc($host) && "$p->{addr_trsvcid}" eq "$port") {
                            $port_id = $p->{id};
                            last;
                        }
                    }
                };
            }
            if (!$port_id) {
                _log($scfg, 1, 'warning', "[TrueNAS] nvme_sync_portals: failed to create or find port for $portal: $create_err");
                $sync_ok = 0;
                next;
            }
        }

        # Step 2: Associate port with subsystem
        eval {
            _api_call_mutate($scfg, 'nvmet.port_subsys.create', [{
                port_id   => int($port_id),
                subsys_id => int($subsys_id),
            }]);
        };
        if ($@) {
            # Association may already exist — not an error
            if ($@ =~ /already exists/i) {
                _log($scfg, 2, 'debug', "[TrueNAS] nvme_sync_portals: port_subsys association already exists for port_id=$port_id");
            } else {
                _log($scfg, 1, 'warning', "[TrueNAS] nvme_sync_portals: failed to associate port for $portal: $@");
                $sync_ok = 0;
            }
        }
    }

    # Only take the TTL shortcut next time if every desired portal really is
    # published. Stamping unconditionally hid a failed port create for a full
    # $CACHE_TTL - precisely the window in which the initiator keeps retrying a
    # portal the target has not published yet.
    $_portal_sync_last_ok{$sid} = time() if $sync_ok;
}

# Ensure NVMe subsystem exists on TrueNAS
sub _nvme_ensure_subsystem {
    my ($scfg) = @_;
    my $nqn = $scfg->{tn_subsystem_nqn};

    _log($scfg, 2, 'debug', "[TrueNAS] nvme_ensure_subsystem: checking for subsystem $nqn");

    # Query existing subsystems
    my $subsystems = _api_call($scfg, 'nvmet.subsys.query', [
        [["subnqn", "=", $nqn]]
    ]);

    if ($subsystems && @$subsystems) {
        my $subsys = $subsystems->[0];
        my $subsys_id = $subsys->{id};
        _log($scfg, 2, 'debug', "[TrueNAS] nvme_ensure_subsystem: subsystem exists with id=$subsys_id, syncing portals");

        _nvme_sync_portals($scfg, $subsys_id);

        return $subsys_id;
    }

    # Create subsystem if it doesn't exist
    _log($scfg, 1, 'info', "[TrueNAS] nvme_ensure_subsystem: creating subsystem $nqn");

    # Generate short name from NQN (last part after :)
    my $name = $nqn;
    $name = $1 if $nqn =~ /:([^:]+)$/;
    $name =~ s/[^a-zA-Z0-9_\-]/_/g;

    # TrueNAS 25.10+ no longer accepts serial parameter in subsystem creation.
    # allow_any_host defaults to true here (TN 26.0.0-BETA.2 won't render
    # a fresh subsys with false + empty allowed_hosts); users with a
    # populated allow_hosts on 25.10.x should set
    # tn_nvme_allow_any_host = 0 in storage.cfg to enforce it. See
    # _nvme_allow_any_host_flag and issue #90.
    my $subsys = _api_call_mutate($scfg, 'nvmet.subsys.create', [{
        name => $name,
        subnqn => $nqn,
        allow_any_host => _nvme_allow_any_host_flag($scfg),
    }]);

    my $subsys_id = ref($subsys) eq 'HASH' ? $subsys->{id} : $subsys;

    # Create ports for all configured portals
    my @portals = ();
    push @portals, $scfg->{tn_discovery_portal} if $scfg->{tn_discovery_portal};
    push @portals, split(/\s*,\s*/, $scfg->{tn_portals}) if $scfg->{tn_portals};

    for my $portal (@portals) {
        my ($host, $port) = _nvme_parse_portal($portal);

        _log($scfg, 2, 'debug', "[TrueNAS] nvme_ensure_subsystem: creating port for $host:$port");

        eval {
            # TrueNAS 25.10+ requires addr_ prefix and separate port_subsys association
            my $port_id;
            my $port_result = eval {
                _api_call_mutate($scfg, 'nvmet.port.create', [{
                    addr_trtype => 'TCP',
                    addr_traddr => $host,
                    addr_trsvcid => int($port),
                }]);
            };
            if ($@ && $@ =~ /already.*port.*same transport and address/i) {
                # Port exists (may be shared with another subsystem) — find and reuse it
                _log($scfg, 2, 'debug', "[TrueNAS] nvme_ensure_subsystem: port $host:$port already exists, reusing");
                my $all_ports = _api_call($scfg, 'nvmet.port.query', []);
                for my $p (@{$all_ports // []}) {
                    if (lc($p->{addr_traddr}) eq lc($host) && "$p->{addr_trsvcid}" eq "$port") {
                        $port_id = $p->{id};
                        last;
                    }
                }
            } elsif ($@) {
                die $@;
            } else {
                $port_id = ref($port_result) eq 'HASH' ? $port_result->{id} : $port_result;
            }

            if (defined $port_id) {
                eval {
                    _api_call_mutate($scfg, 'nvmet.port_subsys.create', [{
                        port_id   => int($port_id),
                        subsys_id => int($subsys_id),
                    }]);
                };
                if ($@ && $@ =~ /already exists/i) {
                    _log($scfg, 2, 'debug', "[TrueNAS] nvme_ensure_subsystem: port_subsys association already exists");
                } elsif ($@) {
                    die $@;
                }
            }
        };
        if ($@) {
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_ensure_subsystem: failed to create port for $portal: $@");
        }
    }

    _log($scfg, 1, 'info', "[TrueNAS] nvme_ensure_subsystem: created subsystem with id=$subsys_id");
    return $subsys_id;
}

# Create NVMe namespace for a zvol
sub _nvme_create_namespace {
    my ($scfg, $zname, $full_ds, $zvol_path) = @_;

    _log($scfg, 1, 'info', "[TrueNAS] nvme_create_namespace: creating namespace for $zname");

    # Ensure subsystem exists
    my $subsys_id = _nvme_ensure_subsystem($scfg);

    # Create namespace
    # Note: zvol creation job is now waited on in alloc_image() before calling this function
    my $ns = _api_call_mutate($scfg, 'nvmet.namespace.create', [{
        device_type => 'ZVOL',
        device_path => $zvol_path,  # Already has 'zvol/' prefix
        subsys_id => $subsys_id,
        enabled => JSON::PP::true,
    }]);

    my $device_uuid = $ns->{device_uuid};
    die "Failed to get device_uuid from namespace creation\n" unless $device_uuid;

    _log($scfg, 1, 'info', "[TrueNAS] nvme_create_namespace: created namespace with UUID $device_uuid");

    # Workaround: TrueNAS may not sync configfs after namespace create (Issue #12).
    # The update() is a benign ping to trigger the configfs re-render; we pass
    # the currently-configured allow_any_host value so we do not silently flip
    # a user-set attribute back to true (issue #90).
    eval { _api_call_mutate($scfg, 'nvmet.subsys.update',
        [$subsys_id, { allow_any_host => _nvme_allow_any_host_flag($scfg) }]) };
    if ($@) {
        _log($scfg, 1, 'warning', "[TrueNAS] nvme_create_namespace: subsystem reapply failed (non-fatal): $@");
    }

    # Connect to subsystem if not already connected
    _nvme_connect($scfg);

    # Wait for device to appear
    my $dev = _nvme_device_for_uuid($scfg, $device_uuid, allow_reconnect => 1);
    _log($scfg, 1, 'info', "[TrueNAS] nvme_create_namespace: device ready at $dev");

    return $device_uuid;
}

# Resolve NVMe namespaces by their globally unique device path. Query results
# nest the subsystem under 'subsys.id'; 'subsys_id' is create-only input.
sub _nvme_namespaces_for_device_path {
    my ($scfg, $device_path) = @_;
    return _api_call($scfg, 'nvmet.namespace.query', [
        [["device_path", "=", $device_path]]
    ]) // [];
}

# alpha21: idempotent namespace create.
#
# The plain nvmet.namespace.create call goes through _api_call_mutate which
# retries up to 3 times on connection errors. If TN successfully creates the
# namespace but the WS response is dropped mid-flight (frequent under
# 3-node concurrent load), the retry fires and TN creates a SECOND namespace
# for the same device_path. Unlike iSCSI extents, nvmet has no
# name-uniqueness constraint, so both survive as duplicates. Over a full
# test run this compounded to ~2.83 namespace rows per zvol (68 rows for
# 24 live zvols, plus 28 fully-orphan rows from prior alloc failures).
#
# Kernel-side each nvmet namespace is bound to configfs; when TN accumulates
# duplicate records the configfs writer falls behind and only some end up
# published to the target port. Connected hosts then see far fewer namespaces
# than the DB claims exist (observed: 9 kernel-visible vs 96 DB rows), and
# activate_volume dies with "namespace publication mismatch".
#
# Contract: given a subsys_id + zvol_path, return exactly one namespace row
# for that zvol_path (device_uuid, nsid, etc.). If one already exists,
# return it (reuse). Otherwise create — with retries disabled — and on ANY
# error re-query in case the create succeeded server-side before the error
# was raised. If the re-query finds a namespace, use it; only re-raise the
# error if nothing landed. Callers pass the same $ns_payload they were
# building for the raw create; only subsys_id/device_path/device_type are
# used from it — device_uuid is assigned by TN.
sub _nvme_create_namespace_idempotent {
    my ($scfg, $ns_payload) = @_;

    my $zvol_path = $ns_payload->{device_path}
        or die "_nvme_create_namespace_idempotent: device_path missing from payload";

    # Reuse if already present.
    my $existing = _nvme_namespaces_for_device_path($scfg, $zvol_path);
    if ($existing && @$existing) {
        _log($scfg, 1, 'info',
            "[TrueNAS] _nvme_create_namespace_idempotent: reusing existing namespace uuid="
            . ($existing->[0]{device_uuid} // '<unknown>') . " for $zvol_path");
        return $existing->[0];
    }

    # alpha30: pick a monotonic-high nsid to avoid TN nsid recycling.
    #
    # Under multi-node create/destroy churn, TN's nvmet auto-assigns the
    # LOWEST FREE nsid on create. Under short-lived VMs this rapidly
    # recycles low nsids. The kernel side then sees:
    #   nsid=3 device_uuid=<OLD-DELETED-NAMESPACE-UUID>
    # even after TN's DB has committed:
    #   nsid=3 device_uuid=<NEW-NAMESPACE-UUID>
    # because TN's configfs sync (DB -> /sys/kernel/config/nvmet/...) does
    # not always land the nsid=3 rewrite before a connecting host reads
    # the port's namespace list. Kernel then can't match the target UUID
    # to any visible namespace at nsid=3 — activate_volume fails with
    # "namespace_metadata_did_not_match_visible_devices" and NO amount of
    # rescan/reconnect fixes it (evidence: alpha28's emergency reconnect
    # completes but the stale UUID at nsid=3 persists).
    #
    # Fix: pass explicit nsid = max_nsid_in_subsystem + jitter, so every
    # new namespace lands at a nsid that has NEVER been used in this
    # subsystem's lifetime. Kernel has no cached mapping for the new
    # nsid, so its post-connect enumeration reflects TN's current DB.
    # Jitter (random 1..8) reduces the collision window between concurrent
    # nodes both computing max+1.
    #
    # Ceiling: TN subsystem NN=1024. If max ever exceeds ceiling, we fall
    # back to letting TN auto-assign (accept the recycle-bug risk again).
    # Under Max's test-suite churn this ceiling is well above what we see.
    if (!defined $ns_payload->{nsid}) {
        my $subsys_id = $ns_payload->{subsys_id};
        if ($subsys_id) {
            my $ns_list = eval {
                _api_call($scfg, 'nvmet.namespace.query',
                    [[["subsys.id", "=", $subsys_id]]]);
            };
            if (!$@ && ref($ns_list) eq 'ARRAY') {
                my $max = 0;
                for my $n (@$ns_list) {
                    $max = $n->{nsid} if defined($n->{nsid}) && $n->{nsid} > $max;
                }
                my $jitter = int(rand(8)) + 1;   # 1..8
                my $picked = $max + $jitter;
                if ($picked < 1024) {
                    $ns_payload = { %$ns_payload, nsid => $picked };
                    _log($scfg, 1, 'info',
                        "[TrueNAS] _nvme_create_namespace_idempotent: picked explicit nsid=$picked "
                        . "(max_used=$max, jitter=$jitter) for $zvol_path");
                } else {
                    _log($scfg, 1, 'warning',
                        "[TrueNAS] _nvme_create_namespace_idempotent: max_used_nsid=$max near "
                        . "subsystem NN ceiling — falling back to TN auto-assignment for $zvol_path");
                }
            }
        }
    }

    # Create with retries disabled so a lost response cannot duplicate.
    # zvol-visibility retry is the caller's responsibility (it needs to
    # inspect the specific validator error message).
    my $ns = eval {
        _api_call($scfg, 'nvmet.namespace.create', [ $ns_payload ],
            { retry_opts => { retry_max => 0 } });
    };
    if (my $err = $@) {
        # Response may have been lost after TN committed. Re-query.
        my $recheck = _nvme_namespaces_for_device_path($scfg, $zvol_path);
        if ($recheck && @$recheck) {
            _log($scfg, 1, 'info',
                "[TrueNAS] _nvme_create_namespace_idempotent: create errored ($err) "
                . "but namespace uuid=" . ($recheck->[0]{device_uuid} // '<unknown>')
                . " exists for $zvol_path — treating as success");
            return $recheck->[0];
        }
        # alpha30: nsid collision from concurrent nodes both picking the
        # same max+jitter value. Recompute and retry once with a fresh
        # max + fresh jitter.
        if (defined $ns_payload->{nsid}
            && $err =~ /nsid.*already|nsid.*in use|duplicate.*nsid/i) {
            _log($scfg, 1, 'warning',
                "[TrueNAS] _nvme_create_namespace_idempotent: nsid=$ns_payload->{nsid} "
                . "collision, recomputing and retrying once");
            delete $ns_payload->{nsid};
            my $subsys_id = $ns_payload->{subsys_id};
            if ($subsys_id) {
                my $ns_list = eval {
                    _api_call($scfg, 'nvmet.namespace.query',
                        [[["subsys.id", "=", $subsys_id]]]);
                };
                if (!$@ && ref($ns_list) eq 'ARRAY') {
                    my $max = 0;
                    for my $n (@$ns_list) {
                        $max = $n->{nsid} if defined($n->{nsid}) && $n->{nsid} > $max;
                    }
                    my $picked = $max + int(rand(16)) + 1;
                    $ns_payload = { %$ns_payload, nsid => $picked } if $picked < 1024;
                }
            }
            $ns = eval {
                _api_call($scfg, 'nvmet.namespace.create', [ $ns_payload ],
                    { retry_opts => { retry_max => 0 } });
            };
            return $ns if !$@;
            $err = $@;
        }
        die $err;
    }
    return $ns;
}

# Reap orphan NVMe namespaces on our subsystem: those whose device_path
# points at a zvol under our tn_dataset prefix but whose backing dataset
# no longer exists on TN. These accumulate when a namespace teardown
# fails partway (network glitch, TN transient) and the plugin surfaces a
# warn but does not persist a retry ledger. Over many operations the
# orphans build up on TN, the publication-mismatch detector in
# _nvme_device_for_uuid then reports "TrueNAS API namespace count: N,
# Linux-visible block devices: M" and dies for every subsequent VM
# activation. Confirmed in Max R. Carrara's test_run7 2026-08-26 3-node
# cluster runs: 253-274 mismatch cascades per node, all traced to
# monotonically-growing orphan namespace counts (4 -> 8 -> 25 -> 49 in
# one subrun).
#
# Scope: only namespaces under our subsystem AND under our storage's
# tn_dataset prefix. Namespaces belonging to other storage configs
# sharing the subsystem, and ephemeral vzdump snapshot clones (issue
# #42), are left alone.
#
# Returns the number of namespaces reaped, or undef on setup failure.
# Never dies -- best-effort cleanup, called from deferred paths.
sub _nvme_reap_orphan_namespaces {
    my ($scfg) = @_;

    my $nqn = $scfg->{tn_subsystem_nqn};
    return undef unless defined $nqn && length $nqn;

    my $ds_prefix = $scfg->{tn_dataset};
    return undef unless defined $ds_prefix && length $ds_prefix;

    my $reap_prefix = "zvol/$ds_prefix/";

    my $subsystems = eval {
        _api_call($scfg, 'nvmet.subsys.query', [
            [ [ 'subnqn', '=', $nqn ] ]
        ]);
    };
    if ($@ || !$subsystems || !@$subsystems) {
        _log($scfg, 1, 'warning',
            "[TrueNAS] reap_orphan_namespaces: subsystem query failed: " . ($@ // 'no subsystem'));
        return undef;
    }
    my $subsys_id = $subsystems->[0]{id};

    my $namespaces = eval {
        _api_call($scfg, 'nvmet.namespace.query',
            [ [ [ 'subsys.id', '=', $subsys_id ] ] ]);
    };
    if ($@ || ref($namespaces) ne 'ARRAY') {
        _log($scfg, 1, 'warning',
            "[TrueNAS] reap_orphan_namespaces: namespace query failed: " . ($@ // 'not an array'));
        return undef;
    }

    my $datasets = eval {
        _api_call($scfg, 'pool.dataset.query',
            [ [ [ 'id', '^', "$ds_prefix/" ] ] ]);
    };
    if ($@ || ref($datasets) ne 'ARRAY') {
        _log($scfg, 1, 'warning',
            "[TrueNAS] reap_orphan_namespaces: dataset query failed: " . ($@ // 'not an array'));
        return undef;
    }
    my %ds_exists = map { ($_->{id} // '') => 1 } @$datasets;

    my @orphans;
    for my $ns (@$namespaces) {
        my $dp = $ns->{device_path} // '';
        next unless length $dp;
        next unless index($dp, $reap_prefix) == 0;  # only our storage's slice
        (my $ds_id = $dp) =~ s{^zvol/}{};
        next if $ds_exists{$ds_id};                 # backing dataset still there -- keep
        my ($zname) = $dp =~ m{/([^/]+)$};
        next if $zname && _is_snapshot_clone_zname($zname);  # issue #42 clones own their cleanup
        push @orphans, $ns;
    }

    return 0 unless @orphans;

    _log($scfg, 0, 'info',
        "[TrueNAS] reap_orphan_namespaces: found " . scalar(@orphans) .
        " orphan namespace(s) in subsys id=$subsys_id under $ds_prefix/ " .
        "(referencing deleted datasets); deleting");

    my $reaped = 0;
    for my $ns (@orphans) {
        my $ns_id = $ns->{id};
        my $dp    = $ns->{device_path} // '<undef>';
        my $uuid  = $ns->{device_uuid} // '<undef>';
        my $nsid  = $ns->{nsid}        // '<undef>';
        eval {
            _api_call($scfg, 'nvmet.namespace.delete', [ $ns_id ]);
        };
        if (my $err = $@) {
            if ($err =~ /does not exist|ENOENT|InstanceNotFound/i) {
                $reaped++;
                _log($scfg, 1, 'info',
                    "[TrueNAS] reap_orphan_namespaces: id=$ns_id already gone");
            } else {
                _log($scfg, 0, 'warning',
                    "[TrueNAS] reap_orphan_namespaces: failed to delete id=$ns_id " .
                    "nsid=$nsid uuid=$uuid device_path=$dp: $err");
            }
        } else {
            $reaped++;
            _log($scfg, 0, 'info',
                "[TrueNAS] reap_orphan_namespaces: deleted orphan id=$ns_id " .
                "nsid=$nsid uuid=$uuid device_path=$dp");
        }
    }

    return $reaped;
}

# Resolve the NVMe device_uuid to use for a volume: the embedded one if the
# volname carries it, otherwise looked up by zvol path. Cloud-init volumes
# (issue #84) have no embedded metadata and always take the lookup path.
# Cached (short TTL, cleared by the normal _clear_cache mutation hooks) so
# that path() and activate_volume back-to-back for the same cloud-init
# volume don't each pay a separate nvmet.namespace.query round trip.
sub _resolve_nvme_uuid($scfg, $zname, $known_uuid) {
    return $known_uuid if defined $known_uuid;
    my $device_path = "zvol/" . $scfg->{tn_dataset} . '/' . $zname;
    my $storage_id = _cache_host_key($scfg);
    my $cache_method = "ns_by_path:$device_path";
    my $ns = _get_cached($storage_id, $cache_method);
    if (!$ns) {
        $ns = _nvme_namespaces_for_device_path($scfg, $device_path);
        _set_cache($storage_id, $cache_method, $ns);
    }
    my $uuid = @$ns ? $ns->[0]{device_uuid} : undef;
    die "Could not locate NVMe namespace for '$zname'\n" if !defined $uuid;
    return $uuid;
}

# Delete NVMe namespace
sub _nvme_delete_namespace {
    my ($scfg, $zname, $full_ds) = @_;

    _log($scfg, 1, 'info', "[TrueNAS] nvme_delete_namespace: deleting namespace for $zname");

    my $namespaces = _nvme_namespaces_for_device_path($scfg, "zvol/$full_ds");

    return unless $namespaces && @$namespaces;

    for my $ns (@$namespaces) {
        _log($scfg, 2, 'debug', "[TrueNAS] nvme_delete_namespace: deleting namespace id=$ns->{id}");
        eval {
            _api_call($scfg, 'nvmet.namespace.delete', [$ns->{id}]);
        };
        if ($@) {
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_delete_namespace: failed to delete namespace $ns->{id}: $@");
        }
    }
}

# ======== Required storage interface ========
# volname format:
#   iSCSI:      vol-<zname>-lun<N>, where <zname> is usually vm-<vmid>-disk-<n>
#   NVMe/TCP:   vol-<zname>-ns<uuid>, where uuid is the device_uuid from TrueNAS
#   Cloud-init: vm-<vmid>-cloudinit, no "vol-" prefix and no metadata suffix --
#               required verbatim by PVE core's drive_is_cloudinit() (issue #84).
#               Device is resolved dynamically by zvol path, see
#               _resolve_iscsi_lun / _resolve_nvme_uuid.
sub parse_volname {
    my ($class, $volname) = @_;

    # Cloud-init disk: plain "vm-<vmid>-cloudinit", no prefix/suffix. The
    # classification goes through the same predicate alloc_image/list_images
    # use, so the two can't drift on what counts as a cloud-init volname;
    # the digit extraction below is safe because that predicate already
    # guarantees the ^vm-\d+-cloudinit$ shape.
    if (_is_cloudinit_zname($volname)) {
        my ($vmid) = $volname =~ /^vm-(\d+)-cloudinit$/;
        return ('images', $volname, $vmid, undef, undef, undef, 'raw', undef);
    }

    # Slash-encoded linked-clone form (PVE convention):
    #   <base_volid>/<clone_volid>
    # where <base_volid> begins with "vol-base-<basevmid>-...". When this
    # form is supplied, the second half is the live clone and the first
    # half identifies its origin template. PVE stores this exact string
    # in the cloned VM's .conf. Both halves can be iSCSI or NVMe.
    if ($volname =~ m{^(vol-base-\d+-disk-\d+-(?:lun\d+|ns[a-f0-9\-]+))/(vol-vm-\d+-disk-\d+-(?:lun\d+|ns[a-f0-9\-]+))$}) {
        my ($base_volid, $clone_volid) = ($1, $2);
        # Recurse to extract details from each half. The clone half is the
        # one PVE actually wants identifiers for; basename/basevmid come
        # from the base half.
        my (undef, $clone_zname, $clone_vmid, undef, undef, undef, $fmt, $clone_meta) =
            $class->parse_volname($clone_volid);
        my (undef, $base_zname,  $base_vmid,  undef, undef, undef, undef, undef) =
            $class->parse_volname($base_volid);
        return ('images', $clone_zname, $clone_vmid, $base_zname, $base_vmid, undef, $fmt, $clone_meta);
    }

    # iSCSI format: vol-<zname>-lun<N>
    if ($volname =~ m/^vol-([A-Za-z0-9:_\.\-]+)-lun(\d+)$/) {
        my ($zname, $lun) = ($1, $2);
        my ($vmid, $isBase);
        if    ($zname =~ m/^vm-(\d+)-/)   { $vmid = $1; }
        elsif ($zname =~ m/^base-(\d+)-/) { $vmid = $1; $isBase = 1; }
        # return shape mimics other block plugins:
        # ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format, $metadata)
        # For iSCSI, metadata = lun number
        return ('images', $zname, $vmid, undef, undef, $isBase, 'raw', $lun);
    }

    # NVMe format: vol-<zname>-ns<uuid>
    if ($volname =~ m/^vol-([A-Za-z0-9:_\.\-]+)-ns([a-f0-9\-]+)$/) {
        my ($zname, $uuid) = ($1, $2);
        my ($vmid, $isBase);
        if    ($zname =~ m/^vm-(\d+)-/)   { $vmid = $1; }
        elsif ($zname =~ m/^base-(\d+)-/) { $vmid = $1; $isBase = 1; }
        # For NVMe, metadata = device_uuid
        return ('images', $zname, $vmid, undef, undef, $isBase, 'raw', $uuid);
    }

    die "unable to parse volname '$volname'\n";
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    # Note: snapname is used during clone operations - we support snapshots via ZFS
    my (undef, $zname, $vmid, undef, undef, undef, undef, $metadata) = $class->parse_volname($volname);

    my $mode = $scfg->{tn_transport_mode} // 'iscsi';

    # Snapshot mode (issue #42): return the device for the ephemeral snapshot
    # clone that activate_volume exposed, rather than the live volume's device.
    if (defined($snapname) && $snapname ne '') {
        my ($clone_zname, $clone_full) = _snapshot_clone_paths($scfg, $zname, $snapname);
        if ($mode eq 'iscsi') {
            _iscsi_login_all($scfg);
            my $lun = _current_lun_for_zname($scfg, $clone_zname);
            die "snapshot device not active for $volname\@$snapname\n" if !defined $lun;
            my $dev = _device_for_lun($scfg, $lun);
            return ($dev, $vmid, 'images');
        } elsif ($mode eq 'nvme-tcp') {
            _nvme_connect($scfg);
            my $ns = _nvme_namespaces_for_device_path($scfg, "zvol/$clone_full");
            my $uuid = @$ns ? $ns->[0]{device_uuid} : undef;
            die "snapshot namespace not active for $volname\@$snapname\n" if !$uuid;
            # alpha25: allow_reconnect=1 so the retry loop's stale-kernel-state
            # recovery paths (i==10/i==25/i==35/i==75/i==125) can actually fire
            # when path() is called from qmclone/qmstart/qmdestroy under
            # multi-node concurrent load. Without it, those gates silently
            # skipped and every path() failure ran out the retry budget.
            my $dev = _nvme_device_for_uuid($scfg, $uuid, allow_reconnect => 1);
            return ($dev, $vmid, 'images');
        } else {
            die "Unknown transport mode: $mode\n";
        }
    }

    if ($mode eq 'iscsi') {
        # iSCSI: metadata is LUN number. Cloud-init volumes (issue #84) carry
        # no embedded metadata and always take the re-resolve path below.
        my $lun = $metadata;
        _iscsi_login_all($scfg);
        my $dev;
        my $lookup_err;
        if (defined $lun) {
            eval { $dev = _device_for_lun($scfg, $lun); };
            $lookup_err = $@;
        }
        if (!$dev) {
            # No embedded LUN, or the embedded one may be stale: re-resolve
            # the current mapping via the shared helper (also the sole path
            # for cloud-init volumes, which have no embedded metadata at
            # all -- issue #84). Dies with a clear message if unresolvable.
            my $real_lun = _resolve_iscsi_lun($scfg, $zname, undef);
            if (!defined($lun) || $real_lun != $lun) {
                $dev = _device_for_lun($scfg, $real_lun);
            } else {
                # Mapping is unchanged: the original _device_for_lun failure
                # already carries a detailed diagnostic (active sessions,
                # by-path listing) that's more useful than a generic
                # message, so bubble it up instead of re-deriving one.
                die $lookup_err if $lookup_err;
                die "Could not locate device for LUN $lun (IQN $scfg->{tn_target_iqn})\n";
            }
        }
        return ($dev, $vmid, 'images');

    } elsif ($mode eq 'nvme-tcp') {
        # NVMe: metadata is device_uuid. Cloud-init volumes (issue #84) carry
        # no embedded metadata and always take the re-resolve path below.
        my $uuid = $metadata;
        _nvme_connect($scfg);
        # alpha25: allow_reconnect=1 — same rationale as the snapshot path
        # above. Every PVE op that touches an NVMe volume goes through path();
        # denying reconnect here made every stale-kernel recovery path
        # unreachable and every mismatch a certain failure.
        my $dev;
        my $lookup_err;
        if (defined $uuid) {
            eval { $dev = _nvme_device_for_uuid($scfg, $uuid, allow_reconnect => 1); };
            $lookup_err = $@;
        }
        if (!$dev) {
            # No embedded UUID, or the embedded one may be stale: re-resolve
            # the current namespace via the shared helper (also the sole
            # path for cloud-init volumes -- issue #84).
            my $real_uuid = _resolve_nvme_uuid($scfg, $zname, undef);
            if (!defined($uuid) || $real_uuid ne $uuid) {
                $dev = _nvme_device_for_uuid($scfg, $real_uuid, allow_reconnect => 1);
            } else {
                # UUID is unchanged: the original lookup already ran the
                # full discovery/retry loop, so a second identical attempt
                # would just repeat it. Bubble up the original diagnostic.
                die $lookup_err if $lookup_err;
                die "Could not locate NVMe device for UUID $uuid\n";
            }
        }
        return ($dev, $vmid, 'images');

    } else {
        die "Unknown transport mode: $mode\n";
    }
}

# Create a new VM disk (zvol + transport-specific exposure) and hand it to Proxmox.
# Arguments (per PVE): ($class, $storeid, $scfg, $vmid, $fmt, $name, $size_kib)
# NOTE: Proxmox passes size in KiB (kibibytes), not bytes!
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size_kib) = @_;

    # Wall-clock instrumentation (level 0 -- always visible). Prefixed
    # TIMING so operators can grep and diff. Emitted at each phase
    # boundary; timestamps let us attribute slow allocs to preflight,
    # TN dataset.create, TN extent/tx create, or the transport wrapper
    # under real cluster load. Remove once we've conclusively pinned
    # down the 596-under-contention bottleneck in cluster_test_run
    # 3-node runs.
    my $t0 = Time::HiRes::time();
    my $t_last = $t0;
    my $lap = sub {
        my ($label) = @_;
        my $now = Time::HiRes::time();
        _log($scfg, 0, 'info', sprintf(
            "[TrueNAS] TIMING alloc vmid=%s %s: +%.3fs (total %.3fs)",
            $vmid, $label, $now - $t_last, $now - $t0));
        $t_last = $now;
    };

    # Level 0: Always log (errors only logged elsewhere)
    # Level 1: Light - function entry with key parameters
    _log($scfg, 1, 'info', "[TrueNAS] alloc_image: vmid=$vmid, name=" . ($name // 'undef') . ", size=$size_kib KiB");
    $lap->('entry');

    die "only raw is supported\n" if defined($fmt) && $fmt ne 'raw';
    die "invalid size\n" if !defined($size_kib) || $size_kib <= 0;

    # Convert KiB to bytes for TrueNAS API
    my $bytes = int($size_kib) * 1024;

    # Level 2: Verbose - unit conversion details
    _log($scfg, 2, 'debug', "[TrueNAS] alloc_image: converting $size_kib KiB → $bytes bytes");

    # Determine effective volblocksize: step down by halves until it evenly divides $bytes.
    # Do NOT round $bytes up — that makes the zvol larger than requested and breaks QEMU
    # drive-mirror size checks during VM migration (issue #25).
    my $blocksize = $scfg->{tn_zvol_blocksize};
    my $bs_bytes  = _parse_blocksize($blocksize);

    if ($bs_bytes && $bs_bytes > 0 && ($bytes % $bs_bytes) != 0) {
        my $orig_bs = $blocksize;
        while ($bs_bytes > 512 && ($bytes % $bs_bytes) != 0) {
            $bs_bytes = int($bs_bytes / 2);
        }
        $blocksize = ($bs_bytes >= 1024) ? (int($bs_bytes / 1024) . 'K') : "$bs_bytes";
        _log($scfg, 1, 'info', "[TrueNAS] " . sprintf(
            "alloc_image: volblocksize stepped down: %s → %s to fit %d bytes exactly (avoids size mismatch on migration)",
            $orig_bs, $blocksize, $bytes
        ));
    }


    # Pre-flight checks: validate all prerequisites before expensive operations
    _log($scfg, 1, 'info', "[TrueNAS] alloc_image: running pre-flight checks for $bytes bytes");
    my $errors = _preflight_check_alloc($scfg, $bytes);
    $lap->('preflight');
    if (@$errors) {
        my $error_msg = "Pre-flight validation failed:\n  - " . join("\n  - ", @$errors);
        _log($scfg, 0, 'err', "[TrueNAS] alloc_image: pre-flight check failed for VM $vmid: " . join("; ", @$errors));
        die "$error_msg\n";
    }

    # Log successful pre-flight checks
    _log($scfg, 1, 'info', sprintf(
        "[TrueNAS] alloc_image: pre-flight checks passed for %s volume allocation on '%s' (VM %d)",
        _format_bytes($bytes), $scfg->{tn_dataset}, $vmid
    ));

    # Determine a disk name under our dataset: vm-<vmid>-disk-<n>
    my $zname = $name;
    if (!$zname) {
        $zname = _find_free_disk_name($scfg, $vmid);
    }

    my $full_ds = $scfg->{tn_dataset} . '/' . $zname;

    # 1) Create the zvol (VOLUME) on TrueNAS with requested size
    # Note: $bytes already calculated above in space check (size in KiB * 1024)
    # Note: $blocksize was determined above (may be stepped-down from configured value)

    # Handle race condition: if dataset already exists (e.g., from concurrent delete still in progress),
    # retry with an incremented disk number. This can happen during rapid create/delete cycles where
    # the async ZFS delete hasn't completed before a new allocation with the same name is attempted.
    my $max_create_retries = 5;
    my $create_attempt = 0;
    my $create_result;
    my $create_error;

    while ($create_attempt < $max_create_retries) {
        $create_attempt++;
        $create_error = undef;

        # All six of these must be sent explicitly, not omitted: TrueNAS 25.10.4's
        # legacy API shim leaves omitted optional fields as unresolved _NotRequired
        # sentinels instead of real defaults, crashing pool.dataset.create both in
        # validation and in audit-log serialization (#58, #65, #78). special_small_block_size
        # must be 'INHERIT' specifically - 0 fails a ZFS-level check, null fails Pydantic.
        my $create_payload = {
            name                     => $full_ds,
            type                     => 'VOLUME',
            volsize                  => $bytes,
            sparse                   => ($scfg->{tn_sparse} // 1) ? JSON::PP::true : JSON::PP::false,
            comments                 => 'Autocreated by Proxmox Plugin',
            volblocksize             => _normalize_blocksize($blocksize) // '16K',
            snapdev                  => 'INHERIT',
            reservation              => 0,
            refreservation           => 0,
            special_small_block_size => 'INHERIT',
            force_size               => JSON::PP::false,
        };
        # Pass compression algorithm if configured (otherwise inherits from parent dataset)
        $create_payload->{compression} = uc($scfg->{tn_compression}) if $scfg->{tn_compression};

        eval {
            $create_result = _api_call(
                $scfg,
                'pool.dataset.create',
                [ $create_payload ],
            );
        };

        if ($@) {
            $create_error = $@;
            # Check if error is "dataset already exists" - indicates race condition with async delete
            if ($create_error =~ /dataset already exists/i) {
                _log($scfg, 1, 'warn', "[TrueNAS] alloc_image: zvol $full_ds already exists (attempt $create_attempt/$max_create_retries), trying alternate name");

                # Parse current name and increment disk number
                if ($zname =~ /^(vm-\d+-disk-)(\d+)(.*)$/) {
                    my ($prefix, $num, $suffix) = ($1, $2, $3);
                    $zname = $prefix . ($num + 1) . $suffix;
                    $full_ds = $scfg->{tn_dataset} . '/' . $zname;
                    _log($scfg, 1, 'info', "[TrueNAS] alloc_image: retrying with name $zname");
                    next;  # Retry with new name
                } else {
                    # Name doesn't match expected pattern, can't auto-increment
                    die "Dataset $full_ds already exists and name pattern cannot be auto-incremented: $create_error\n";
                }
            }
            # Some other error - re-throw
            die $create_error;
        }

        # Success - break out of retry loop
        last;
    }

    # If we exhausted retries, die with the last error
    if ($create_attempt >= $max_create_retries && $create_error) {
        die "Failed to create zvol after $max_create_retries attempts (last error: $create_error)\n";
    }
    $lap->('pool.dataset.create');

    # If pool.dataset.create returns a job ID, wait for it to complete
    # This ensures the zvol is fully created before we try to use it
    if (defined $create_result && !ref($create_result) && $create_result =~ /^\d+$/) {
        _log($scfg, 1, 'info', "[TrueNAS] alloc_image: waiting for zvol creation job $create_result to complete");
        my $job_result = _wait_for_job_completion($scfg, $create_result, 30);
        unless ($job_result->{success}) {
            die "Failed to create zvol $full_ds: " . ($job_result->{error} // 'Unknown error') . "\n";
        }
        _log($scfg, 1, 'info', "[TrueNAS] alloc_image: zvol $full_ds created successfully");
        $lap->('zvol.job.wait');
    }

    _invalidate_status_capacity_cache($storeid, $scfg);

    # 2) Transport-specific volume exposure
    my $zvol_path = 'zvol/' . $full_ds;
    my $mode = $scfg->{tn_transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        return _alloc_image_iscsi($class, $scfg, $zname, $full_ds, $zvol_path);
    } elsif ($mode eq 'nvme-tcp') {
        return _alloc_image_nvme($class, $scfg, $zname, $full_ds, $zvol_path);
    } else {
        die "Unknown transport mode: $mode\n";
    }
}

# iSCSI-specific allocation (create extent + mapping, wait for device)
sub _alloc_image_iscsi {
    my ($class, $scfg, $zname, $full_ds, $zvol_path) = @_;

    my $t0 = Time::HiRes::time();
    my $t_last = $t0;
    my $lap = sub {
        my ($label) = @_;
        my $now = Time::HiRes::time();
        _log($scfg, 0, 'info', sprintf(
            "[TrueNAS] TIMING alloc_iscsi zname=%s %s: +%.3fs (total %.3fs)",
            $zname, $label, $now - $t_last, $now - $t0));
        $t_last = $now;
    };
    $lap->('entry');

    # Create an iSCSI extent for that zvol (device-backed)
    # TrueNAS expects a 'disk' like "zvol/<pool>/<zname>"
    my $extent_name = _generate_extent_name($scfg, $zname);
    my $extent_payload = {
        name => $extent_name,
        type => 'DISK',
        disk => $zvol_path,
        insecure_tpc => JSON::PP::true, # typical default for modern OS initiators
    };
    my $extent_id;

    # Idempotency: if an extent already points at this exact zvol path,
    # reuse it instead of colliding on the deterministic extent name.
    # Extent orphans from a prior failed free_image (or a concurrent
    # cluster node that got there first) otherwise brick every retry --
    # test_run5/truenas-2026-08-06 3-node cluster runs surfaced this as a
    # cascade of "iscsi_extent_create.name: Extent name must be unique"
    # failures that persisted across every subsequent iteration.
    # _clone_image_iscsi already applies the same check; align the alloc
    # path with it.
    {
        my $reuse_matches = _tn_extent_query_by_disk($scfg, $zvol_path) // [];
        my $existing_extent = $reuse_matches->[0];
        if ($existing_extent) {
            $extent_id = $existing_extent->{id};
            _log($scfg, 1, 'info',
                "[TrueNAS] _alloc_image_iscsi: reusing existing extent id=$extent_id for $zvol_path");
        }
    }
    $lap->('extent.reuse_check');

    if (!defined $extent_id) {
        # pool.dataset.create returns as soon as ZFS finishes, but TN validates
        # iscsi.extent.create by stat'ing /dev/zvol/<ds> which udev may still
        # be creating. Poll-retry on that specific validator error only, up to
        # ~3 s. Same shape as _clone_image_iscsi -- the alloc path races less
        # in practice but the window is identical, so cover it too.
        my $ext;
        my $err;
        my $max_zvol_wait_attempts = 15;
        for (my $attempt = 1; $attempt <= $max_zvol_wait_attempts; $attempt++) {
            $ext = eval {
                _api_call_mutate(
                    $scfg,
                    'iscsi.extent.create',
                    [ $extent_payload ],
                );
            };
            $err = $@;
            last if !$err;
            last if !_is_zvol_not_ready_error($err);
            _log($scfg, 1, 'info',
                "[TrueNAS] alloc_image_iscsi: /dev/zvol/$full_ds not visible yet " .
                "(attempt $attempt/$max_zvol_wait_attempts), waiting for udev");
            select(undef, undef, undef, 0.2);
        }
        # Fix B: post-hoc reuse on unique-name conflict. The plugin knows
        # the exact name it tried; look the extent up by name (most direct
        # match) and reuse if its disk field is ours. If TN has an extent
        # with our name but a DIFFERENT disk field, log loudly at level 0
        # so operators can see what's on TN even without tn_debug set --
        # that shape is exactly the diagnostic gap that made Max R.
        # Carrara's (Proxmox) test_run6 cluster failures unattributable.
        if ($err && _is_extent_name_conflict_error($err)) {
            _clear_cache(_cache_host_key($scfg));  # force fresh view
            my $by_name_matches = _tn_extent_query_by_name($scfg, $extent_name) // [];
            my $by_name = $by_name_matches->[0];
            if ($by_name) {
                if (($by_name->{disk} // '') eq $zvol_path) {
                    _log($scfg, 1, 'info',
                        "[TrueNAS] _alloc_image_iscsi: name-conflict resolved by reuse " .
                        "id=$by_name->{id} name=$extent_name for $zvol_path (Fix B)");
                    $ext = $by_name;
                    $err = '';
                } elsif (_iscsi_extent_recover_stale_base_name($scfg, $by_name, $zvol_path)) {
                    # Historical create_base extent-rename gap. Stale
                    # base extent renamed; retry our create once.
                    $ext = eval {
                        _api_call_mutate($scfg, 'iscsi.extent.create', [ $extent_payload ]);
                    };
                    $err = $@;
                    if (!$err) {
                        _log($scfg, 0, 'info',
                            "[TrueNAS] _alloc_image_iscsi: retry after stale-base rename succeeded for $extent_name");
                    }
                } else {
                    # An extent with our deterministic name exists but points
                    # at a different disk. Fix B cannot safely reuse it (that
                    # would silently redirect this VM's disk to whatever the
                    # foreign extent is backing). Report the actual TN state.
                    _log($scfg, 0, 'err',
                        "[TrueNAS] _alloc_image_iscsi: extent name '$extent_name' " .
                        "already on TN (id=$by_name->{id}) with disk='" .
                        ($by_name->{disk} // '<undef>') . "', we expected disk='$zvol_path'. " .
                        "Refusing to reuse -- another zvol may be sharing our hash slot, " .
                        "or TN normalized the disk field. Investigate iscsi.extent.query.");
                }
            } else {
                _log($scfg, 0, 'warning',
                    "[TrueNAS] _alloc_image_iscsi: TN said name '$extent_name' is not unique " .
                    "but a follow-up iscsi.extent.query does not surface it. Possible cache " .
                    "or replication lag on TN; falling through to failure.");
            }
        }
        if ($err) {
            # Cleanup: delete the zvol if extent creation failed. The nested
            # eval clobbers $@, so capture the original error first.
            eval { _tn_dataset_delete($scfg, $full_ds) };
            die "Failed to create iSCSI extent for disk '$zname': $err\n";
        }
        # normalize id from WebSocket result (hashref)
        $extent_id = ref($ext) eq 'HASH' ? $ext->{id} : $ext;
        # Invalidate cache so subsequent targetextents lookup sees current state
        _clear_cache(_cache_host_key($scfg));
    }
    $lap->('extent.create');
    if (!defined $extent_id) {
        eval { _tn_dataset_delete($scfg, $full_ds) };
        die sprintf(
            "Failed to create iSCSI extent for disk '%s'\n\n" .
            "Dataset: %s\n" .
            "zvol path: %s\n" .
            "Extent name: %s\n\n" .
            "Common causes:\n" .
            "  1. TrueNAS iSCSI service is not running\n" .
            "     -> Check: System Settings > Services > iSCSI (should be RUNNING)\n" .
            "  2. ZFS dataset creation succeeded but zvol is not accessible\n" .
            "     -> Verify zvol exists: zfs list -t volume | grep %s\n" .
            "  3. API key lacks 'Sharing' write permissions\n" .
            "     -> Check: Credentials > API Keys > Verify permissions\n" .
            "  4. Extent name conflict with existing extent\n" .
            "     -> Check: Shares > iSCSI > Extents for duplicate names\n\n" .
            "TrueNAS logs: /var/log/middlewared.log\n",
            $zname, $full_ds, $zvol_path, $extent_name, $zname
        );
    }

    # 3) Map extent to our shared target via _tn_targetextent_create.
    # This wrapper handles idempotency and "Extent is already in use" recovery
    # for concurrent-node races, so no separate pre-check is needed.
    my $target_id = _resolve_target_id($scfg);

    my $lun;
    {
        my $tx = eval { _tn_targetextent_create($scfg, $target_id, $extent_id, undef) };
        if (my $err = $@) {
            # Cleanup: delete extent and zvol if mapping creation failed.
            # Nested evals clobber $@, so capture the original error first.
            eval { _api_call_mutate($scfg, 'iscsi.extent.delete', [$extent_id]) };
            eval { _tn_dataset_delete($scfg, $full_ds) };
            die "Failed to create target-extent mapping for disk '$zname': $err\n";
        }

        # Extract LUN from the returned mapping object
        $lun = ref($tx) eq 'HASH' ? $tx->{lunid} : undef;

        # Invalidate cache after creating new mapping
        _clear_cache(_cache_host_key($scfg));

        # Fallback: re-fetch if create response didn't include lunid
        if (!defined $lun) {
            my $tx_matches = _tn_targetextent_query_by_target_extent($scfg, $target_id, $extent_id) // [];
            my $existing_map = $tx_matches->[0];
            $lun = $existing_map->{lunid} if $existing_map;
        }
    }
    $lap->('targetextent.create');
    if (!defined $lun) {
        die sprintf(
            "Could not determine assigned LUN for disk '%s'\n\n" .
            "Target ID: %d\n" .
            "Extent ID: %d\n" .
            "Extent name: %s\n\n" .
            "This usually means:\n" .
            "  1. Target-extent mapping creation failed silently\n" .
            "  2. TrueNAS cache not yet updated (rare)\n" .
            "  3. API query returned stale data\n\n" .
            "Troubleshooting:\n" .
            "  - Check TrueNAS GUI: Shares > iSCSI > Targets > Associated Targets\n" .
            "  - Verify extent '%s' is mapped to target ID %d\n" .
            "  - Check TrueNAS logs: /var/log/middlewared.log\n" .
            "  - Verify API has 'Sharing' read permissions\n",
            $zname, $target_id, $extent_id, $zname, $zname, $target_id
        );
    }

    # 5) Return volname immediately — device discovery is deferred after lock release.
    # activate_volume handles authoritative device discovery before any VM uses the disk.
    # Cloud-init disks (issue #84) must be named exactly "vm-<vmid>-cloudinit" with
    # no metadata suffix, so PVE core recognizes and regenerates them on clone.
    my $volname = _is_cloudinit_zname($zname) ? $zname : "vol-$zname-lun$lun";

    # Defer local I/O operations (iSCSI login, rescan, device polling) to run after CFS lock release
    my $deferred_scfg = $scfg;  # capture for closure
    my $deferred_lun = $lun;
    _defer_after_lock(sub {
        $lap->('deferred.start');
        _log($deferred_scfg, 2, 'debug', "[TrueNAS] alloc_image deferred: starting iSCSI device discovery for LUN $deferred_lun");

        # When sessions are already active, skip the disruptive session rescan and multipath
        # reload — these affect ALL iSCSI sessions/devices system-wide and can cause I/O errors
        # on other active multipath devices (Issue #15). activate_volume handles authoritative
        # device discovery with built-in rescans at safe intervals.
        if (_target_sessions_active($deferred_scfg)) {
            _log($deferred_scfg, 2, 'debug', "[TrueNAS] alloc_image deferred: sessions already active, skipping rescan (activate_volume will handle device discovery)");
            return;
        }

        # No active sessions — perform login and device discovery
        _log($deferred_scfg, 1, 'info', "[TrueNAS] alloc_image deferred: logging in to target $deferred_scfg->{tn_target_iqn}");
        eval { _iscsi_login_all($deferred_scfg); };
        if ($@) {
            _log($deferred_scfg, 1, 'warning', "[TrueNAS] alloc_image deferred: iSCSI login failed (activate_volume will retry): $@");
            return;
        }

        # Rescan to detect the new LUN (safe here — we just logged in, no existing I/O)
        eval { _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan failed"); };
        # Force capacity re-read on existing sdX devices. Required when the
        # new LUN number was recycled from a previously-deleted extent.
        eval { _iscsi_rescan_sd_capacity($deferred_scfg); };
        if ($deferred_scfg->{tn_use_multipath}) {
            eval { _try_run(['multipath','-r'], "multipath reload failed"); };
        }
        eval { run_command(['udevadm','settle'], outfunc => sub {}); };

        # Best-effort device verification with reduced retries. Pass
        # max_retries_override=1 to _device_for_lun so its internal poll
        # collapses to a single non-blocking check -- our outer 8x250ms
        # loop is the retry budget for this deferred, best-effort path,
        # and the full 60 s inner timeout would stack on top of it.
        my $device_ready = 0;
        for my $attempt (1..8) {
            eval {
                my $dev = _device_for_lun($deferred_scfg, $deferred_lun, 1);
                if ($dev && -e $dev && -b $dev) {
                    _log($deferred_scfg, 2, 'debug', "[TrueNAS] alloc_image deferred: device $dev ready for LUN $deferred_lun (attempt $attempt)");
                    $device_ready = 1;
                }
            };
            last if $device_ready;
            usleep(250_000);  # 250ms between attempts
            if ($attempt % 4 == 0) {
                eval { _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan"); };
                eval { run_command(['udevadm','settle'], outfunc => sub {}); };
            }
        }
        if (!$device_ready) {
            _log($deferred_scfg, 1, 'info', "[TrueNAS] alloc_image deferred: device not yet visible for LUN $deferred_lun (activate_volume will handle)");
        }
        $lap->('deferred.end');
    });

    return $volname;
}

# NVMe-specific allocation (create namespace, defer device discovery)
sub _alloc_image_nvme {
    my ($class, $scfg, $zname, $full_ds, $zvol_path) = @_;

    _log($scfg, 1, 'info', "[TrueNAS] _alloc_image_nvme: creating NVMe namespace for $zname");

    # Create namespace on TrueNAS (locked section — API calls only)
    my $subsys_id = _nvme_ensure_subsystem($scfg);
    my $ns_payload_alloc = {
        device_type => 'ZVOL',
        device_path => $zvol_path,
        subsys_id => $subsys_id,
        enabled => JSON::PP::true,
    };

    # alpha21: idempotent create defuses retry-storm duplicates (see
    # _nvme_create_namespace_idempotent header). Zvol-visibility retry
    # (waiting for /dev/zvol/<ds> to appear) stays here — that error
    # is not a retryable connection error, so the outer WS layer would
    # not retry it anyway.
    my $ns;
    my $ns_err;
    my $max_zvol_wait_attempts = 15;
    for (my $attempt = 1; $attempt <= $max_zvol_wait_attempts; $attempt++) {
        $ns = eval { _nvme_create_namespace_idempotent($scfg, $ns_payload_alloc) };
        $ns_err = $@;
        last if !$ns_err;
        last if !_is_zvol_not_ready_error($ns_err);
        _log($scfg, 1, 'info',
            "[TrueNAS] _alloc_image_nvme: $zvol_path not visible as block device yet " .
            "(attempt $attempt/$max_zvol_wait_attempts), waiting for udev");
        select(undef, undef, undef, 0.2);
    }
    if (my $err = $ns_err) {
        # Cleanup: delete the zvol if namespace creation failed. The nested
        # eval clobbers $@, so capture the original error first.
        eval { _tn_dataset_delete($scfg, $full_ds) };
        die "Failed to create NVMe namespace for disk '$zname': $err\n";
    }
    my $device_uuid = $ns->{device_uuid};
    unless ($device_uuid) {
        eval { _tn_dataset_delete($scfg, $full_ds) };
        die "Failed to get device_uuid from namespace creation\n";
    }
    _log($scfg, 1, 'info', "[TrueNAS] _alloc_image_nvme: created namespace with UUID $device_uuid");

    # Return volname immediately — defer connect + device discovery.
    # Cloud-init disks (issue #84) must be named exactly "vm-<vmid>-cloudinit" with
    # no metadata suffix, so PVE core recognizes and regenerates them on clone.
    my $volname = _is_cloudinit_zname($zname) ? $zname : "vol-$zname-ns$device_uuid";

    my $deferred_scfg = $scfg;
    my $deferred_uuid = $device_uuid;
    my $deferred_subsys_id = $subsys_id;
    _defer_after_lock(sub {
        # alpha32: instrument every phase at level 0 so we can see which
        # step of the deferred block holds the VM config lock the longest.
        # LOCKHOLD tag makes it grep-friendly against the "can't lock
        # file" test failures. Each phase logs elapsed time from block
        # entry.
        my $t0 = Time::HiRes::time();
        my $lap_defer = sub {
            my ($phase) = @_;
            _log($deferred_scfg, 0, 'info', sprintf(
                "[TrueNAS] LOCKHOLD alloc_nvme_deferred uuid=%s phase=%s elapsed=%.3fs",
                $deferred_uuid, $phase, Time::HiRes::time() - $t0));
        };
        $lap_defer->('entry');

        # Workaround: TrueNAS may not sync configfs after namespace create (Issue #12).
        # Ping via update() with the currently-configured allow_any_host so we
        # do not silently overwrite a user-set attribute (issue #90).
        eval { _api_call_mutate($deferred_scfg, 'nvmet.subsys.update',
            [$deferred_subsys_id, { allow_any_host => _nvme_allow_any_host_flag($deferred_scfg) }]) };
        if ($@) {
            _log($deferred_scfg, 1, 'warning', "[TrueNAS] alloc_image_nvme deferred: subsystem reapply failed (non-fatal): $@");
        }
        $lap_defer->('subsys.update');

        _log($deferred_scfg, 2, 'debug', "[TrueNAS] alloc_image_nvme deferred: connecting and discovering device for UUID $deferred_uuid");
        eval { _nvme_connect($deferred_scfg); };
        if ($@) {
            _log($deferred_scfg, 1, 'warning', "[TrueNAS] alloc_image_nvme deferred: NVMe connect failed (activate_volume will retry): $@");
            $lap_defer->('nvme_connect_failed_exit');
            return;
        }
        $lap_defer->('nvme_connect');
        # Settle + rescan to detect new namespace (mirrors clone_image_nvme deferred path)
        usleep(200_000);  # 200ms initial settle
        eval { run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {}) };
        $lap_defer->('udevadm_settle');
        eval { _nvme_rescan_subsystem_controllers($deferred_scfg) };
        $lap_defer->('nvme_rescan');
        # alpha31: allow_reconnect=0 in the DEFERRED path. This runs while
        # the VM's config lock (/var/lock/qemu-server/lock-<vmid>.conf) is
        # still held by the calling qm operation. If _nvme_device_for_uuid
        # triggers a reconnect (stale-NGUID gate at i==10 fires often under
        # multi-node testing), the kernel does a full controller
        # remove+add and udev re-enumerates every namespace under the
        # subsystem (~30 devices). The subsequent udevadm settle inside
        # _nvme_device_for_uuid blocks 10-13s waiting for udev to drain,
        # and we STILL hold the config lock during that. Any concurrent
        # qm op on the same VMID from the test framework times out on
        # lock-<vmid>.conf. Pre-warm is best-effort — if the device is
        # not yet visible here, activate_volume (which is called OUTSIDE
        # the config lock via a fresh worker) has allow_reconnect=1 and
        # will do the reconnect cleanly then.
        my $dev = eval { _nvme_device_for_uuid($deferred_scfg, $deferred_uuid, allow_reconnect => 0) };
        $lap_defer->('device_for_uuid');
        if ($dev) {
            _log($deferred_scfg, 1, 'info', "[TrueNAS] alloc_image_nvme deferred: device ready at $dev");
        } else {
            _log($deferred_scfg, 1, 'info', "[TrueNAS] alloc_image_nvme deferred: device not yet visible (activate_volume will handle)");
        }
        $lap_defer->('exit');
    });

    _log($scfg, 1, 'info', "[TrueNAS] _alloc_image_nvme: volume created successfully: $volname");
    return $volname;
}

# Return size in bytes (scalar), or (size_bytes, format) in list context
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    my (undef, $zname, undef, undef, undef, undef, $fmt, undef) =
        $class->parse_volname($volname);
    $fmt //= 'raw';
    my $full = $scfg->{tn_dataset} . '/' . $zname;
    my $ds = eval { _tn_dataset_get($scfg, $full) } // {};
    if (my $err = $@) {
        if ($err =~ /does not exist|ENOENT|InstanceNotFound/i) {
            die "volume '$full' does not exist on TrueNAS\n";
        }
        die $err;
    }
    my $bytes = _normalize_value($ds->{volsize});
    die "volume_size_info: missing volsize for $full\n" if !$bytes;
    return wantarray ? ($bytes, $fmt) : $bytes;
}

# Delete a VM disk: remove transport-specific resources, delete zvol, and clean up.
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    # Level 1: Light - function entry
    _log($scfg, 1, 'info', "[TrueNAS] free_image: volname=$volname");

    die "unsupported format '$format'\n" if defined($format) && $format ne 'raw';

    my (undef, $zname, undef, undef, undef, $parsed_isBase, undef, $metadata) =
        $class->parse_volname($volname);
    my $full_ds = $scfg->{tn_dataset} . '/' . $zname;

    # If this is a base / template volume, refuse to delete it while any
    # linked clone still derives from its __base__ snapshot. ZFS would
    # already refuse the destroy at the libzfs level, but doing the
    # check here gives PVE a clearer error message than the EBUSY
    # rollup it would otherwise see.
    #
    # PVE may call free_image either with $isBase=1 explicitly (when it
    # got the parse_volname result earlier), or with $isBase=undef but a
    # zname matching the base-<vmid>-disk-N convention. Detect both.
    if ($isBase || $parsed_isBase) {
        my $snap_id = "$full_ds\@__base__";
        # TN's pool.snapshot.query does not surface the `clones` zfs
        # property in this release (the properties object comes back
        # empty regardless of extra.properties / retrieve_properties).
        # Query the dataset side instead: any volume whose origin
        # points at our @__base__ snapshot is a live linked clone.
        my $children = eval {
            _api_call($scfg, 'pool.dataset.query',
                [ [ [ 'origin.parsed', '=', $snap_id ] ],
                  { select => [ 'id' ] } ]);
        };
        my @clones;
        if ($children && ref($children) eq 'ARRAY') {
            @clones = map { $_->{id} } grep { defined $_->{id} } @$children;
        }
        if (@clones) {
            die sprintf(
                "Cannot delete base image '%s': %d linked clone(s) still " .
                "derive from %s\@__base__ (%s). Destroy the clone(s) first " .
                "or use `pool.dataset.promote` on one to break the dependency.\n",
                $volname, scalar(@clones), $full_ds, join(', ', @clones),
            );
        }
        _log($scfg, 1, 'info',
            "[TrueNAS] free_image: deleting base image $full_ds (no live clones)");
    }

    # Protect weight volume from deletion - it maintains target visibility
    # Match both old format (pve-plugin-weight) and new format (pve-weight-*)
    if ($zname eq 'pve-plugin-weight' || $zname =~ /^pve-weight-/) {
        die "Cannot delete weight volume '$volname' - it maintains target visibility and prevents storage outages.\n" .
            "Weight volumes are critical infrastructure and must persist to keep iSCSI targets discoverable.\n";
    }

    # Level 2: Verbose - parsed details
    _log($scfg, 2, 'debug', "[TrueNAS] free_image: zname=$zname, metadata=" . ($metadata // 'none') . ", full_ds=$full_ds");

    # Dispatch to transport-specific deletion
    my $mode = $scfg->{tn_transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        # Cloud-init volumes (issue #84) carry no embedded LUN; resolve one
        # best-effort so _free_image_iscsi can still pre-clean the local
        # SCSI device before the TrueNAS-side delete. Failure here must not
        # block deletion (the zvol/extent lookup below is independent of
        # LUN), so a failed resolve just leaves $lun undef as before.
        my $lun = $metadata // eval { _resolve_iscsi_lun($scfg, $zname, undef) };
        return _free_image_iscsi($class, $storeid, $scfg, $volname, $zname, $full_ds, $lun);
    } elsif ($mode eq 'nvme-tcp') {
        return _free_image_nvme($class, $storeid, $scfg, $volname, $zname, $full_ds, $metadata);
    } else {
        die "Unknown transport mode: $mode\n";
    }
}

# iSCSI-specific deletion
sub _free_image_iscsi {
    my ($class, $storeid, $scfg, $volname, $zname, $full_ds, $lun) = @_;

    # Capture SCSI device names BEFORE any deletion/logout (symlinks disappear after logout)
    # This allows us to clean up orphaned SCSI devices after TrueNAS deletion succeeds
    my @scsi_devices_to_cleanup;
    if (defined $lun) {
        eval {
            my $iqn = $scfg->{tn_target_iqn};
            my $pattern = "-iscsi-$iqn-lun-$lun";
            if (opendir(my $dh, "/dev/disk/by-path")) {
                my @by_paths = grep { $_ =~ /^ip-.*\Q$pattern\E$/ } readdir($dh);
                closedir($dh);
                for my $bp (@by_paths) {
                    # Validate and untaint the path
                    next unless $bp =~ m{^(ip-[\w.:,\[\]\-]+iscsi-[\w.:,\[\]\-]+lun-\d+)$};
                    my $full_path = "/dev/disk/by-path/$1";
                    next unless -l $full_path;
                    # Resolve symlink to actual device
                    my $real = Cwd::abs_path($full_path);
                    if ($real && $real =~ m{^/dev/(sd[a-z]{1,4})$}) {
                        push @scsi_devices_to_cleanup, $1;
                    }
                }
            }
        };
        _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: captured " . scalar(@scsi_devices_to_cleanup) . " SCSI device(s) for cleanup") if @scsi_devices_to_cleanup;
    }

    # Resolve target/extent/mapping on TrueNAS (moved up: needed for WWID validation below).
    # Use narrow queries: we only ever want the row that matches THIS zvol.
    my $target_id = _resolve_target_id($scfg);
    my $zvol_path_match = "zvol/$scfg->{tn_dataset}/$zname";
    my $ext_matches = _tn_extent_query_by_disk($scfg, $zvol_path_match) // [];
    my $extent = $ext_matches->[0];
    my $tx;
    if ($extent && $target_id) {
        my $tx_matches = _tn_targetextent_query_by_target_extent($scfg, $target_id, $extent->{id}) // [];
        $tx = $tx_matches->[0];
    }

    # Best-effort: flush the local multipath map for this LUN's WWID.
    # Derive WWID directly from the TrueNAS extent NAA (already fetched above) rather than
    # calling path() + scsi_id — scsi_id does not work reliably on DM devices (/dev/mapper/mpathX),
    # and calling path() here would re-enter the login path on a volume being deleted.
    # TrueNAS NAA format: "0x6589cfc..." → multipath WWID: "36589cfc..." (0x prefix → NAA-6 type byte 3)
    if ($scfg->{tn_use_multipath}) {
        eval {
            if ($extent && $extent->{naa} && $extent->{naa} =~ /^0x/i) {
                (my $flush_wwid = lc($extent->{naa})) =~ s/^0x/3/;
                _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: flushing multipath map $flush_wwid");
                eval { PVE::Tools::run_command(['multipath','-f',$flush_wwid], outfunc=>sub{}, errfunc=>sub{}) };
            }
            # If no extent or NAA missing/malformed: skip flush (cannot determine WWID safely)
        };
        # ignore any multipath flush errors here
    }

    my $in_use = sub { my ($e)=@_; return ($e && $e =~ /in use/i) ? 1 : 0; };
    my $need_force_logout = 0;
    my $did_session_logout = 0;

    # Pre-teardown: remove this LUN's SCSI block device from the kernel before TrueNAS API calls.
    # The iSCSI TCP session stays open (needed for other LUNs), but the kernel device is released.
    if (@scsi_devices_to_cleanup) {
        _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: pre-teardown of " . scalar(@scsi_devices_to_cleanup) . " SCSI device(s) before API calls");
        my @device_paths;
        for my $dev (@scsi_devices_to_cleanup) {
            my $delete_path = "/sys/block/$dev/device/delete";
            push @device_paths, $delete_path if -e $delete_path;
            if (-e $delete_path && -w $delete_path) {
                eval {
                    _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: deleting SCSI device $dev");
                    if (open my $fh, '>', $delete_path) { print $fh "1"; close $fh; }
                };
            }
        }
        _verify_devices_disconnected($scfg, \@device_paths);
        eval { run_command(['udevadm','settle'], outfunc => sub {}) };
        sleep(DEVICE_SETTLE_DELAY_S);
        @scsi_devices_to_cleanup = ();
    }

    # 1) Delete targetextent mapping
    # Always pass force=true to bypass "target in use" checks from other cluster nodes' sessions.
    if ($tx && defined $tx->{id}) {
        my $id = $tx->{id};
        my $ok = eval {
            _api_call($scfg,'iscsi.targetextent.delete',[ $id, JSON::PP::true ]);
            1;
        };
        if (!$ok) {
            my $err = $@ // '';
            if ($scfg->{tn_force_delete_on_inuse} && $in_use->($err)) {
                $need_force_logout = 1;
            } elsif ($err !~ /does not exist|ENOENT|InstanceNotFound/i) {
                # Only warn if resource actually exists - ENOENT means already cleaned up
                warn "warning: delete targetextent id=$id failed: $err";
            }
            # Silently ignore "does not exist" errors - resource already gone
        }
    }

    # 2) Delete extent (may still be mapped if step 1 failed)
    # Always pass force=true to bypass "target in use" checks from other cluster nodes' sessions.
    if ($extent && defined $extent->{id}) {
        my $eid = $extent->{id};
        my $ok = eval {
            _api_call($scfg,'iscsi.extent.delete',[ $eid, JSON::PP::false, JSON::PP::true ]);
            1;
        };
        if (!$ok) {
            my $err = $@ // '';
            if ($scfg->{tn_force_delete_on_inuse} && $in_use->($err)) {
                $need_force_logout = 1;
            } elsif ($err !~ /does not exist|ENOENT|InstanceNotFound/i) {
                # Only warn if resource actually exists - ENOENT means already cleaned up
                warn "warning: delete extent id=$eid failed: $err";
            }
            # Silently ignore "does not exist" errors - resource already gone
        }
    }

    # 3) If TrueNAS reported "in use" and force_delete_on_inuse=1, check if safe to logout
    # Don't logout if there are other active LUNs - this breaks multi-disk operations
    if ($need_force_logout) {
        # Invalidate cache to get fresh targetextent data — a destination LUN may have been
        # created since the cache was last populated (e.g., during a disk move operation)
        _clear_cache(_cache_host_key($scfg));
        # Check how many LUNs are currently mapped to this target. Narrow-
        # query by target only (server-side filter), then count.
        my $active_luns = 0;
        eval {
            my $target_maps = _api_call($scfg, 'iscsi.targetextent.query',
                [ [ [ 'target', '=', $target_id ] ] ]) // [];
            $active_luns = scalar(@$target_maps);
        };

        # Only logout if this is the last LUN (or unknown count) — full logout during a
        # disk move would tear down the destination LUN's session mid-copy.
        if ($active_luns <= 1 || $@) {
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: logging out to retry extent deletion (active LUNs: $active_luns)");
            _logout_target_all_portals($scfg);
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: waiting for iSCSI session to disconnect");
            sleep(DEVICE_SETTLE_DELAY_S);
            eval { run_command(['udevadm','settle'], outfunc => sub {}) };
            $did_session_logout = 1;
        } else {
            # Other LUNs active — do NOT logout entire target.
            # Early per-LUN SCSI teardown should have released this LUN's reference.
            # $need_force_logout stays 1 to trigger the retry block below without a session logout.
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: $active_luns LUNs active — retrying deletes without logout");
        }
        # Retry mapping delete
        if ($tx && defined $tx->{id}) {
            my $id = $tx->{id};
            eval {
                _api_call($scfg,'iscsi.targetextent.delete',[ $id, JSON::PP::true ]);
            };
            if ($@) {
                # In cluster environments, other nodes may have active sessions causing "in use" errors
                # This is expected - TrueNAS will clean up orphaned extents when all sessions close
                _log($scfg, 1, 'info', "[TrueNAS] _free_image_iscsi: could not delete targetextent id=$id (may be in use by other cluster nodes)");
            }
        }
        # Retry extent delete (re-query extent by disk path, narrow)
        my $retry_matches = _tn_extent_query_by_disk($scfg, $zvol_path_match) // [];
        $extent = $retry_matches->[0];
        if ($extent && defined $extent->{id}) {
            my $eid = $extent->{id};
            eval {
                _api_call($scfg,'iscsi.extent.delete',[ $eid, JSON::PP::false, JSON::PP::true ]);
            };
            if ($@) {
                _log($scfg, 1, 'info', "[TrueNAS] _free_image_iscsi: could not delete extent id=$eid (may be in use by other cluster nodes)");
            }
        }
    }

    # 4) Allow devices to settle before dataset deletion
    if ($need_force_logout) {
        if ($did_session_logout) {
            # Session was disconnected in step 3 — give it a moment before dataset deletion
            sleep(DEVICE_SETTLE_DELAY_S);
        }
        eval { run_command(['udevadm','settle'], outfunc => sub {}) };
        $need_force_logout = 1;  # signal deferred cleanup: skip session rescan
    }

    # 5) Safety check before deferring the dataset delete: verify dataset has
    # no child datasets (only snapshots allowed). Must run SYNCHRONOUSLY so we
    # can fail the free_image call cleanly if a manually-created child dataset
    # is present. Recursive deletion in the cleanup_worker would otherwise
    # destroy those children silently.
    eval {
        my $ds_info = eval { _tn_dataset_get($scfg, $full_ds) };
        if ($ds_info && $ds_info->{children}) {
            my @children = grep { $_->{type} ne 'SNAPSHOT' } @{$ds_info->{children}};
            if (@children) {
                my $child_names = join(', ', map { $_->{name} // $_->{id} } @children);
                die "Cannot use recursive deletion: dataset $full_ds has child datasets: $child_names. " .
                    "Recursive deletion would destroy these child datasets. Please remove them manually first.";
            }
        }
    };
    die $@ if $@;

    # Invalidate cache eagerly (list_images should not see the stale mapping).
    _clear_cache(_cache_host_key($scfg));

    # 6) Defer post-deletion cleanup after lock release (session rescan, self-healing, logout check)
    my $deferred_scfg = $scfg;
    my $deferred_need_force_logout = $need_force_logout;
    _defer_after_lock(sub {
        _log($deferred_scfg, 2, 'debug', "[TrueNAS] free_image_iscsi deferred: post-deletion cleanup");

        if ($deferred_need_force_logout) {
            # Just clean up stale multipath mappings without reconnecting
            if ($deferred_scfg->{tn_use_multipath}) {
                eval { PVE::Tools::run_command(['multipath','-r'], outfunc=>sub{}, errfunc=>sub{}) };
            }
            eval { PVE::Tools::run_command(['udevadm','settle'], outfunc=>sub{}) };
        } else {
            eval { PVE::Tools::run_command(['iscsiadm','-m','session','-R'], outfunc=>sub{}) };
            if ($deferred_scfg->{tn_use_multipath}) {
                eval { PVE::Tools::run_command(['multipath','-r'], outfunc=>sub{}) };
            }
            eval { PVE::Tools::run_command(['udevadm','settle'], outfunc=>sub{}) };
        }

        # Self-healing: Verify weight volume exists after deletion
        eval {
            _log($deferred_scfg, 2, 'debug', "[TrueNAS] free_image deferred: self-healing: verifying weight volume");
            _ensure_target_visible($deferred_scfg);
        };
        if ($@) {
            _log($deferred_scfg, 0, 'warning', "[TrueNAS] free_image deferred: self-healing: weight volume verification failed: $@");
        }

        # Optional: logout if no LUNs remain for this target on this node
        if ($deferred_scfg->{tn_logout_on_free}) {
            eval {
                if (_session_has_no_luns($deferred_scfg)) {
                    _logout_target_all_portals($deferred_scfg);
                }
            };
            _log($deferred_scfg, 1, 'warning', "[TrueNAS] free_image deferred: logout_on_free check failed: $@") if $@;
        }
    });

    # Return a cleanup_worker coderef for the slow pool.dataset.delete step.
    # PVE::Storage::vdisk_free (Storage.pm:~1220) forks whatever we return as
    # an 'imgdel' UPID task AFTER releasing the cfs storage lock, so the
    # calling qm destroy returns quickly. Under cluster load the dataset
    # delete can block 20-50 s waiting for other nodes to release the
    # extent's underlying zvol; keeping that on the caller's synchronous
    # path was making vm_disk_buses exceed its 180 s test-framework limit
    # (test_run6/truenas-2026-08-13, run-37 iter 1 and 2). The imgdel task
    # is idempotent -- if the next iteration's alloc_image runs before it
    # completes, the plugin's find-free-disk-name auto-increment handles
    # the residual zvol without a name collision.
    my $delete_scfg = $scfg;
    my $delete_full_ds = $full_ds;
    return sub {
        my $upid = shift;  # PVE passes the imgdel UPID
        eval {
            _delete_dataset_with_retry($delete_scfg, $delete_full_ds);
        };
        if (my $err = $@) {
            if ($err =~ /does not exist|ENOENT|InstanceNotFound/i) {
                # already gone; nothing to do
            } else {
                die "Failed to delete dataset $delete_full_ds: $err\n";
            }
        }
    };
}

# NVMe-specific deletion
sub _free_image_nvme {
    my ($class, $storeid, $scfg, $volname, $zname, $full_ds, $device_uuid) = @_;

    _log($scfg, 1, 'info', "[TrueNAS] _free_image_nvme: deleting NVMe namespace for $zname");

    # Helper to detect "in use" errors
    my $in_use = sub {
        my ($err) = @_;
        return $err =~ /in use|busy|mounted|cannot.*delete/i;
    };

    my $need_force_disconnect = 0;

    # 1) Delete NVMe namespace
    my $ok = eval {
        _nvme_delete_namespace($scfg, $zname, $full_ds);
        1;
    };
    if (!$ok) {
        my $err = $@ // '';
        if ($scfg->{tn_force_delete_on_inuse} && $in_use->($err)) {
            $need_force_disconnect = 1;
            _log($scfg, 1, 'info', "[TrueNAS] _free_image_nvme: namespace deletion blocked (in use), will retry after disconnect: $err");
        } elsif ($err !~ /does not exist|ENOENT|not found/i) {
            # Only warn if resource actually exists
            warn "warning: delete NVMe namespace failed: $err";
        }
    }

    # 2) If TrueNAS reported "in use" and force_delete_on_inuse=1, disconnect and retry
    if ($need_force_disconnect) {
        # Check if there are other active namespaces in this subsystem
        my $active_ns_count = 0;
        eval {
            my $nqn = $scfg->{tn_subsystem_nqn};
            my $subsystems = _api_call($scfg, 'nvmet.subsys.query',
                [[ ["subnqn", "=", $nqn] ]]);

            if ($subsystems && @$subsystems) {
                my $subsys_id = $subsystems->[0]{id};
                # Count all namespaces in this subsystem. Query results nest the
                # subsystem under 'subsys.id' (the 'subsys_id' form is create-only
                # input), so filter on 'subsys.id'.
                my $namespaces = _api_call($scfg, 'nvmet.namespace.query',
                    [[ ["subsys.id", "=", $subsys_id] ]]);
                $active_ns_count = $namespaces ? scalar(@$namespaces) : 0;
            }
        };

        # Only disconnect if this is the last namespace, or if we can't determine count
        # This prevents breaking multi-disk operations
        if ($active_ns_count <= 1 || $@) {
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_nvme: disconnecting NVMe subsystem to retry namespace deletion (active namespaces: $active_ns_count)");
            _nvme_disconnect($scfg);
            # Wait for NVMe disconnect to complete
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_nvme: waiting for NVMe disconnect to complete");
            sleep(DEVICE_SETTLE_DELAY_S);
            eval { run_command(['udevadm','settle'], outfunc => sub {}) };

            # Retry namespace deletion
            eval {
                _nvme_delete_namespace($scfg, $zname, $full_ds);
            };
            if ($@) {
                _log($scfg, 1, 'info', "[TrueNAS] _free_image_nvme: could not delete namespace for $zname (may be in use by other cluster nodes)");
            } else {
                # Reconnect after successful deletion
                eval { _nvme_connect($scfg) };
                if ($@) {
                    _log($scfg, 1, 'warning', "[TrueNAS] _free_image_nvme: reconnection failed after namespace deletion: $@");
                } else {
                    _log($scfg, 2, 'debug', "[TrueNAS] _free_image_nvme: successfully reconnected after namespace deletion");
                }
            }
        } else {
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_nvme: skipping disconnect - $active_ns_count other namespaces active");
        }
    }

    # 2) CRITICAL: Ensure NVMe devices are disconnected before dataset deletion
    # This fixes race condition where dataset deletion fails because devices are still active
    if ($need_force_disconnect) {
        _log($scfg, 2, 'debug', "[TrueNAS] _free_image_nvme: ensuring NVMe disconnect complete before dataset deletion");
        # Additional wait to ensure NVMe devices are fully released
        eval { run_command(['udevadm','settle'], outfunc => sub {}) };

        # Verify NVMe device cleanup (similar to iSCSI path)
        # Find device path for this UUID to verify it's disconnected
        my @nvme_device_paths;
        if ($device_uuid) {
            # Try to find the device path - it should not exist after disconnect
            my $dev_path = eval { _nvme_find_device_by_subsystem($scfg, $device_uuid) };
            if ($dev_path && ref($dev_path) eq 'HASH') {
                my $selected_device_path = _nvme_selector_selected_device_path($dev_path);
                push @nvme_device_paths, $selected_device_path if defined($selected_device_path);
            } elsif ($dev_path) {
                push @nvme_device_paths, $dev_path;
            }
        }

        if (@nvme_device_paths) {
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_nvme: verifying device cleanup for " . join(', ', @nvme_device_paths));
            _verify_devices_disconnected($scfg, \@nvme_device_paths);
        }
    }

    # 3) Safety check (sync) then defer dataset delete to cleanup_worker.
    # Same rationale as _free_image_iscsi: hoist the slow pool.dataset.delete
    # out of the caller's synchronous path so qm destroy returns quickly.
    eval {
        my $ds_info = eval { _tn_dataset_get($scfg, $full_ds) };
        if ($ds_info && $ds_info->{children}) {
            my @children = grep { $_->{type} ne 'SNAPSHOT' } @{$ds_info->{children}};
            if (@children) {
                my $child_names = join(', ', map { $_->{name} // $_->{id} } @children);
                die "Cannot use recursive deletion: dataset $full_ds has child datasets: $child_names. " .
                    "Recursive deletion would destroy these child datasets. Please remove them manually first.";
            }
        }
    };
    die $@ if $@;

    # 4) Defer udev cleanup after lock release, then reap any orphan
    # namespaces on our subsystem. Under multi-node load a namespace
    # teardown occasionally fails partway (network glitch, TN transient);
    # the plugin logs a warn but has no persistent retry ledger, so the
    # namespace lives on TN forever. Over many operations these
    # accumulate and the publication-mismatch detector in
    # _nvme_device_for_uuid starts failing every activate_volume that
    # runs against the ballooned namespace list. Reap here so orphans
    # get cleaned up at the natural rate of one-per-free without
    # slowing the caller (deferred block runs after the lock releases).
    # See _nvme_reap_orphan_namespaces for the full rationale.
    my $deferred_scfg = $scfg;
    _defer_after_lock(sub {
        _log($deferred_scfg, 2, 'debug', "[TrueNAS] free_image_nvme deferred: udev settle");
        eval { run_command(['udevadm','settle'], outfunc=>sub{}) };
        eval { _nvme_reap_orphan_namespaces($deferred_scfg) };
    });

    # Return cleanup_worker for the slow dataset delete (see _free_image_iscsi
    # for full rationale).
    my $delete_scfg = $scfg;
    my $delete_full_ds = $full_ds;
    return sub {
        my $upid = shift;
        eval {
            _delete_dataset_with_retry($delete_scfg, $delete_full_ds);
        };
        if (my $err = $@) {
            if ($err =~ /does not exist|ENOENT|InstanceNotFound/i) {
                # already gone; nothing to do
            } else {
                die "Failed to delete dataset $delete_full_ds: $err\n";
            }
        }
    };
}

# Heuristic: returns true if our target session shows no "Attached SCSI devices" with LUNs.
# Conservative: we only logout if we see a session for the IQN AND there are zero LUNs listed.
sub _session_has_no_luns {
    my ($scfg) = @_;
    my $target_iqn = $scfg->{tn_target_iqn} // return 0;

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

# ======== list_images(): report dataset capacity correctly ========
# Returns an arrayref of hashes: { volid, size, format, vmid? }
# Respects $vmid (owner filter) and $vollist (explicit include list).
sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    my $res = [];

    my $mode = $scfg->{tn_transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        return _list_images_iscsi($class, $storeid, $scfg, $vmid, $vollist, $cache);
    } elsif ($mode eq 'nvme-tcp') {
        return _list_images_nvme($class, $storeid, $scfg, $vmid, $vollist, $cache);
    }

    return $res;
}

# iSCSI-specific list_images implementation
sub _list_images_iscsi {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    my $res = [];

    # ---- fetch fresh TrueNAS state (minimal caching for target_id only) ----
    # Bypass the per-worker _tn_extents / _tn_targetextents caches: list_images
    # must reflect the current TN state, and the caches are per-pvedaemon-worker.
    # After free_image runs in worker A, worker A clears its own cache but B's
    # cache still shows the deleted extent+mapping. free_image also defers the
    # pool.dataset.delete to an imgdel task (see the "PVE::Storage::vdisk_free
    # forks whatever we return as an 'imgdel' UPID task AFTER releasing the cfs
    # storage lock" comment near line 6208), so the ground-truth dataset query
    # below can't filter the phantom out either -- the dataset is genuinely
    # still on TN when list_images runs immediately after purge. The disk_purge
    # test asserts that the purged volid disappears from storage content
    # listing; without bypassing the cache here it intermittently reappears.
    # Cost: two extra TN API calls per list_images invocation. list_images is
    # not in a hot loop -- it's called on demand from storage-content queries.
    my $extents    = _api_call($scfg, 'iscsi.extent.query', []) // [];
    my $maps       = _api_call($scfg, 'iscsi.targetextent.query', []) // [];
    my $target_id  = $cache->{target_id} //= _resolve_target_id($scfg);

    # Index extents by id for quick lookups
    my %extent_by_id = map { ($_->{id} // -1) => $_ } @$extents;

    # Optional include filter (vollist is "<storeid>:<volname>" entries)
    my %want;
    if ($vollist && ref($vollist) eq 'ARRAY' && @$vollist) {
        %want = map { $_ => 1 } @$vollist;
    }

    # PERFORMANCE OPTIMIZATION: Batch-fetch all child datasets once
    # instead of N individual API calls (fixes N+1 query pattern)
    my %dataset_cache;
    my $datasets_ok = 0;
    eval {
        # Query TrueNAS for all child datasets under our storage dataset
        # This is significantly faster than individual _tn_dataset_get() calls per volume
        my $datasets = _api_call($scfg, 'pool.dataset.query', [
            [["id", "^", "$scfg->{tn_dataset}/"]]
        ]);

        # Build hash lookup table: dataset_id => dataset_info
        if ($datasets && ref($datasets) eq 'ARRAY') {
            $datasets_ok = 1;
            for my $ds (@$datasets) {
                my $id = $ds->{id} // next;
                $dataset_cache{$id} = $ds;
            }
        }
    };
    if ($@) {
        _log($scfg, 1, 'warning', "[TrueNAS] list_images_iscsi: failed to batch-fetch datasets, falling back to individual queries: $@");
    }

    # Walk all mappings for our shared target; each mapping -> one LUN for an extent
    MAPPING: for my $tx (@$maps) {
        next MAPPING unless (($tx->{target} // -1) == $target_id);
        my $eid = $tx->{extent};
        my $e   = $extent_by_id{$eid} // next MAPPING;

        # Extract zvol name from extent's disk path (e.g., "zvol/tank/proxmox/vm-101-disk-0")
        my $disk_path = $e->{disk} // '';
        next MAPPING unless $disk_path =~ m{^zvol/(.+)$};
        my $ds_full = $1;

        # Extract zvol name from path, filtering by configured dataset
        next MAPPING unless $ds_full =~ m{^\Q$scfg->{tn_dataset}\E/(.+)$};
        my $zname = $1;

        # The targetextent/extent mapping list can be served from a stale
        # per-worker cache after a DIFFERENT worker purged the volume. The
        # pool.dataset.query above is always fresh, so treat it as ground
        # truth: if the backing zvol no longer exists, this mapping is a
        # phantom from the stale cache and must not be listed
        # (disk_purge.pl test 9). Only enforce when the batch query
        # succeeded; otherwise fall through to the per-volume fallback.
        next MAPPING if $datasets_ok && !exists $dataset_cache{$ds_full};

        # Skip ephemeral vzdump snapshot clones (issue #42). These are transient
        # devices exposed only for the duration of an LXC snapshot backup; they
        # are not Proxmox-managed volumes and must not appear in list_images.
        next MAPPING if _is_snapshot_clone_zname($zname);

        # Determine assigned LUN id
        my $lun = $tx->{lunid};
        next MAPPING if !defined $lun;

        # Owner (vmid) from our naming convention. Must match both live
        # disks (vm-<vmid>-...) and templated/base disks (base-<vmid>-...) --
        # otherwise core's find_free_diskname() never sees a template's
        # existing base-<vmid>-disk-N volumes on this storage and reuses a
        # colliding index when a second disk of the same template is moved
        # here (issue #85).
        my $owner;
        $owner = $1 if $zname =~ /^(?:vm|base)-(\d+)-/;

        # Honor $vmid filter
        if (defined $vmid) {
            # Skip if no owner detected (e.g., weight zvol) or owner doesn't match
            next MAPPING if !defined $owner || $owner != $vmid;
        }

        # Compose plugin volname + volid. Cloud-init disks (issue #84) are
        # named exactly "vm-<vmid>-cloudinit" with no metadata suffix.
        my $volname = _is_cloudinit_zname($zname) ? $zname : "vol-$zname-lun$lun";
        my $volid   = "$storeid:$volname";

        # Honor explicit include filter
        if (%want && !$want{$volid}) {
            next MAPPING;
        }

        # Ask TrueNAS for the zvol to get current size (bytes) and creation time
        # Use cached dataset if available (O(1) hash lookup), otherwise fall back to API call
        my $ds = $dataset_cache{$ds_full} // do {
            my $result = eval { _tn_dataset_get($scfg, $ds_full) };
            if ($@) {
                _log($scfg, 1, 'warning', "[TrueNAS] list_images: failed to fetch dataset $ds_full during fallback: $@");
            }
            $result // {};
        };
        my $size = _normalize_value($ds->{volsize}); # bytes (0 if missing)

        # Extract creation time
        # Try multiple possible locations for creation time
        my $ctime = 0;
        if (my $props = $ds->{properties}) {
            if (ref($props->{creation}) eq 'HASH') {
                $ctime = int($props->{creation}{rawvalue} // $props->{creation}{value} // 0);
            } elsif (defined $props->{creation} && !ref($props->{creation}) && $props->{creation} =~ /(\d{10})/) {
                $ctime = int($1);
            }
        }
        # Fallback: try direct fields on dataset
        if (!$ctime && defined $ds->{created}) {
            $ctime = int($ds->{created});
        }
        # If still no time, use current time as fallback to avoid epoch display
        $ctime = time() if !$ctime;

        # Format is always raw for block iSCSI zvols
        my %entry = (
            volid   => $volid,
            size    => $size || 0,
            format  => 'raw',
            content => 'images',
            vmid    => defined($owner) ? int($owner) : 0,
            ctime   => $ctime,
        );
        push @$res, \%entry;
    }
    return $res;
}

# NVMe-specific list_images implementation
sub _list_images_nvme {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    my $res = [];

    # Get subsystem ID
    my $nqn = $scfg->{tn_subsystem_nqn};
    my $subsystems = eval {
        _api_call($scfg, 'nvmet.subsys.query', [
            [["subnqn", "=", $nqn]]
        ]);
    };
    if ($@) {
        _log($scfg, 0, 'err', "[TrueNAS] list_images_nvme: failed to query subsystem: $@");
        return $res;
    }
    if (!$subsystems || !@$subsystems) {
        _log($scfg, 0, 'err', "[TrueNAS] list_images_nvme: subsystem $nqn not found");
        return $res;
    }
    my $subsys_id = $subsystems->[0]{id};

    # Get all namespaces for this subsystem
    # Note: Query without filter because TrueNAS API filter syntax is inconsistent
    my $namespaces = eval {
        _api_call($scfg, 'nvmet.namespace.query', [[]]);
    } // [];

    # Filter to only our subsystem
    # Note: namespace has 'subsys' field which is a hash with 'id' field
    $namespaces = [ grep {
        my $ns_subsys = $_->{subsys};
        my $ns_subsys_id = ref($ns_subsys) eq 'HASH' ? $ns_subsys->{id} : $ns_subsys;
        ($ns_subsys_id // -1) == $subsys_id
    } @$namespaces ];

    # Optional include filter
    my %want;
    if ($vollist && ref($vollist) eq 'ARRAY' && @$vollist) {
        %want = map { $_ => 1 } @$vollist;
    }

    # PERFORMANCE OPTIMIZATION: Batch-fetch all child datasets once
    # instead of N individual API calls (fixes N+1 query pattern)
    my %dataset_cache;
    eval {
        # Query TrueNAS for all child datasets under our storage dataset
        # This is significantly faster than individual _tn_dataset_get() calls per volume
        my $datasets = _api_call($scfg, 'pool.dataset.query', [
            [["id", "^", "$scfg->{tn_dataset}/"]]
        ]);

        # Build hash lookup table: dataset_id => dataset_info
        if ($datasets && ref($datasets) eq 'ARRAY') {
            for my $ds (@$datasets) {
                my $id = $ds->{id} // next;
                $dataset_cache{$id} = $ds;
            }
        }
    };
    if ($@) {
        _log($scfg, 1, 'warning', "[TrueNAS] list_images_nvme: failed to batch-fetch datasets, falling back to individual queries: $@");
    }

    # Process each namespace
    for my $ns (@$namespaces) {
        my $device_path = $ns->{device_path} // '';
        next unless $device_path =~ m{^zvol/(.+)$};
        my $ds_full = $1;  # e.g., "flash/nvme-test/vm-998-disk-0"

        # Extract zvol name from path
        next unless $ds_full =~ m{^\Q$scfg->{tn_dataset}\E/(.+)$};
        my $zname = $1;  # e.g., "vm-998-disk-0"

        # Skip ephemeral vzdump snapshot clones (issue #42). These are transient
        # devices exposed only for the duration of an LXC snapshot backup; they
        # are not Proxmox-managed volumes and must not appear in list_images.
        next if _is_snapshot_clone_zname($zname);

        # Owner (vmid) from naming convention. Must match both live disks
        # (vm-<vmid>-...) and templated/base disks (base-<vmid>-...) --
        # otherwise core's find_free_diskname() never sees a template's
        # existing base-<vmid>-disk-N volumes on this storage and reuses a
        # colliding index when a second disk of the same template is moved
        # here (issue #85).
        my $owner;
        $owner = $1 if $zname =~ /^(?:vm|base)-(\d+)-/;

        # Honor $vmid filter
        if (defined $vmid) {
            next if !defined $owner || $owner != $vmid;
        }

        # Compose volname using device_uuid. Cloud-init disks (issue #84) are
        # named exactly "vm-<vmid>-cloudinit" with no metadata suffix.
        my $device_uuid = $ns->{device_uuid} // next;
        my $volname = _is_cloudinit_zname($zname) ? $zname : "vol-$zname-ns$device_uuid";
        my $volid = "$storeid:$volname";

        # Honor explicit include filter
        if (%want && !$want{$volid}) {
            next;
        }

        # Get zvol details for size and creation time
        # Use cached dataset if available (O(1) hash lookup), otherwise fall back to API call
        my $ds = $dataset_cache{$ds_full} // do {
            my $result = eval { _tn_dataset_get($scfg, $ds_full) };
            if ($@) {
                _log($scfg, 1, 'warning', "[TrueNAS] list_images: failed to fetch dataset $ds_full during fallback: $@");
            }
            $result // {};
        };
        my $size = _normalize_value($ds->{volsize});  # bytes

        # Extract creation time
        my $ctime = 0;
        if (my $props = $ds->{properties}) {
            if (ref($props->{creation}) eq 'HASH') {
                $ctime = int($props->{creation}{rawvalue} // $props->{creation}{value} // 0);
            } elsif (defined $props->{creation} && !ref($props->{creation}) && $props->{creation} =~ /(\d{10})/) {
                $ctime = int($1);
            }
        }
        if (!$ctime && defined $ds->{created}) {
            $ctime = int($ds->{created});
        }
        $ctime = time() if !$ctime;

        # Format is always raw for NVMe zvols
        my %entry = (
            volid   => $volid,
            size    => $size || 0,
            format  => 'raw',
            content => 'images',
            vmid    => defined($owner) ? int($owner) : 0,
            ctime   => $ctime,
        );
        push @$res, \%entry;
    }

    return $res;
}

sub _status_cache_storeid {
    my ($storeid, $scfg) = @_;
    return $storeid if defined($storeid) && $storeid ne '';
    return $scfg->{storeid} if defined($scfg->{storeid}) && $scfg->{storeid} ne '';
    return _cache_host_key($scfg);
}

sub _status_capacity_cache_method {
    my ($storeid, $scfg) = @_;
    my $effective_storeid = _status_cache_storeid($storeid, $scfg);
    my $endpoint = $scfg->{tn_api_host} // 'unknown-endpoint';
    my $dataset = $scfg->{tn_dataset} // 'unknown-dataset';
    return "status-capacity:v1:$effective_storeid:$endpoint:$dataset";
}

sub _invalidate_status_capacity_cache {
    my ($storeid, $scfg) = @_;
    my $effective_storeid = _status_cache_storeid($storeid, $scfg);
    my $host_key = _cache_host_key($scfg);
    my $method = _status_capacity_cache_method($effective_storeid, $scfg);
    _invalidate_cache_key($host_key, $method);
    # Drop the on-disk stamp too so a stale value can't outlive a
    # mutation that just invalidated the in-process cache.
    _unlink_status_stamp($method);
    $_status_capacity_cache_stats{invalidate}++;
    _log($scfg, 2, 'debug', "[TrueNAS] status-cache: invalidate key=$method");
}

# ======== status(): dataset capacity ========
# total = quota (if set) else (written/used + available)
# avail = (quota - written/used) when quota present, else dataset available
# used  = dataset "written" (preferred), fallback to "used"
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    my $active = 1;
    my ($total, $avail, $used) = (0,0,0);
    my $host_key = _cache_host_key($scfg);
    my $status_method = _status_capacity_cache_method($storeid, $scfg);

    # The one path-redundancy reconciliation point. pvestatd calls status() on
    # a timer, so a portal that comes back is re-added within a poll interval,
    # while a portal that stays down costs at most one bounded connect attempt
    # per backoff window - and never on the VM start path. Detection itself is a
    # pure sysfs read. Never allowed to break capacity reporting.
    if (($scfg->{tn_transport_mode} // '') eq 'nvme-tcp') {
        eval { _nvme_connect($scfg, repair => 1) };
        _log($scfg, 2, 'debug', "[TrueNAS] status: path reconcile failed: $@") if $@;
    }

    eval {
        my $ds = _get_cached($host_key, $status_method, $STATUS_CAPACITY_TTL_S);
        if ($ds) {
            $_status_capacity_cache_stats{hit}++;
            _log($scfg, 2, 'debug', "[TrueNAS] status-cache: hit key=$status_method");
        } else {
            # Cross-process stamp check (issue #106). status() is
            # frequently called from short-lived processes (every
            # `pvesm status` is a fresh Perl interpreter), so the
            # in-process cache always misses in exactly the path that
            # PVE's cross-node upload probe hits. The on-disk stamp
            # in /run/truenas-plugin/status-<key> is shared across
            # processes and lets a fresh invocation reuse a value
            # that any process wrote within STATUS_CAPACITY_STAMP_TTL_S.
            $ds = _read_status_stamp($scfg, $status_method);
            if ($ds) {
                $_status_capacity_cache_stats{stamp_hit}++;
                _log($scfg, 2, 'debug', "[TrueNAS] status-cache: stamp-hit key=$status_method");
                # Seed the in-process cache so any second call in the
                # same process (rare, but pvestatd's own polling in
                # the resident daemon does re-enter this path) still
                # gets the fast in-process short-TTL path.
                _set_cache($host_key, $status_method, $ds);
            } else {
                $_status_capacity_cache_stats{miss}++;
                _log($scfg, 2, 'debug', "[TrueNAS] status-cache: miss key=$status_method");
                # retry_max => 2 (was 0): a single 60 s broker deadline on
                # pool.dataset.get_instance under concurrent cluster load was
                # marking storage inactive on transient slowness, which then
                # cascaded into "storage is not active" failures on unrelated
                # tests. Two retries add up to 3 x 60 s = 180 s worst case, but
                # normal path is 1 attempt and the STATUS_CAPACITY_TTL_S cache
                # keeps pvestatd from re-hitting this every poll.
                $ds = _tn_dataset_get($scfg, $scfg->{tn_dataset}, { retry_max => 2 });
                _set_cache($host_key, $status_method, $ds);
                _write_status_stamp($scfg, $status_method, $ds);

                # Pool health check on cache miss only (non-fatal — log warning if degraded)
                my $pool = _tn_pool_health($scfg);
                if ($pool && !$pool->{healthy}) {
                    my ($pool_name) = split('/', $scfg->{tn_dataset}, 2);
                    _log($scfg, 0, 'warning',
                        "[TrueNAS] status: pool '$pool_name' is not healthy (status: " .
                        ($pool->{status} // 'UNKNOWN') . ")");
                }
            }
        }

        my $quota     = _normalize_value($ds->{quota});     # bytes; 0 = no quota
        my $available = _normalize_value($ds->{available}); # bytes
        $used         = _normalize_value($ds->{written});
        $used         = _normalize_value($ds->{used}) if !$used;
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
        my $err = $@;
        _invalidate_status_capacity_cache($storeid, $scfg);

        # Distinguish between connectivity issues and actual errors
        if (_is_connection_error($err)) {
            # Network/connectivity issue - mark as inactive (temporary)
            _log($scfg, 0, 'info', "[TrueNAS] status: storage '$storeid' marked inactive (connectivity issue): $err");
            $active = 0;
        } elsif (_is_not_found_error($err)) {
            # Dataset doesn't exist - this is a configuration error
            _log($scfg, 0, 'err', "[TrueNAS] status: storage '$storeid' configuration error (dataset not found): $err");
            $active = 0;
        } elsif (_is_auth_error($err)) {
            # Authentication/permission issue - configuration error
            _log($scfg, 0, 'err', "[TrueNAS] status: storage '$storeid' authentication failed (check API key): $err");
            $active = 0;
        } else {
            # Other errors - mark inactive but log as warning for investigation
            _log($scfg, 0, 'warning', "[TrueNAS] status: storage '$storeid' status check failed: $err");
            $active = 0;
        }

        # Return zeros for all capacity metrics when inactive
        $total = 0;
        $avail = 0;
        $used  = 0;
    }
    return ($total, $avail, $used, $active);
}

# ======== Target Visibility Pre-flight Check ========
# Ensures the iSCSI target is visible and discoverable.
# If the target has no extents, it won't appear in discovery.
# This function creates a small "weight" zvol to keep the target visible.
sub _ensure_target_visible {
    my ($scfg, %opts) = @_;

    my $iqn = $scfg->{tn_target_iqn};

    # Throttle: skip entire preflight on activate_storage path if recently verified
    my $target_visible_key = _cache_host_key($scfg) . ':' . ($iqn // 'unknown-target');
    if ($opts{skip_discovery_probe}) {
        if (time() - ($_target_visible_last_ok{$target_visible_key} // 0) < $TARGET_VISIBLE_SKIP_TTL_S) {
            _log($scfg, 2, 'debug', "[TrueNAS] Pre-flight: target $iqn recently verified (" . int(time() - ($_target_visible_last_ok{$target_visible_key} // 0)) . "s ago), skipping");
            return 1;
        }
    }
    my $portal = _normalize_portal($scfg->{tn_discovery_portal});

    # Create a unique weight volume name per target
    # Extract short name from IQN (e.g., "iqn.2005-10.org.freenas.ctl:proxmox" -> "proxmox")
    my $target_suffix = $iqn;
    if ($iqn =~ /:([^:]+)$/) {
        $target_suffix = $1;
    }
    # Sanitize for use in zvol name (replace non-alphanumeric with dash)
    $target_suffix =~ s/[^a-zA-Z0-9]/-/g;
    $target_suffix =~ s/-+/-/g;  # Collapse multiple dashes
    $target_suffix =~ s/^-|-$//g;  # Remove leading/trailing dashes

    # Append an 8-char SHA1 prefix of the full IQN to guarantee uniqueness across targets
    # whose sanitized suffixes could otherwise collide (e.g. "target.foo" and "target-foo"
    # both sanitize to "target-foo"). sha1_hex is already imported via Digest::SHA.
    my $iqn_hash8          = substr(sha1_hex($iqn), 0, 8);
    my $weight_name        = "pve-weight-$target_suffix-$iqn_hash8";  # canonical (v2.0.20+)
    my $weight_name_legacy = "pve-weight-$target_suffix";             # pre-v2.0.20 deployments
    my $weight_zname       = $scfg->{tn_dataset} . '/' . $weight_name;

    # Level 1: Log pre-flight check start
    _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: checking target visibility for $iqn (weight: $weight_name)");

    # Step 1: Check if target exists on TrueNAS
    # Note: TrueNAS may store the target name as either:
    # - Just the short name (e.g., "proxmox")
    # - The full IQN (e.g., "iqn.2005-10.org.freenas.ctl:proxmox")
    # We check for both formats
    my $target_short_name = $iqn;
    if ($iqn =~ /:([^:]+)$/) {
        $target_short_name = $1;
    }

    my $target_exists = 0;
    my $target_id;
    eval {
        my $targets = _tn_targets($scfg);
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: retrieved " . scalar(@$targets) . " targets from TrueNAS");
        for my $t (@$targets) {
            my $tname = $t->{name} // 'undefined';
            _log($scfg, 2, 'debug', "[TrueNAS] Pre-flight: checking target '$tname' against '$target_short_name' or '$iqn'");
            # Match either the short name or the full IQN
            if ($tname eq $target_short_name || $tname eq $iqn) {
                $target_exists = 1;
                $target_id = $t->{id};
                last;
            }
        }
    };
    if ($@) {
        my $query_err = $@;
        # Distinguish query failure from confirmed target absence.
        # If the query itself failed (rate-limit, network, etc.), we cannot conclude
        # the target is absent — log a clear cause and propagate the original error.
        if ($query_err =~ /rate.limit|EBUSY/i) {
            _log($scfg, 0, 'err', "[TrueNAS] Pre-flight: TrueNAS API rate limited while querying targets — too many connections from this node. Wait 60s and retry.");
        } else {
            _log($scfg, 0, 'err', "[TrueNAS] Pre-flight: failed to query targets: $query_err");
        }
        die "Pre-flight: could not verify iSCSI target $iqn (query failed: $query_err)\n";
    }

    if (!$target_exists) {
        _log($scfg, 0, 'err', "[TrueNAS] Pre-flight: target $iqn does not exist on TrueNAS");
        die "iSCSI target $iqn not found on TrueNAS. Please configure the target first.\n";
    }

    _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: target $iqn exists on TrueNAS (ID: $target_id)");

    # Step 2: Proactively ensure weight zvol exists (regardless of current discoverability)
    # This prevents issues where weight gets deleted and target becomes undiscoverable
    _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: ensuring weight volume exists for target reliability");
    my $weight_exists = 0;
    my $weight_zname_legacy = $scfg->{tn_dataset} . '/' . $weight_name_legacy;
    eval {
        my $ds = _tn_dataset_get($scfg, $weight_zname);
        if ($ds) {
            $weight_exists = 1;
        } else {
            # Also check for legacy-named zvol (pre-v2.0.20 clusters upgrading in-place)
            # If found, continue using it — no need to create a duplicate hash-named zvol.
            # The legacy extent will continue to point to this zvol and work correctly.
            my $ds_legacy = _tn_dataset_get($scfg, $weight_zname_legacy);
            if ($ds_legacy) {
                $weight_exists = 1;
                _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: found legacy weight zvol '$weight_zname_legacy' (pre-v2.0.20); continuing to use it");
            }
        }
    };

    my $weight_zvol_just_created = 0;  # tracks whether we created the zvol in this run (for L1 disk-path check in step 4)
    if (!$weight_exists) {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: creating weight zvol $weight_zname (1GB)");
        eval {
            _tn_dataset_create($scfg, $weight_zname, 1048576, '64K'); # 1GB in KiB
        };
        if ($@) {
            if ($@ =~ /already exists|dataset.*exist/i) {
                # Concurrent create from another cluster node — zvol is present, continue
                _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight zvol $weight_zname already exists (concurrent create), continuing");
            } else {
                _log($scfg, 0, 'err', "[TrueNAS] Pre-flight: failed to create weight zvol: $@");
                die "Failed to create weight zvol: $@\n";
            }
        } else {
            $weight_zvol_just_created = 1;
            _invalidate_cache_key(_cache_host_key($scfg), 'extents');
            _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight zvol created");
        }
    } else {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight zvol already exists");
    }

    # Step 4: Create extent for weight zvol if it doesn't exist.
    # The weight extent is scoped to the iSCSI target (IQN), not the storage dataset.
    # Multiple storages sharing the same target share the same weight extent, so we
    # match by name only — the disk path may differ if another storage created it first.
    # Try the canonical (new) name first, then fall back to the legacy name for clusters
    # that already have a weight extent created by an older plugin version.
    my $found_weight_name;  # actual name of the weight extent on TrueNAS (may be legacy)
    eval {
        my $extents = _tn_extents($scfg);
        for my $ext (@$extents) {
            my $ext_name = $ext->{name} // '';
            if ($ext_name eq $weight_name || $ext_name eq $weight_name_legacy) {
                # If we just created the weight zvol this run, verify the extent's disk path
                # matches OUR zvol path. Two storages sharing the same IQN but using different
                # datasets can end up with the extent pointing to a dead zvol from the other
                # dataset (e.g., flash/pve vs nvme/pve). Delete the stale extent and recreate.
                if ($weight_zvol_just_created && ($ext->{disk} // '') ne "zvol/$weight_zname") {
                    _log($scfg, 1, 'info',
                        "[TrueNAS] Pre-flight: weight extent '$ext_name' points to '$ext->{disk}' " .
                        "but our zvol is at 'zvol/$weight_zname' — deleting stale extent for re-create");
                    eval { _tn_extent_delete($scfg, $ext->{id}) };
                    if ($@) {
                        _log($scfg, 0, 'warning', "[TrueNAS] Pre-flight: failed to delete stale weight extent: $@");
                        # Fall through: leave $found_weight_name unset so step 4 skips creation
                        # (safer than a partially cleaned state). Next cycle will retry.
                    }
                    # $found_weight_name stays undef — step 4 will create a correct one
                    last;
                }
                if ($ext_name eq $weight_name_legacy) {
                    _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: using legacy weight extent '$weight_name_legacy' (pre-v2.0.20 name format; will continue working)");
                }
                $found_weight_name = $ext_name;
                last;
            }
        }
    };

    if (!$found_weight_name) {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: creating extent for weight zvol");
        eval {
            _tn_extent_create($scfg, $weight_name, $weight_zname);
        };
        if ($@) {
            if ($@ =~ /Extent name must be unique/i) {
                # Another storage or concurrent process already created the weight extent
                _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight extent already exists (created concurrently or by another storage)");
                _clear_cache(_cache_host_key($scfg));
                $found_weight_name = $weight_name;  # it exists now — step 5 will fetch it fresh
            } else {
                _log($scfg, 0, 'err', "[TrueNAS] Pre-flight: failed to create weight extent: $@");
                die "Failed to create weight extent: $@\n";
            }
        } else {
            _invalidate_cache_key(_cache_host_key($scfg), 'extents');
            _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight extent created");
            $found_weight_name = $weight_name;
        }
    } else {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight extent already exists");
    }

    # Step 5: Ensure extent is mapped to THIS target (not just any target).
    # Cache is invalidated only on mutation (zvol/extent create) — if the extent
    # was deleted on TrueNAS after caching, the FK handler below recovers gracefully.
    # Use $found_weight_name (may be legacy) so that lookups stay consistent with step 4.
    my $weight_mapped = 0;
    my $weight_extent_id;
    my $stale_targetextent_id;  # mapping to wrong target left by cache-collision bug in older plugin versions
    eval {
        my $extents = _tn_extents($scfg);
        for my $ext (@$extents) {
            if (($ext->{name} // '') eq ($found_weight_name // '')) {
                $weight_extent_id = $ext->{id};
                last;
            }
        }

        if ($weight_extent_id) {
            my $targetextents = _tn_targetextents($scfg);
            for my $te (@$targetextents) {
                if ($te->{extent} == $weight_extent_id) {
                    if ($te->{target} == $target_id) {
                        # Mapped to the correct target
                        $weight_mapped = 1;
                        last;
                    } else {
                        # Mapped to wrong target — stale from cache-collision bug in older plugin versions
                        $stale_targetextent_id = $te->{id};
                        last;
                    }
                }
            }
        }
    };

    # Remove stale wrong-target mapping before creating the correct one
    my $stale_cleared = 1;
    if ($stale_targetextent_id) {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: removing stale weight extent mapping from wrong target (leftover from cache-collision bug)");
        eval { _tn_targetextent_delete($scfg, $stale_targetextent_id); };
        if ($@) {
            if ($@ =~ /InstanceNotFound|does not exist|not found/i) {
                # Mapping was already deleted (concurrent cleanup from another node, or stale cache)
                # — desired state achieved; clear cache and proceed with correct mapping create
                _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: stale mapping already gone (concurrent cleanup), continuing");
                _clear_cache(_cache_host_key($scfg));
            } else {
                _log($scfg, 0, 'warning', "[TrueNAS] Pre-flight: failed to remove stale weight mapping: $@");
                $stale_cleared = 0;  # extent still locked to wrong target — skip create attempt
            }
        } else {
            _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: stale weight mapping removed");
        }
    }

    if (!$weight_mapped && $stale_cleared && $weight_extent_id && $target_id) {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: mapping weight extent to target");
        eval {
            _tn_targetextent_create($scfg, $target_id, $weight_extent_id, 0);
        };
        if ($@) {
            if ($@ =~ /LUN ID is already being used|lunid.*already/i) {
                _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: LUN 0 in use, retrying weight mapping with auto-assigned LUN");
                eval { _tn_targetextent_create($scfg, $target_id, $weight_extent_id, undef); };
                if ($@) {
                    if ($@ =~ /FOREIGN KEY constraint failed|IntegrityError/i) {
                        # Extent ID exists in TrueNAS query but not in SQLite — configfs/DB desync.
                        # Delete the stale extent to force TrueNAS to resync; next cycle will recreate.
                        _handle_fk_stale_extent($scfg, $weight_extent_id);
                    } else {
                        _log($scfg, 0, 'warning', "[TrueNAS] Pre-flight: failed to map weight extent with auto LUN: $@");
                    }
                } else {
                    _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight extent mapped to target (auto LUN)");
                }
            } elsif ($@ =~ /FOREIGN KEY constraint failed|IntegrityError/i) {
                # Extent ID exists in TrueNAS query but not in SQLite — configfs/DB desync.
                # Delete the stale extent to force TrueNAS to resync; next cycle will recreate.
                _handle_fk_stale_extent($scfg, $weight_extent_id);
            } else {
                _log($scfg, 0, 'warning', "[TrueNAS] Pre-flight: failed to map weight extent: $@");
            }
            # Non-fatal - extent may already be mapped
        } else {
            _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight extent mapped to target");
        }
    }

    # Step 6: Verify target is now discoverable
    # Skip on status/activate path (caller passes skip_discovery_probe => 1) —
    # the weight zvol + extent + mapping are already ensured above, and
    # activate_volume handles authoritative device discovery. The deferred
    # self-healing caller retains full verification.
    if ($opts{skip_discovery_probe}) {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: target $iqn weight volume ensured (discovery probe skipped)");
        $_target_visible_last_ok{$target_visible_key} = time();
        return 1;
    }

    sleep 2; # Give TrueNAS time to update
    my $target_discoverable = 0;
    eval {
        my @discovery_output = _run_lines(['iscsiadm', '-m', 'discovery', '-t', 'sendtargets', '-p', $portal]);
        for my $line (@discovery_output) {
            if ($line =~ /\b\Q$iqn\E\b/) {
                $target_discoverable = 1;
                last;
            }
        }
    };

    if ($target_discoverable) {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: target $iqn is discoverable - weight volume ensures persistence");
        $_target_visible_last_ok{$target_visible_key} = time();
        return 1;
    } else {
        _log($scfg, 0, 'warning', "[TrueNAS] Pre-flight: target $iqn not discoverable despite weight volume - may need manual intervention");
        # Don't die - let iSCSI login handle the error with better diagnostics
        return 0;
    }
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $mode = $scfg->{tn_transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        # Run pre-flight check to ensure target is visible
        eval {
            _ensure_target_visible($scfg, skip_discovery_probe => 1);
        };
        if ($@) {
            _log($scfg, 1, 'warning', "[TrueNAS] activate_storage: target visibility pre-flight check failed for $storeid: $@");
        }
    } elsif ($mode eq 'nvme-tcp') {
        # Check nvme-cli is available
        eval {
            _nvme_check_cli();
        };
        if ($@) {
            die "NVMe/TCP storage activation failed: $@\n";
        }

        # Ensure subsystem exists and connect
        eval {
            _nvme_ensure_subsystem($scfg);
            # Initial bring-up only. With nothing live yet _nvme_connect()
            # attempts every configured portal - literal or by name - regardless
            # of mode, so this
            # still establishes full redundancy on a cold start. Repairing a
            # portal that is down is deliberately NOT done here:
            # activate_storage() is on the VM start path, and while the
            # surrounding eval keeps a dead portal from failing a start, it
            # would not keep it from slowing one. That job belongs to status().
            _nvme_connect($scfg);
        };
        if ($@) {
            _log($scfg, 1, 'warning', "[TrueNAS] activate_storage: NVMe/TCP subsystem connection failed for $storeid: $@");
        }
    }

    return 1;
}

sub deactivate_storage { return 1; }

# ======== Ephemeral snapshot device exposure (issue #42) ========
# LXC vzdump in "snapshot" mode backs up from <zvol>@<snapname> while the live
# volume keeps running. Because our volumes are raw block devices (iSCSI LUN /
# NVMe namespace), a ZFS snapshot is not directly addressable as a device. To
# give vzdump something to read, we clone the snapshot into a throwaway zvol and
# expose that clone as its own LUN / namespace for the duration of the backup,
# tearing it all down again in deactivate_volume.

# Clone <source_full>@<snapname> into the deterministic clone zvol. Idempotent:
# if the clone already exists (e.g. retried activate_volume) we treat it as
# success. Waits for the async clone job if one is returned.
sub _clone_snapshot_zvol {
    my ($scfg, $source_full, $snapname, $clone_full) = @_;
    my $source_snapshot = "$source_full\@$snapname";

    my $clone_result = eval { _tn_dataset_clone($scfg, $source_snapshot, $clone_full) };
    if (my $err = $@) {
        # Already present from a prior activate — reuse it. The rest of
        # _expose_snapshot_device is already idempotent (extent/namespace
        # lookup-before-create), so the caller can proceed against the
        # leftover clone.
        #
        # Match either the newer TN 25.10.x error string
        # (ZFSPathAlreadyExistsException, "Path already exists on the
        # pool") or the older "dataset already exists" phrasing. Missing
        # the ZFSPath variant was issue #59: a single failed vzdump run
        # left the clone in place, the next backup died at this line
        # with "already exists", and every subsequent backup failed
        # forever until an operator manually destroyed the clone and its
        # parent @vzdump snapshot on TrueNAS.
        return if $err =~ /ZFSPathAlreadyExistsException|dataset already exists|path already exists/i;
        die "Failed to clone snapshot $source_snapshot to $clone_full: $err\n";
    }

    # Wait for clone job to complete if it returned a job ID
    if (defined $clone_result && !ref($clone_result) && $clone_result =~ /^\d+$/) {
        _log($scfg, 1, 'info', "[TrueNAS] _clone_snapshot_zvol: waiting for clone job $clone_result");
        my $job_result = _wait_for_job_completion($scfg, $clone_result, 30);
        unless ($job_result->{success}) {
            die "Failed to clone snapshot $source_snapshot to $clone_full: "
                . ($job_result->{error} // 'Unknown error') . "\n";
        }
    }

    _invalidate_status_capacity_cache(undef, $scfg);
    return;
}

# Expose <zvol>@<snapname> as a temporary block device. Returns the device path.
# On any failure after the clone is created, the clone is destroyed before the
# error is re-thrown so we never leak a zvol.
#
# Note: this runs without a CFS cluster lock, by design. Proxmox calls
# activate_volume synchronously before vzdump reads the device, so the clone and
# its extent/namespace must exist by the time we return - the deferred-after-lock
# mechanism used elsewhere would complete too late. The clone name is
# deterministic per ($zname,$snapname) and all create steps are idempotent, so
# concurrent activations of the same snapshot converge on one device safely.
sub _expose_snapshot_device {
    my ($class, $scfg, $volname, $snapname) = @_;

    my (undef, $zname) = $class->parse_volname($volname);
    my $source_full = $scfg->{tn_dataset} . '/' . $zname;
    my ($clone_zname, $clone_full, $zvol_path) = _snapshot_clone_paths($scfg, $zname, $snapname);

    _log($scfg, 1, 'info', "[TrueNAS] _expose_snapshot_device: $volname\@$snapname -> $clone_zname");

    _clone_snapshot_zvol($scfg, $source_full, $snapname, $clone_full);

    my $mode = $scfg->{tn_transport_mode} // 'iscsi';

    my $dev = eval {
        if ($mode eq 'iscsi') {
            # Reuse an existing extent for this clone if present, else create one.
            _clear_cache(_cache_host_key($scfg));
            my $extent = _resolve_extent_by_disk($scfg, $clone_zname);
            my $extent_id = $extent ? $extent->{id} : undef;

            if (!defined $extent_id) {
                my $ext = _tn_extent_create(
                    $scfg, $clone_zname, $clone_full, _generate_extent_name($scfg, $clone_zname));
                $extent_id = ref($ext) eq 'HASH' ? $ext->{id} : $ext;
            }
            die "failed to create extent for snapshot clone $clone_zname\n" if !defined $extent_id;

            # Map extent to the shared target (idempotent).
            my $target_id = _resolve_target_id($scfg);
            my $tx = _tn_targetextent_create($scfg, $target_id, $extent_id, undef);

            my $lun = ref($tx) eq 'HASH' ? $tx->{lunid} : undef;
            $lun //= _current_lun_for_zname($scfg, $clone_zname);
            die "could not determine LUN for snapshot clone $clone_zname\n" if !defined $lun;

            # Bring the LUN online locally and resolve to a device node.
            _iscsi_login_all($scfg);
            _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan");
            if ($scfg->{tn_use_multipath}) {
                eval { _try_run(['multipath','-r'], "multipath reload"); };
            }
            eval { run_command(['udevadm','settle'], outfunc => sub {}) };
            return _device_for_lun($scfg, $lun);

        } elsif ($mode eq 'nvme-tcp') {
            # Reuse an existing namespace for this clone if present, else create one.
            my $nqn = $scfg->{tn_subsystem_nqn};
            my $subsystems = _api_call($scfg, 'nvmet.subsys.query', [[ ["subnqn", "=", $nqn] ]]);
            die "Failed to query NVMe subsystem $nqn\n" if !$subsystems || !@$subsystems;
            my $subsys_id = $subsystems->[0]{id};

            # alpha21: idempotent create defuses retry-storm duplicates.
            my $ns_payload = {
                subsys_id   => $subsys_id,
                device_path => $zvol_path,
                device_type => 'ZVOL',
            };
            my $ns;
            my $ns_err;
            my $max_zvol_wait_attempts = 15;
            for (my $attempt = 1; $attempt <= $max_zvol_wait_attempts; $attempt++) {
                $ns = eval { _nvme_create_namespace_idempotent($scfg, $ns_payload) };
                $ns_err = $@;
                last if !$ns_err;
                last if !_is_zvol_not_ready_error($ns_err);
                _log($scfg, 1, 'info',
                    "[TrueNAS] _expose_snapshot_device: $zvol_path not visible as block device yet " .
                    "(attempt $attempt/$max_zvol_wait_attempts), waiting for udev");
                select(undef, undef, undef, 0.2);
            }
            die $ns_err if $ns_err;
            my $device_uuid = $ns->{device_uuid}
                // die "No device_uuid returned from namespace creation\n";
            # Workaround: TrueNAS may not sync configfs after namespace create (Issue #12).
            # Ping via update() with the currently-configured allow_any_host
            # (see _nvme_allow_any_host_flag / issue #90).
            eval { _api_call_mutate($scfg, 'nvmet.subsys.update',
                [$subsys_id, { allow_any_host => _nvme_allow_any_host_flag($scfg) }]) };

            _nvme_connect($scfg);
            eval { _nvme_rescan_subsystem_controllers($scfg) };
            eval { run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {}) };
            return _nvme_device_for_uuid($scfg, $device_uuid, allow_reconnect => 1);

        } else {
            die "Unknown transport mode: $mode\n";
        }
    };
    if (my $err = $@) {
        # Expose failed after the clone was created — tear it back down so we
        # don't leak the clone (and any half-created extent/namespace).
        _log($scfg, 0, 'err', "[TrueNAS] _expose_snapshot_device: expose failed, rolling back clone: $err");
        eval { $class->_teardown_snapshot_device($scfg, $volname, $snapname) };
        die $err;
    }

    return $dev;
}

# Tear down everything _expose_snapshot_device created. Best-effort: every step
# is wrapped so a single failure cannot prevent the rest of the cleanup.
sub _teardown_snapshot_device {
    my ($class, $scfg, $volname, $snapname) = @_;

    my (undef, $zname) = $class->parse_volname($volname);
    my ($clone_zname, $clone_full) = _snapshot_clone_paths($scfg, $zname, $snapname);

    _log($scfg, 1, 'info', "[TrueNAS] _teardown_snapshot_device: tearing down $clone_zname");

    my $mode = $scfg->{tn_transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        eval {
            _clear_cache(_cache_host_key($scfg));
            my $target_id = _resolve_target_id($scfg);
            my $extent = _resolve_extent_by_disk($scfg, $clone_zname);

            # Capture local SCSI device(s) for this LUN before deleting the mapping.
            my $lun = $extent ? _current_lun_for_zname($scfg, $clone_zname) : undef;
            my @scsi_devices;
            if (defined $lun) {
                my $iqn = $scfg->{tn_target_iqn};
                my $pattern = "-iscsi-$iqn-lun-$lun";
                if (opendir(my $dh, "/dev/disk/by-path")) {
                    my @by_paths = grep { /^ip-.*\Q$pattern\E$/ } readdir($dh);
                    closedir($dh);
                    for my $bp (@by_paths) {
                        next unless $bp =~ m{^(ip-[\w.:,\[\]\-]+iscsi-[\w.:,\[\]\-]+lun-\d+)$};
                        my $full_path = "/dev/disk/by-path/$1";
                        next unless -l $full_path;
                        my $real = Cwd::abs_path($full_path);
                        push @scsi_devices, $1 if $real && $real =~ m{^/dev/(sd[a-z]{1,4})$};
                    }
                }
            }

            # Flush multipath map for this clone's WWID (derived from extent NAA).
            if ($scfg->{tn_use_multipath} && $extent && $extent->{naa} && $extent->{naa} =~ /^0x/i) {
                (my $flush_wwid = lc($extent->{naa})) =~ s/^0x/3/;
                eval { run_command(['multipath','-f',$flush_wwid], outfunc=>sub{}, errfunc=>sub{}) };
            }

            # Remove local SCSI block devices for this LUN.
            for my $dev (@scsi_devices) {
                my $delete_path = "/sys/block/$dev/device/delete";
                if (-e $delete_path && -w $delete_path) {
                    eval { if (open my $fh, '>', $delete_path) { print $fh "1"; close $fh; } };
                }
            }

            # Delete targetextent mapping (force=true), then the extent.
            if ($extent && $target_id) {
                my $tx_matches = _tn_targetextent_query_by_target_extent(
                    $scfg, $target_id, $extent->{id}) // [];
                my $tx = $tx_matches->[0];
                if ($tx && defined $tx->{id}) {
                    eval { _api_call($scfg,'iscsi.targetextent.delete',[ $tx->{id}, JSON::PP::true ]) };
                }
                eval { _api_call($scfg,'iscsi.extent.delete',[ $extent->{id}, JSON::PP::false, JSON::PP::true ]) };
            }
            _clear_cache(_cache_host_key($scfg));
        };
        warn "[TrueNAS] _teardown_snapshot_device: iSCSI cleanup failed: $@\n" if $@;

    } elsif ($mode eq 'nvme-tcp') {
        eval { _nvme_delete_namespace($scfg, $clone_zname, $clone_full) };
        warn "[TrueNAS] _teardown_snapshot_device: namespace delete failed: $@\n" if $@;
    }

    # Destroy the clone zvol (ignore if already gone).
    eval { _tn_dataset_delete($scfg, $clone_full) };
    if (my $err = $@) {
        warn "[TrueNAS] _teardown_snapshot_device: clone delete failed: $err\n"
            if $err !~ /does not exist|ENOENT|InstanceNotFound/i;
    }

    return;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    # Note: snapname is used for snapshot operations, we support snapshots via ZFS

    _log($scfg, 2, 'debug', "[TrueNAS] activate_volume: volname=$volname");

    # Snapshot mode (issue #42): expose an ephemeral clone of the snapshot as its
    # own device so LXC vzdump snapshot backups can read it. path() resolves the
    # same clone; deactivate_volume tears it down.
    if (defined($snapname) && $snapname ne '') {
        $class->_expose_snapshot_device($scfg, $volname, $snapname);
        return 1;
    }

    my $mode = $scfg->{tn_transport_mode} // 'iscsi';

    # Parse volname to extract metadata (LUN for iSCSI, UUID for NVMe)
    my (undef, $zname, $vmid, undef, undef, undef, undef, $metadata) = $class->parse_volname($volname);

    if ($mode eq 'iscsi') {
        _iscsi_login_all($scfg);
        # Force capacity re-read on existing sdX devices in case the LUN
        # we are about to activate was recycled from a previously-deleted
        # extent. Cheap, idempotent — just issues SCSI READ CAPACITY per
        # device. Without this, qemu-img on a recycled LUN sees the old
        # (smaller) capacity and refuses to write.
        eval { _iscsi_rescan_sd_capacity($scfg); };
        if ($scfg->{tn_use_multipath}) {
            run_command(['multipath','-r'], outfunc => sub {});
            eval { run_command(['udevadm','settle'], outfunc => sub {}) };
            usleep(UDEV_SETTLE_TIMEOUT_US);
        }

        # Wait for the specific LUN device to appear (up to ~20s, configurable).
        # Cloud-init volumes (issue #84) carry no embedded LUN; resolve by zname.
        my $lun = _resolve_iscsi_lun($scfg, $zname, $metadata);
        _log($scfg, 2, 'debug', "[TrueNAS] activate_volume: waiting for LUN $lun device");
        eval {
            my $dev = _device_for_lun($scfg, $lun);
            # alpha19: by-path may exist but its backing sd may be a stale
            # zero-size device from a prior LUN mapping. Verify + heal.
            _iscsi_ensure_lun_ready($scfg, $lun, $dev);
            _log($scfg, 2, 'debug', "[TrueNAS] activate_volume: device ready at $dev");
        };
        if ($@) {
            my $err = $@;
            $err = 'Unknown error while locating iSCSI device' if !defined($err) || $err eq '';
            _log($scfg, 0, 'err', "[TrueNAS] activate_volume: failed to locate device: $err");
            $err .= "\n" if $err !~ /\n\z/;
            die $err;
        }

    } elsif ($mode eq 'nvme-tcp') {
        # alpha32: LOCKHOLD instrumentation for activate_volume NVMe path.
        # This runs UNDER the VM config lock (qm start, qm clone target, etc).
        my $t0_av = Time::HiRes::time();
        my $lap_av = sub {
            my ($phase) = @_;
            _log($scfg, 0, 'info', sprintf(
                "[TrueNAS] LOCKHOLD activate_volume vmid=%s uuid=%s phase=%s elapsed=%.3fs",
                $vmid // '?', $metadata, $phase, Time::HiRes::time() - $t0_av));
        };
        $lap_av->('entry');

        _nvme_connect($scfg);
        $lap_av->('nvme_connect');

        # alpha29: force TN to re-sync nvmet configfs before we wait for the
        # target device. TrueNAS 25.10's nvmet.namespace.create returns as
        # soon as its DB row is written, BEFORE the corresponding configfs
        # entry under /sys/kernel/config/nvmet/subsystems/*/namespaces/*
        # is created. The existing subsys.update workaround (which pokes
        # TN into flushing DB->configfs) lives in _defer_after_lock inside
        # alloc_image / clone_image / expose_snapshot — those only run on
        # the CREATING node. Under a multi-node cluster where the VM is
        # started on a DIFFERENT node than the one that allocated the disk
        # (e.g. cluster_migration, live-migrate, or when the alloc/start
        # request happened to be routed to different pvedaemons), that
        # node's activate_volume runs BEFORE any subsys.update has fired
        # against TN. Kernel connects, but sees the pre-namespace configfs
        # state and never notices the new namespace. Emergency reconnect
        # in _nvme_device_for_uuid doesn't help — reconnecting still gets
        # a configfs snapshot that predates the target namespace.
        #
        # Fix: fire subsys.update ourselves here. Idempotent, cheap (one
        # API call), only runs on activate_volume. If TN already synced,
        # this is a no-op; if it hadn't, this forces it. Then the
        # subsequent _nvme_device_for_uuid loop sees the target promptly.
        eval {
            my $nqn = $scfg->{tn_subsystem_nqn};
            my $subs = _api_call($scfg, 'nvmet.subsys.query', [[["subnqn","=",$nqn]]]);
            if ($subs && @$subs) {
                my $subsys_id = $subs->[0]{id};
                # Ping subsys.update with the currently-configured
                # allow_any_host to trigger a configfs re-sync (issue #12)
                # without overwriting a user-set attribute (issue #90).
                _api_call_mutate($scfg, 'nvmet.subsys.update',
                    [$subsys_id, { allow_any_host => _nvme_allow_any_host_flag($scfg) }]);
                _log($scfg, 2, 'debug',
                    "[TrueNAS] activate_volume: pre-wait subsys.update sent for subsys $subsys_id");
            }
        };
        if ($@) {
            _log($scfg, 1, 'warning',
                "[TrueNAS] activate_volume: pre-wait subsys.update failed (non-fatal): $@");
        }
        $lap_av->('pre_wait_subsys_update');

        # Wait for the specific namespace device to appear (up to 5s).
        # Cloud-init volumes (issue #84) carry no embedded UUID; resolve by zname.
        my $device_uuid = _resolve_nvme_uuid($scfg, $zname, $metadata);
        _log($scfg, 2, 'debug', "[TrueNAS] activate_volume: waiting for device UUID $device_uuid");
        eval {
            my $dev = _nvme_device_for_uuid($scfg, $device_uuid, allow_reconnect => 1);
            _log($scfg, 2, 'debug', "[TrueNAS] activate_volume: device ready at $dev");
        };
        $lap_av->('device_for_uuid_exit');
        if ($@) {
            my $err = $@;
            $err = 'Unknown error while locating NVMe device' if !defined($err) || $err eq '';
            _log($scfg, 0, 'err', "[TrueNAS] activate_volume: failed to locate device: $err");
            $err .= "\n" if $err !~ /\n\z/;
            die $err;
        }
    }

    return 1;
}
sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    # Snapshot mode (issue #42): tear down the ephemeral clone device that
    # activate_volume exposed for vzdump snapshot backups. Best-effort.
    if (defined($snapname) && $snapname ne '') {
        eval { $class->_teardown_snapshot_device($scfg, $volname, $snapname) };
        warn "[TrueNAS] deactivate_volume snapshot teardown failed: $@\n" if $@;
    }
    return 1;
}

# Note: snapshot functions are implemented above and MUST NOT be overridden here.

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname, $name, $format) = @_;

    die "only raw format is supported\n" if defined($format) && $format ne 'raw';

    # If source is a base image and no snapname was supplied, default to
    # the immutable anchor snapshot created by create_base. ZFS cannot
    # clone a live zvol — only snapshots — so this default closes the
    # PVE qm-clone flow against a template (PVE does not always pass
    # __base__ explicitly; it relies on volume_has_feature's `base => 1`
    # advertisement to mean "this plugin knows how to clone bases").
    if (!defined($snapname) || $snapname eq '') {
        my (undef, undef, undef, undef, undef, $isBase, undef, undef) =
            $class->parse_volname($volname);
        if ($isBase) {
            $snapname = '__base__';
        } else {
            die "clone not supported without snapshot for non-base volume '$volname'\n";
        }
    }

    _log($scfg, 1, 'info', "[TrueNAS] clone_image: volname=$volname, vmid=$vmid, snapname=$snapname");

    # Dispatch by transport mode
    my $mode = $scfg->{tn_transport_mode} // 'iscsi';
    if ($mode eq 'iscsi') {
        return _clone_image_iscsi($class, $scfg, $storeid, $volname, $vmid, $snapname, $name);
    } elsif ($mode eq 'nvme-tcp') {
        return _clone_image_nvme($class, $scfg, $storeid, $volname, $vmid, $snapname, $name);
    } else {
        _log($scfg, 0, 'err', "[TrueNAS] clone_image: unknown transport mode: $mode");
        die "Unknown transport mode: $mode\n";
    }
}

# iSCSI-specific clone implementation
sub _clone_image_iscsi {
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname, $name) = @_;

    # Parse source volume information. When source is a base / template,
    # we need to return the slash-encoded volname "vol-<base>-lunB/vol-<clone>-lunM"
    # so PVE records the parent relationship in the cloned VM's .conf.
    my (undef, $source_zname, undef, undef, undef, $source_is_base, undef, $source_lun) =
        $class->parse_volname($volname);
    my $source_full = $scfg->{tn_dataset} . '/' . $source_zname;
    my $source_snapshot = $source_full . '@' . $snapname;

    _log($scfg, 2, 'debug', "[TrueNAS] _clone_image_iscsi: cloning from $source_snapshot");

    # Determine target dataset name
    my $target_zname = $name;
    if (!$target_zname) {
        $target_zname = _find_free_disk_name($scfg, $vmid);
    }

    my $target_full = $scfg->{tn_dataset} . '/' . $target_zname;

    # 1) Create ZFS clone from snapshot, with retry on "already exists" TOCTOU race
    # (two nodes picking the same free name between _find_free_disk_name and clone create)
    my $clone_result;
    {
        my $max_clone_retries = 5;
        my $clone_attempt = 0;
        while ($clone_attempt < $max_clone_retries) {
            $clone_attempt++;
            $clone_result = eval { _tn_dataset_clone($scfg, $source_snapshot, $target_full) };
            last unless $@;
            if ($@ =~ /dataset already exists/i && !$name) {
                # Race condition: name was taken between find and clone; pick a new one
                _log($scfg, 1, 'warn', "[TrueNAS] _clone_image_iscsi: $target_full already exists (attempt $clone_attempt/$max_clone_retries), retrying with new name");
                _clear_cache(_cache_host_key($scfg));
                $target_zname = _find_free_disk_name($scfg, $vmid);
                $target_full  = $scfg->{tn_dataset} . '/' . $target_zname;
                next;
            }
            die $@;
        }
        die "Failed to create clone after $max_clone_retries attempts\n" if !defined $clone_result;
    }

    # Wait for clone job to complete if it returned a job ID
    if (defined $clone_result && !ref($clone_result) && $clone_result =~ /^\d+$/) {
        _log($scfg, 1, 'info', "[TrueNAS] _clone_image_iscsi: waiting for clone job $clone_result to complete");
        my $job_result = _wait_for_job_completion($scfg, $clone_result, 30);
        unless ($job_result->{success}) {
            die "Failed to clone zvol $source_snapshot to $target_full: " . ($job_result->{error} // 'Unknown error') . "\n";
        }
        _log($scfg, 1, 'info', "[TrueNAS] _clone_image_iscsi: clone completed successfully");
    }

    _invalidate_status_capacity_cache($storeid, $scfg);

    # 2) Create iSCSI extent for the cloned zvol
    my $zvol_path = 'zvol/' . $target_full;

    # Check if extent for this zvol already exists (by disk path, narrow query)
    my $existing_matches = _tn_extent_query_by_disk($scfg, $zvol_path) // [];
    my $existing_extent = $existing_matches->[0];

    my $extent_name = _generate_extent_name($scfg, $target_zname);
    my $extent_id;

    if ($existing_extent) {
        # Extent already points to our zvol, reuse it
        $extent_id = $existing_extent->{id};
    }

    # Create extent if we don't have one yet
    if (!defined $extent_id) {
        my $extent_payload = {
            name => $extent_name,
            type => 'DISK',
            disk => $zvol_path,
            insecure_tpc => JSON::PP::true,
        };

        # pool.snapshot.clone returns as soon as ZFS finishes the clone, but
        # TN validates iscsi.extent.create by stat'ing /dev/zvol/<ds> which
        # udev may still be creating. Poll-retry on that specific validator
        # error only, up to ~3 s, so real errors still surface immediately.
        # Observed at test_run5/truenas-2026-07-22 run-01 iteration 3.
        my $ext;
        my $err;
        my $max_zvol_wait_attempts = 15;
        for (my $attempt = 1; $attempt <= $max_zvol_wait_attempts; $attempt++) {
            $ext = eval {
                _api_call_mutate(
                    $scfg,
                    'iscsi.extent.create',
                    [ $extent_payload ],
                );
            };
            $err = $@;
            last if !$err;
            last if !_is_zvol_not_ready_error($err);
            _log($scfg, 1, 'info',
                "[TrueNAS] _clone_image_iscsi: /dev/zvol/$target_full not visible yet " .
                "(attempt $attempt/$max_zvol_wait_attempts), waiting for udev");
            select(undef, undef, undef, 0.2);
        }
        # Fix B: post-hoc reuse on unique-name conflict; see the same
        # pattern in _alloc_image_iscsi. Look up by NAME (exact known
        # value); reuse only when disk field matches ours; log loudly
        # at level 0 if TN has a same-named extent with a different disk.
        if ($err && _is_extent_name_conflict_error($err)) {
            _clear_cache(_cache_host_key($scfg));
            my $by_name_matches = _tn_extent_query_by_name($scfg, $extent_name) // [];
            my $by_name = $by_name_matches->[0];
            if ($by_name) {
                if (($by_name->{disk} // '') eq $zvol_path) {
                    _log($scfg, 1, 'info',
                        "[TrueNAS] _clone_image_iscsi: name-conflict resolved by reuse " .
                        "id=$by_name->{id} name=$extent_name for $zvol_path (Fix B)");
                    $ext = $by_name;
                    $err = '';
                } elsif (_iscsi_extent_recover_stale_base_name($scfg, $by_name, $zvol_path)) {
                    # Historical create_base extent-rename gap. Stale
                    # base extent renamed; retry our create once.
                    $ext = eval {
                        _api_call_mutate($scfg, 'iscsi.extent.create', [ $extent_payload ]);
                    };
                    $err = $@;
                    if (!$err) {
                        _log($scfg, 0, 'info',
                            "[TrueNAS] _clone_image_iscsi: retry after stale-base rename succeeded for $extent_name");
                    }
                } else {
                    _log($scfg, 0, 'err',
                        "[TrueNAS] _clone_image_iscsi: extent name '$extent_name' " .
                        "already on TN (id=$by_name->{id}) with disk='" .
                        ($by_name->{disk} // '<undef>') . "', we expected disk='$zvol_path'. " .
                        "Refusing to reuse.");
                }
            } else {
                _log($scfg, 0, 'warning',
                    "[TrueNAS] _clone_image_iscsi: TN said name '$extent_name' is not unique " .
                    "but a follow-up iscsi.extent.query does not surface it.");
            }
        }
        if ($err) {
            # Cleanup: delete the zvol clone if extent creation failed. The
            # nested eval clobbers $@, so capture the original error first.
            eval { _tn_dataset_delete($scfg, $target_full) };
            die "Failed to create iSCSI extent for clone: $err\n";
        }
        $extent_id = ref($ext) eq 'HASH' ? $ext->{id} : $ext;
        # Invalidate cache so the subsequent targetextents lookup sees current state
        _clear_cache(_cache_host_key($scfg));
    }

    die "failed to create extent for clone $target_zname\n" if !defined $extent_id;

    # 3) Map extent to target via _tn_targetextent_create (handles idempotency and
    # "Extent is already in use" recovery for concurrent-node races)
    my $target_id = _resolve_target_id($scfg);

    my $lun;
    {
        my $tx = eval { _tn_targetextent_create($scfg, $target_id, $extent_id, undef) };
        if (my $err = $@) {
            # Cleanup: delete extent and zvol if mapping creation failed.
            # Nested evals clobber $@, so capture the original error first.
            eval { _api_call_mutate($scfg, 'iscsi.extent.delete', [$extent_id]) };
            eval { _tn_dataset_delete($scfg, $target_full) };
            die "Failed to create target-extent mapping for clone: $err\n";
        }

        # Extract LUN from the returned mapping object
        $lun = ref($tx) eq 'HASH' ? $tx->{lunid} : undef;

        # Invalidate cache after creating new mapping
        _clear_cache(_cache_host_key($scfg));

        # Fallback: re-fetch if create response didn't include lunid
        if (!defined $lun) {
            my $tx_matches = _tn_targetextent_query_by_target_extent($scfg, $target_id, $extent_id) // [];
            my $existing_map = $tx_matches->[0];
            $lun = $existing_map->{lunid} if $existing_map;
        }
    }

    die "could not determine assigned LUN for clone $target_zname\n" if !defined $lun;

    # 5) Return clone volume name — defer initiator rescan after lock release.
    # For a linked clone of a base, prefix with "<base>/" so PVE records
    # the parent relationship; parse_volname recognizes the slash form.
    my $clone_volname = "vol-$target_zname-lun$lun";
    if ($source_is_base) {
        $clone_volname = "vol-$source_zname-lun$source_lun/$clone_volname";
    }

    my $deferred_scfg = $scfg;
    _defer_after_lock(sub {
        _log($deferred_scfg, 2, 'debug', "[TrueNAS] clone_image_iscsi deferred: refreshing initiator view");
        eval { _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan failed"); };
        # Force capacity re-read on existing sdX devices. Required when the
        # new clone's LUN number was recycled from a previously-deleted
        # extent — iscsiadm -R won't refresh capacity on its own and
        # qemu-img convert will read the stale (smaller) size.
        eval { _iscsi_rescan_sd_capacity($deferred_scfg); };
        if ($deferred_scfg->{tn_use_multipath}) {
            eval { _try_run(['multipath','-r'], "multipath reload failed"); };
        }
        eval { run_command(['udevadm','settle'], outfunc => sub {}); };
    });

    return $clone_volname;
}

# NVMe-specific clone implementation
sub _clone_image_nvme {
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname, $name) = @_;

    # Parse source volume information. When source is a base / template,
    # return slash-encoded volname "vol-<base>-ns<base_uuid>/vol-<clone>-ns<clone_uuid>"
    # so PVE records the parent relationship in the cloned VM's .conf.
    my (undef, $source_zname, undef, undef, undef, $source_is_base, undef, $source_uuid) =
        $class->parse_volname($volname);
    my $source_full = $scfg->{tn_dataset} . '/' . $source_zname;
    my $source_snapshot = $source_full . '@' . $snapname;

    _log($scfg, 2, 'debug', "[TrueNAS] _clone_image_nvme: cloning from $source_snapshot");

    # Determine target dataset name
    my $target_zname = $name;
    if (!$target_zname) {
        $target_zname = _find_free_disk_name($scfg, $vmid);
    }

    my $target_full = $scfg->{tn_dataset} . '/' . $target_zname;

    # 1) Create ZFS clone from snapshot, with retry on "already exists" TOCTOU race
    my $clone_result;
    {
        my $max_clone_retries = 5;
        my $clone_attempt = 0;
        while ($clone_attempt < $max_clone_retries) {
            $clone_attempt++;
            $clone_result = eval { _tn_dataset_clone($scfg, $source_snapshot, $target_full) };
            last unless $@;
            if ($@ =~ /dataset already exists/i && !$name) {
                _log($scfg, 1, 'warn', "[TrueNAS] _clone_image_nvme: $target_full already exists (attempt $clone_attempt/$max_clone_retries), retrying with new name");
                _clear_cache(_cache_host_key($scfg));
                $target_zname = _find_free_disk_name($scfg, $vmid);
                $target_full  = $scfg->{tn_dataset} . '/' . $target_zname;
                next;
            }
            die $@;
        }
        die "Failed to create clone after $max_clone_retries attempts\n" if !defined $clone_result;
    }

    # Wait for clone job to complete if it returned a job ID
    if (defined $clone_result && !ref($clone_result) && $clone_result =~ /^\d+$/) {
        _log($scfg, 1, 'info', "[TrueNAS] _clone_image_nvme: waiting for clone job $clone_result to complete");
        my $job_result = _wait_for_job_completion($scfg, $clone_result, 30);
        unless ($job_result->{success}) {
            die "Failed to clone zvol $source_snapshot to $target_full: " . ($job_result->{error} // 'Unknown error') . "\n";
        }
        _log($scfg, 1, 'info', "[TrueNAS] _clone_image_nvme: clone completed successfully");
    }

    _invalidate_status_capacity_cache($storeid, $scfg);

    # Verify cloned zvol exists and get its properties
    my $cloned_ds = eval { _tn_dataset_get($scfg, $target_full) };
    if (!$cloned_ds) {
        die "Failed to verify cloned zvol $target_full: $@\n";
    }
    my $cloned_size = _normalize_value($cloned_ds->{volsize});
    _log($scfg, 1, 'info', "[TrueNAS] _clone_image_nvme: verified cloned zvol size = $cloned_size bytes");

    # 2) Create NVMe namespace for the cloned zvol
    my $nqn = $scfg->{tn_subsystem_nqn};

    # Get subsystem ID
    my $subsystems = eval {
        _api_call($scfg, 'nvmet.subsys.query', [
            [["subnqn", "=", $nqn]]
        ]);
    };
    if ($@ || !$subsystems || !@$subsystems) {
        die "Failed to query NVMe subsystem $nqn: $@\n";
    }
    my $subsys_id = $subsystems->[0]{id};

    # Create namespace (size is inherited from the zvol at device_path)
    my $ns_payload = {
        subsys_id => $subsys_id,
        device_path => "zvol/$target_full",
        device_type => 'ZVOL',
    };

    _log($scfg, 1, 'info', "[TrueNAS] _clone_image_nvme: namespace payload = " . encode_json($ns_payload));

    # alpha21: idempotent create defuses retry-storm duplicates AND fixes
    # the pre-existing gap where _clone_image_nvme had no existing-namespace
    # check (unlike _alloc_image_nvme and _expose_snapshot_device). A
    # concurrent-clone race on the same target zvol would previously leave
    # two namespaces; now the second caller reuses the first.
    my $ns;
    my $ns_err;
    my $max_zvol_wait_attempts = 15;
    for (my $attempt = 1; $attempt <= $max_zvol_wait_attempts; $attempt++) {
        $ns = eval { _nvme_create_namespace_idempotent($scfg, $ns_payload) };
        $ns_err = $@;
        last if !$ns_err;
        last if !_is_zvol_not_ready_error($ns_err);
        _log($scfg, 1, 'info',
            "[TrueNAS] _clone_image_nvme: zvol/$target_full not visible as block device yet " .
            "(attempt $attempt/$max_zvol_wait_attempts), waiting for udev");
        select(undef, undef, undef, 0.2);
    }
    if (my $err = $ns_err) {
        # Cleanup: delete the zvol clone if namespace creation failed. The
        # nested eval clobbers $@, so capture the original error first.
        eval { _tn_dataset_delete($scfg, $target_full) };
        die "Failed to create NVMe namespace for clone: $err\n";
    }

    my $device_uuid = $ns->{device_uuid} // die "No device_uuid returned from namespace creation\n";

    # 3) Return clone volume name — defer device discovery after lock release.
    # The namespace and dataset are created successfully at this point.
    # activate_volume handles authoritative device discovery before any VM uses the disk.
    # For a linked clone of a base, prefix with "<base>/" so PVE records
    # the parent relationship; parse_volname recognizes the slash form.
    my $clone_volname = "vol-$target_zname-ns$device_uuid";
    if ($source_is_base) {
        $clone_volname = "vol-$source_zname-ns$source_uuid/$clone_volname";
    }

    my $deferred_scfg = $scfg;
    my $deferred_uuid = $device_uuid;
    my $deferred_subsys_id = $subsys_id;
    _defer_after_lock(sub {
        # Workaround: TrueNAS may not sync configfs after namespace create (Issue #12).
        # Ping via update() with the currently-configured allow_any_host
        # (see _nvme_allow_any_host_flag / issue #90).
        eval { _api_call_mutate($deferred_scfg, 'nvmet.subsys.update',
            [$deferred_subsys_id, { allow_any_host => _nvme_allow_any_host_flag($deferred_scfg) }]) };
        if ($@) {
            _log($deferred_scfg, 1, 'warning', "[TrueNAS] clone_image_nvme deferred: subsystem reapply failed (non-fatal): $@");
        }

        _log($deferred_scfg, 2, 'debug', "[TrueNAS] clone_image_nvme deferred: discovering device for UUID $deferred_uuid");
        # alpha32: same LOCKHOLD instrumentation as alloc deferred.
        my $t0 = Time::HiRes::time();
        my $lap_defer_clone = sub {
            my ($phase) = @_;
            _log($deferred_scfg, 0, 'info', sprintf(
                "[TrueNAS] LOCKHOLD clone_nvme_deferred uuid=%s phase=%s elapsed=%.3fs",
                $deferred_uuid, $phase, Time::HiRes::time() - $t0));
        };
        $lap_defer_clone->('entry');
        usleep(200_000);  # 200ms initial settle
        eval { run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {}) };
        $lap_defer_clone->('udevadm_settle');
        eval { _nvme_rescan_subsystem_controllers($deferred_scfg) };
        $lap_defer_clone->('nvme_rescan');
        my $dev = eval { _nvme_device_for_uuid($deferred_scfg, $deferred_uuid, allow_reconnect => 0) };
        $lap_defer_clone->('device_for_uuid');
        if ($dev) {
            _log($deferred_scfg, 1, 'info', "[TrueNAS] clone_image_nvme deferred: device ready at $dev");
        } else {
            _log($deferred_scfg, 1, 'info', "[TrueNAS] clone_image_nvme deferred: device not yet visible (activate_volume will handle)");
        }
        $lap_defer_clone->('exit');
    });

    return $clone_volname;
}

sub copy_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname, $name, $format) = @_;

    # For our TrueNAS plugin, copy_image uses the same ZFS clone functionality as clone_image
    # This provides efficient space-efficient copying via ZFS clone technology
    # Proxmox calls this method for full clones when the 'copy' feature is supported

    return $class->clone_image($scfg, $storeid, $volname, $vmid, $snapname, $name, $format);
}

# Convert a regular VM disk volume into a base / template image.
#
# PVE invokes this once per VM disk when the user runs `qm template <vmid>`.
# Contract: rename the underlying storage object to a "base-<vmid>-..."
# form, take a base snapshot that linked clones will derive from, and
# return the new volname so PVE updates the VM config.
#
# Implementation for this plugin:
#   1. pool.dataset.rename tank/<dataset>/vm-<vmid>-disk-N
#                      -> tank/<dataset>/base-<vmid>-disk-N
#      with force=true (TN's rename rejects datasets referenced by an
#      iSCSI extent without the override; verified safe on TN 26 BETA).
#   2. iscsi.extent.update <id> {disk=>"zvol/<new_dataset>"} so the
#      extent points at the renamed zvol. naa stays stable, so PVE's
#      /dev/disk/by-id paths don't change and the kernel/multipath
#      stack doesn't need to re-discover the device.
#   3. pool.snapshot.create dataset=<new_dataset> name=__base__. This is
#      the immutable anchor every linked clone's zvol will derive from.
#
# Returns the new volname "vol-base-<vmid>-disk-N-lun<M>". The lun
# number is unchanged.
#
# Rollback: best-effort. On extent.update failure we try to rename
# back. On snapshot.create failure the rename + extent.update stand
# (the dataset is named correctly, just lacks the __base__ snap; PVE
# will retry). create_base is otherwise idempotent if a previous
# attempt left a renamed dataset without __base__.
sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ($vtype, $zname, $vmid, $basename, $basevmid, $isBase, $format, $metadata) =
        $class->parse_volname($volname);

    die "create_base: not an image volume ($vtype)\n" if $vtype ne 'images';
    die "create_base: $volname is already a base image\n" if $isBase;
    die "create_base: $volname has no derivable VMID\n" if !defined $vmid;

    my $mode = $scfg->{tn_transport_mode} // 'iscsi';
    die "create_base: unknown transport mode '$mode'\n"
        if $mode ne 'iscsi' && $mode ne 'nvme-tcp';

    # zname is e.g. "vm-<vmid>-disk-N". Compute the new base name.
    my $new_zname = $zname;
    unless ($new_zname =~ s/^vm-/base-/) {
        die "create_base: zname '$zname' does not start with 'vm-', cannot derive base name\n";
    }

    my $old_full = $scfg->{tn_dataset} . '/' . $zname;
    my $new_full = $scfg->{tn_dataset} . '/' . $new_zname;
    my $old_zvol_path = 'zvol/' . $old_full;
    my $new_zvol_path = 'zvol/' . $new_full;

    _log($scfg, 1, 'info',
        "[TrueNAS] create_base: $old_full -> $new_full (vmid=$vmid mode=$mode)");

    # Locate the transport-side share that currently references the old
    # zvol so we can rewire it after the rename.
    my ($transport_id, $rewire_method, $rewire_payload);
    my $share_label;
    if ($mode eq 'iscsi') {
        my $matches = _tn_extent_query_by_disk($scfg, $old_zvol_path) // [];
        my $extent = $matches->[0];
        die "create_base: no iSCSI extent found for $old_zvol_path\n" unless $extent;
        $transport_id   = $extent->{id};
        $rewire_method  = 'iscsi.extent.update';
        # Rename the extent alongside the disk-field rewrite. Without
        # the rename, the vm-<vmid>-disk-N-<hash> extent-name slot on
        # TN stays owned by this (now-base) extent forever; the next
        # VM allocated at the same VMID hashes to the same name and
        # gets "iscsi_extent_create.name: Extent name must be unique".
        # See _iscsi_extent_recover_stale_base_name for the recovery
        # path that unwinds historical TN state where this rename was
        # skipped.
        my $new_extent_name = _generate_extent_name($scfg, $new_zname);
        $rewire_payload = { disk => $new_zvol_path, name => $new_extent_name };
        $share_label    = "iSCSI extent id=$transport_id";
    } else {
        # nvme-tcp
        my $namespaces = _nvme_namespaces_for_device_path($scfg, $old_zvol_path) // [];
        die "create_base: no nvmet namespace found for $old_zvol_path\n" unless @$namespaces;
        $transport_id   = $namespaces->[0]->{id};
        $rewire_method  = 'nvmet.namespace.update';
        $rewire_payload = { device_path => $new_zvol_path };
        $share_label    = "nvmet namespace id=$transport_id";
    }

    # Step 1 (nvme-tcp only): disable namespace BEFORE rename. TN
    # validates the current device_path on every namespace.update,
    # including {enabled:false} — so if we rename first the validator
    # fails because the old device_path no longer exists. Disabling
    # while the old path is still valid sidesteps that. For iSCSI
    # there is no equivalent restriction; extent.update happily
    # rewrites `disk` on a live extent.
    if ($mode eq 'nvme-tcp') {
        eval {
            _api_call_mutate(
                $scfg,
                'nvmet.namespace.update',
                [ $transport_id, { enabled => JSON::PP::false } ],
            );
        };
        if ($@) {
            die "create_base: nvmet.namespace.update enabled=false (ns=$transport_id) failed: $@";
        }
    }

    # Step 2: pool.dataset.rename with force=true. force is required
    # because TN's safety check refuses to rename a dataset that an
    # iSCSI extent or nvmet namespace references; we override because
    # we are about to update the share in step 3.
    my $rename_ok = eval {
        _api_call_mutate(
            $scfg,
            'pool.dataset.rename',
            [ $old_full, { new_name => $new_full, force => JSON::PP::true } ],
        );
        1;
    };
    my $rename_err = $rename_ok ? undef : $@;

    # On-EEXIST recovery: TN returns
    #   [EEXIST] zfs.resource.rename: 'tank/<pool>/base-<vmid>-disk-N' already exists
    # when the target base dataset is left over from a prior template of the
    # same VMID that was not fully cleaned. Confirmed in Max R. Carrara's
    # test_run7 2026-08-25 3-node cluster runs at 9-54 hits per node.
    # If the leftover is an orphan (no children, no linked clones), remove
    # it and retry the rename once. Otherwise fall through to the die below
    # with the original error so the operator sees the real conflict.
    if ($rename_err && _is_dataset_already_exists_error($rename_err) &&
        _dataset_orphan_check_and_delete($scfg, $new_full)) {
        _log($scfg, 0, 'info',
            "[TrueNAS] create_base: retrying rename $old_full -> $new_full after orphan cleanup");
        $rename_ok = eval {
            _api_call_mutate(
                $scfg,
                'pool.dataset.rename',
                [ $old_full, { new_name => $new_full, force => JSON::PP::true } ],
            );
            1;
        };
        $rename_err = $rename_ok ? undef : $@;
        _log($scfg, 0, 'info',
            "[TrueNAS] create_base: rename retry after orphan cleanup succeeded for $new_full")
            if $rename_ok;
    }

    if ($rename_err) {
        if ($mode eq 'nvme-tcp') {
            # Re-enable namespace so we don't leave it disabled.
            eval {
                _api_call_mutate(
                    $scfg,
                    'nvmet.namespace.update',
                    [ $transport_id, { enabled => JSON::PP::true } ],
                );
            };
        }
        die "create_base: pool.dataset.rename '$old_full' -> '$new_full' failed: $rename_err";
    }

    # Step 3: rewire the transport share to point at the new zvol path.
    # For iSCSI this updates the extent's `disk` field. For NVMe-TCP
    # this updates the namespace's `device_path` and re-enables it.
    # In both cases the device identifier exposed to the initiator
    # (naa for iSCSI, device_uuid/nguid for NVMe) is stored separately
    # and stays stable across the rewire, so PVE's /dev/disk/by-id and
    # /dev/disk/by-path entries don't change.
    eval {
        _api_call_mutate(
            $scfg,
            $rewire_method,
            [ $transport_id, $rewire_payload ],
        );
        if ($mode eq 'nvme-tcp') {
            _api_call_mutate(
                $scfg,
                'nvmet.namespace.update',
                [ $transport_id, { enabled => JSON::PP::true } ],
            );
        }
    };
    if ($@) {
        my $err = $@;
        _log($scfg, 0, 'err',
            "[TrueNAS] create_base: $rewire_method failed; rolling back rename: $err");
        eval {
            _api_call_mutate(
                $scfg,
                'pool.dataset.rename',
                [ $new_full, { new_name => $old_full, force => JSON::PP::true } ],
            );
        };
        if ($mode eq 'nvme-tcp') {
            # After rename rollback, old device_path is valid again. Try
            # to re-enable the namespace so we don't leave it disabled.
            eval {
                _api_call_mutate(
                    $scfg,
                    'nvmet.namespace.update',
                    [ $transport_id, { enabled => JSON::PP::true } ],
                );
            };
        }
        die "create_base: $share_label rewire to $new_zvol_path failed: $err";
    }

    # Step 3: take the __base__ snapshot. This is the anchor for every
    # linked clone derived from this template.
    eval {
        _api_call_mutate(
            $scfg,
            'pool.snapshot.create',
            [ { dataset => $new_full, name => '__base__', recursive => JSON::PP::false } ],
        );
    };
    if ($@) {
        # Don't roll back the rename here; the template is functionally
        # complete from PVE's perspective (config will reference the new
        # name). Surface the failure so the operator can re-snapshot.
        die "create_base: pool.snapshot.create $new_full\@__base__ failed: $@";
    }

    _invalidate_status_capacity_cache($storeid, $scfg);
    _clear_cache(_cache_host_key($scfg));

    # Reconstruct the new volname. For iSCSI metadata is the LUN, for
    # NVMe it's the device UUID. The format is unchanged from the
    # source; only the zname portion was renamed vm- -> base-.
    my $new_volname;
    if ($mode eq 'iscsi') {
        $new_volname = "vol-${new_zname}-lun${metadata}";
    } else {
        $new_volname = "vol-${new_zname}-ns${metadata}";
    }
    _log($scfg, 1, 'info',
        "[TrueNAS] create_base: $volname -> $new_volname ($share_label, identifier unchanged)");
    return $new_volname;
}

# ======== Deferred Work & Extended Lock Timeout ========
# Override cluster_lock_storage to:
#   1) Use a longer timeout for TrueNAS operations (default 120s vs Proxmox's 10s)
#   2) Execute deferred work AFTER the CFS lock is released
#
# The deferred work pattern allows plugin methods to push local I/O operations
# (iSCSI login, device discovery polling, udev settle) to a queue that runs
# outside the cluster-wide lock. This dramatically reduces lock hold time for
# concurrent operations like bulk VM provisioning.
#
# Safety: activate_volume is the authoritative device discovery point — Proxmox
# always calls it before a VM uses a disk, so deferred discovery is best-effort.

use constant DEFAULT_LOCK_TIMEOUT => 120;  # 2 minutes default, vs Proxmox's 10 seconds

our @_deferred_work;

# Queue a code block to execute after the current CFS lock is released.
# Deferred work is best-effort: failures are logged but never fatal.
sub _defer_after_lock {
    my ($code) = @_;
    push @_deferred_work, $code;
}

sub cluster_lock_storage {
    my ($class, $storeid, $shared, $timeout, $func, @param) = @_;

    # Use configured timeout or our default (much longer than Proxmox's 10s)
    my $cfg = PVE::Storage::config();
    my $scfg = PVE::Storage::storage_config($cfg, $storeid, 1);
    my $lock_timeout = $scfg->{tn_storage_lock_timeout} // DEFAULT_LOCK_TIMEOUT;

    # Override the timeout if not explicitly provided or if it's the Proxmox default
    $timeout = $lock_timeout if !defined($timeout) || $timeout < $lock_timeout;

    # Localize @_deferred_work for re-entrancy safety (nested lock calls get their own queue)
    local @_deferred_work = ();

    my $result;
    # Bypass the CFS storage lock by default. Rationale:
    #
    # PVE::Storage::Plugin::cluster_lock_storage acquires a coarse-grained
    # cfs_lock_storage that serializes EVERY storage op across ALL nodes.
    # That's the right primitive for local storages (local, LVM) where
    # concurrent PVE-side metadata mutation would corrupt state, but for
    # a network storage like TrueNAS SCALE it's redundant and actively
    # harmful under load: TrueNAS's own middleware already serializes
    # conflicting mutations (iscsi.extent.create name-uniqueness,
    # iscsi.targetextent LUN assignment, ZFS dataset name uniqueness),
    # and the plugin's Fix 1 (alloc-time extent reuse), Fix B (post-hoc
    # name-conflict recovery), and dataset-already-exists auto-increment
    # cover any residual PVE-side race.
    #
    # cluster_test_run 2026-08-17 3-node runs measured >2 min queue wait
    # for the CFS lock while OTHER nodes' allocs held it, pushing the
    # test client's PUT past pveproxy's 60 s ceiling and 596'ing the run
    # -- even though our own body time (with the alpha7-alpha16 fixes)
    # was down to ~15-20 s. Bypass eliminates the queue entirely; nodes
    # alloc in true parallel, TN serializes internally as needed.
    #
    # Set tn_use_cluster_lock=1 in storage.cfg to force the classic
    # PVE-serialized behavior (kept for regression comparison and for
    # setups running an unusual TN configuration where its own internal
    # serialization is not trusted). Default remains bypass.
    if ($scfg->{tn_use_cluster_lock}) {
        $result = $class->SUPER::cluster_lock_storage($storeid, $shared, $timeout, $func, @param);
    } else {
        # No lock -- just run the callback directly. Errors propagate as
        # usual (die from $func bubbles up to the PVE caller).
        $result = $func->(@param);
    }

    # Execute deferred work outside the lock (best-effort, never die)
    if (@_deferred_work) {
        _log($scfg, 2, 'debug', "[TrueNAS] cluster_lock_storage: executing " . scalar(@_deferred_work) . " deferred operation(s) after lock release");
        for my $work (@_deferred_work) {
            eval { $work->() };
            if ($@) {
                _log($scfg, 1, 'warning', "[TrueNAS] cluster_lock_storage: deferred work failed (non-fatal): $@");
            }
        }
    }

    return $result;
}

1;
