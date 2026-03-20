package PVE::Storage::Custom::TrueNASPlugin;
use v5.36;
use strict;
use warnings;

# Plugin Version
our $VERSION = '2.0.10';
# Highest Proxmox storage API version this plugin is validated against.
our $TESTED_APIVER = 13;
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

# Simple cache for API results (static data)
my %API_CACHE = ();
my $CACHE_TTL = 60; # 60 seconds

# Per-process cache for _resolve_target_id results (avoids redundant API calls)
my %_target_id_cache;

# Per-process cache for preflight check results (time-based, 30s validity)
my $_preflight_last_ok = 0;

# Utility function to normalize TrueNAS API values
# Handles both scalar values and hash structures with parsed/raw fields
# Used throughout the plugin for consistent value extraction
sub _normalize_value {
    my ($v) = @_;
    return 0 if !defined $v;
    return $v if !ref($v);
    return $v->{parsed} // $v->{raw} // 0 if ref($v) eq 'HASH';
    return 0;
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
    JOB_POLL_DELAY_S          => 1,        # job status polling interval

    # Job timeouts (seconds)
    SNAPSHOT_DELETE_TIMEOUT_S        => 15,  # snapshot deletion job timeout
    DATASET_DELETE_TIMEOUT_S         => 30,  # dataset deletion job timeout (increased for reliability)
    DEVICE_CLEANUP_VERIFY_TIMEOUT_S  => 5,   # device cleanup verification timeout
    DATASET_DELETE_RETRY_COUNT       => 3,   # max retries for dataset deletion on "busy" errors
};

sub _cache_key {
    my ($storage_id, $method) = @_;
    return "${storage_id}:${method}";
}

sub _get_cached {
    my ($storage_id, $method) = @_;
    my $key = _cache_key($storage_id, $method);
    my $entry = $API_CACHE{$key};
    return unless $entry;

    # Check if cache entry is still valid
    return unless (time() - $entry->{timestamp}) < $CACHE_TTL;
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
        # Clear cache for specific storage
        delete $API_CACHE{$_} for grep { /^\Q$storage_id\E:/ } keys %API_CACHE;
    } else {
        # Clear all cache
        %API_CACHE = ();
    }
    # Also clear the target ID cache
    %_target_id_cache = ();
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
    my $debug_level = $scfg->{debug} // 0;
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

# ======== Retry logic with exponential backoff ========
sub _is_retryable_error {
    my ($error) = @_;
    return 0 if !defined $error;

    # Retry on network errors, timeouts, connection issues
    return 1 if $error =~ /timeout|timed out/i;
    return 1 if $error =~ /connection refused|connection reset|broken pipe/i;
    return 1 if $error =~ /network is unreachable|host is unreachable/i;
    return 1 if $error =~ /temporary failure|service unavailable/i;
    return 1 if $error =~ /502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout/i;
    return 1 if $error =~ /rate limit/i;
    return 1 if $error =~ /ssl.*error/i; # Transient SSL errors
    return 1 if $error =~ /connection.*failed/i;

    # Do NOT retry on authentication errors, not found, or validation errors
    return 0 if $error =~ /401 Unauthorized|403 Forbidden|404 Not Found/i;
    return 0 if $error =~ /ENOENT|InstanceNotFound|does not exist/i;
    return 0 if $error =~ /invalid.*key|authentication.*failed/i;
    return 0 if $error =~ /validation.*error|invalid.*parameter/i;
    return 0 if $error =~ /EINVAL|Invalid params/i;

    return 0; # Default: don't retry unknown errors
}

sub _retry_with_backoff {
    my ($scfg, $operation_name, $code_ref) = @_;

    my $max_retries = $scfg->{api_retry_max} // 3;
    my $initial_delay = $scfg->{api_retry_delay} // 1;

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
# Supports PVE 8.x (APIVER 11) and PVE 9.x (APIVER 13)
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
        content => [ { images => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],
    };
}

# ======== Config schema (only plugin-specific keys) ========
sub properties {
    return {
        # Transport & connection
        api_host => {
            description => "TrueNAS hostname or IP.",
            type => 'string', format => 'pve-storage-server',
        },
        api_key => {
            description => "TrueNAS user-linked API key.",
            type => 'string',
        },
        api_scheme => {
            description => "WebSocket scheme: 'wss' (secure) or 'ws' (insecure). Default: wss.",
            type => 'string', optional => 1,
        },
        api_transport => {
            description => "Deprecated legacy transport selector. Ignored; WebSocket is always used.",
            type => 'string', optional => 1,
        },
        api_port => {
            description => "TCP port (defaults: 443 for wss, 80 for ws).",
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

        # Transport mode selection
        transport_mode => {
            description => "Storage transport protocol: 'iscsi' or 'nvme-tcp'.",
            type => 'string',
            enum => ['iscsi', 'nvme-tcp'],
            optional => 1,
            default => 'iscsi',
        },

        # iSCSI target & portals
        target_iqn => {
            description => "Shared iSCSI Target IQN on TrueNAS (or target's short name) - required for iSCSI transport.",
            type => 'string',
            optional => 1,
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
            type => 'boolean',
            default => 'false',
        },
        logout_on_free => {
            description => 'After delete, logout the target if no LUNs remain for this node.',
            type => 'boolean',
            default => 'false',
        },
        use_by_path  => { type => 'boolean', optional => 1, default => 0 },
        ipv6_by_path => {
            description => "Normalize IPv6 by-path names (enable only if using IPv6 portals).",
            type => 'boolean', optional => 1, default => 0,
        },

        # Debug level
        debug => {
            description => "Debug level: 0=none (errors only), 1=light (function calls), 2=verbose (full trace)",
            type => 'integer', optional => 1, default => 0, minimum => 0, maximum => 2,
        },

        # CHAP (optional - iSCSI only)
        chap_user     => { type => 'string', optional => 1 },
        chap_password => { type => 'string', optional => 1 },

        # NVMe/TCP parameters
        subsystem_nqn => {
            description => "NVMe subsystem NQN - required for nvme-tcp transport.",
            type => 'string',
            optional => 1,
        },
        hostnqn => {
            description => "NVMe host NQN (optional, auto-generated from /etc/nvme/hostnqn if not specified).",
            type => 'string',
            optional => 1,
        },
        nvme_dhchap_secret => {
            description => "DH-HMAC-CHAP host authentication key (format: DHHC-1:01:...) - optional.",
            type => 'string',
            optional => 1,
        },
        nvme_dhchap_ctrl_secret => {
            description => "DH-HMAC-CHAP controller authentication key for bidirectional auth - optional.",
            type => 'string',
            optional => 1,
        },

        # Thin provisioning toggle (maps to TrueNAS sparse)
        tn_sparse => {
            description => "Create thin-provisioned zvols on TrueNAS (maps to 'sparse').",
            type => 'boolean', optional => 1, default => 1,
        },

        # Live snapshot support
        enable_live_snapshots => {
            description => "Enable live snapshots with VM state storage on TrueNAS.",
            type => 'boolean', optional => 1, default => 1,
        },
        # Volume chains for snapshots (enables vmstate support)
        snapshot_volume_chains => {
            description => "Use volume chains for snapshots (enables vmstate on iSCSI).",
            type => 'boolean', optional => 1, default => 1,
        },
        # vmstate storage location
        vmstate_storage => {
            description => "Storage location for vmstate: 'shared' (TrueNAS iSCSI) or 'local' (node filesystem).",
            type => 'string', optional => 1, default => 'local',
        },

        # Bulk operations for improved performance
        enable_bulk_operations => {
            description => "Enable bulk API operations for better performance (requires WebSocket transport).",
            type => 'boolean', optional => 1, default => 1,
        },

        # Retry configuration
        api_retry_max => {
            description => "Maximum number of API call retries on transient failures.",
            type => 'integer', optional => 1, default => 3,
        },
        api_retry_delay => {
            description => "Initial retry delay in seconds (doubles with each retry).",
            type => 'number', optional => 1, default => 1,
        },
        storage_lock_timeout => {
            description => "Cluster lock timeout in seconds for storage operations. " .
                          "Increase for parallel bulk provisioning. Default: 120.",
            type => 'integer', optional => 1, default => 120, minimum => 10, maximum => 600,
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
        api_host      => { fixed => 1 },
        api_key       => { fixed => 1 },
        api_scheme    => { optional => 1, fixed => 1 },
        api_transport => { optional => 1, fixed => 1 },
        api_port      => { optional => 1, fixed => 1 },
        api_insecure  => { optional => 1, fixed => 1 },
        prefer_ipv4   => { optional => 1 },

        # Placement
        dataset        => { fixed => 1 },
        zvol_blocksize => { optional => 1, fixed => 1 },

        # Transport mode
        transport_mode => { optional => 1, fixed => 1 },

        # iSCSI target & portals
        target_iqn             => { optional => 1, fixed => 1 },
        discovery_portal       => { optional => 1, fixed => 1 },
        portals                => { optional => 1 },
        force_delete_on_inuse  => { optional => 1 },
        logout_on_free         => { optional => 1 },

        # Initiator
        use_multipath => { optional => 1 },
        use_by_path   => { optional => 1 },
        ipv6_by_path  => { optional => 1 },

        # CHAP (iSCSI)
        chap_user     => { optional => 1 },
        chap_password => { optional => 1 },

        # NVMe/TCP parameters
        subsystem_nqn          => { optional => 1, fixed => 1 },
        hostnqn                => { optional => 1 },
        nvme_dhchap_secret     => { optional => 1 },
        nvme_dhchap_ctrl_secret => { optional => 1 },

        # Thin toggle
        tn_sparse => { optional => 1 },

        # Debug
        debug => { optional => 1 },

        # Live snapshots
        enable_live_snapshots => { optional => 1 },
        snapshot_volume_chains => { optional => 1 },
        vmstate_storage => { optional => 1 },

        # Bulk operations
        enable_bulk_operations => { optional => 1 },

        # Retry configuration
        api_retry_max => { optional => 1 },
        api_retry_delay => { optional => 1 },

        # Concurrency
        storage_lock_timeout => { optional => 1 },
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
    if (defined $opts->{api_transport}) {
        my $legacy_transport = lc($opts->{api_transport} // '');

        if (!defined($opts->{api_scheme}) || $opts->{api_scheme} eq '') {
            if ($legacy_transport eq 'wss') {
                $opts->{api_scheme} = 'wss';
            } else {
                # Legacy api_transport values are deprecated and should not force insecure WS.
                # Default to secure websocket behavior for compatibility.
                $opts->{api_scheme} = 'wss';
            }
        }

        if ($legacy_transport eq 'rest') {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': api_transport=rest is deprecated and unsupported. " .
                "Using WebSocket transport instead (api_scheme=$opts->{api_scheme})."
            );
        } elsif ($legacy_transport eq 'ws') {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': api_transport=ws is deprecated; " .
                "using secure websocket transport instead (api_scheme=$opts->{api_scheme})."
            );
        } else {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': api_transport is deprecated and ignored; " .
                "use api_scheme/api_port if transport tuning is needed."
            );
        }
    }

    # Validate retry configuration parameters
    if (defined $opts->{api_retry_max}) {
        die "api_retry_max must be between 0 and 10 (got $opts->{api_retry_max})\n"
            if $opts->{api_retry_max} < 0 || $opts->{api_retry_max} > 10;
    }
    if (defined $opts->{api_retry_delay}) {
        die "api_retry_delay must be between 0.1 and 60 seconds (got $opts->{api_retry_delay})\n"
            if $opts->{api_retry_delay} < 0.1 || $opts->{api_retry_delay} > 60;
    }

    # Validate dataset name follows ZFS naming conventions
    if ($opts->{dataset}) {
        # ZFS datasets: alphanumeric, underscore, hyphen, period, slash (for hierarchy)
        if ($opts->{dataset} =~ /[^a-zA-Z0-9_\-\.\/]/) {
            die "dataset name contains invalid characters: '$opts->{dataset}'\n" .
                "  Allowed characters: a-z A-Z 0-9 _ - . /\n";
        }

        # Must not start or end with slash
        if ($opts->{dataset} =~ /^\/|\/$/) {
            die "dataset name must not start or end with '/': '$opts->{dataset}'\n";
        }

        # Must not contain double slashes
        if ($opts->{dataset} =~ /\/\//) {
            die "dataset name must not contain '//': '$opts->{dataset}'\n";
        }

        # Must not be empty after trimming
        if ($opts->{dataset} eq '') {
            die "dataset name cannot be empty\n";
        }
    }

    # Warn if using insecure WebSocket
    if (defined $opts->{api_scheme} && lc($opts->{api_scheme}) eq 'ws') {
        syslog('warning',
            "[TrueNAS] Storage '$sectionId' is using insecure WebSocket (ws://). " .
            "Consider using secure WebSocket (wss://) for API communication."
        );
    }

    # Validate required fields are present
    if (!$opts->{api_host}) {
        die "api_host is required\n";
    }
    if (!$opts->{api_key}) {
        die "api_key is required\n";
    }
    if (!$opts->{dataset}) {
        die "dataset is required\n";
    }

    # Validate transport mode and transport-specific parameters
    my $mode = $opts->{transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        # iSCSI mode requires target_iqn and discovery_portal
        if (!$opts->{target_iqn}) {
            die "target_iqn is required for iSCSI transport\n";
        }
        if (!$opts->{discovery_portal}) {
            die "discovery_portal is required for iSCSI transport\n";
        }

        # Warn if NVMe-specific parameters are set in iSCSI mode
        if ($opts->{subsystem_nqn}) {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': subsystem_nqn is ignored in iSCSI mode"
            );
        }
        if ($opts->{hostnqn}) {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': hostnqn is ignored in iSCSI mode"
            );
        }

    } elsif ($mode eq 'nvme-tcp') {
        # NVMe/TCP mode requires subsystem_nqn
        if (!$opts->{subsystem_nqn}) {
            die "subsystem_nqn is required for nvme-tcp transport\n";
        }

        # Validate NQN format (basic check)
        if ($opts->{subsystem_nqn} !~ /^nqn\.\d{4}-\d{2}\./) {
            die "subsystem_nqn must follow NVMe NQN format (e.g., nqn.2005-10.org.example:identifier)\n";
        }

        # Validate hostnqn format if provided
        if ($opts->{hostnqn} && $opts->{hostnqn} !~ /^nqn\./) {
            die "hostnqn must follow NVMe NQN format\n";
        }

        # Warn if iSCSI-specific parameters are set in NVMe mode
        if ($opts->{target_iqn}) {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': target_iqn is ignored in nvme-tcp mode"
            );
        }
        if ($opts->{chap_user} || $opts->{chap_password}) {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': CHAP parameters are ignored in nvme-tcp mode (use nvme_dhchap_secret instead)"
            );
        }
        if ($opts->{use_by_path}) {
            syslog('warning',
                "[TrueNAS] Storage '$sectionId': use_by_path is ignored in nvme-tcp mode (UUID paths used)"
            );
        }

    } else {
        die "Invalid transport_mode '$mode': must be 'iscsi' or 'nvme-tcp'\n";
    }

    return $opts;
}

# ======== DNS/IPv4 helper ========
sub _host_ipv4($host) {
    return $host if $host =~ /^\d+\.\d+\.\d+\.\d+$/; # already IPv4 literal
    my @ent = Socket::gethostbyname($host); # A-record lookup
    if (@ent && defined $ent[4]) {
        my $ip = inet_ntoa($ent[4]);
        return $ip if $ip;
    }
    return $host; # fallback (could be IPv6 literal or DNS)
}

# ======== WebSocket JSON-RPC client ========
# Connect to ws(s)://<host>/api/current; auth via auth.login_with_api_key.
sub _ws_defaults($scfg) {
    my $scheme = $scfg->{api_scheme};
    if (!$scheme) { $scheme = 'wss'; }
    elsif ($scheme =~ /^https$/i) { $scheme = 'wss'; }
    elsif ($scheme =~ /^http$/i)  { $scheme = 'ws';  }
    my $port = $scfg->{api_port} // (($scheme eq 'wss') ? 443 : 80);
    return ($scheme, $port);
}
sub _ws_open($scfg) {
    my ($scheme, $port) = _ws_defaults($scfg);
    my $host = $scfg->{api_host};
    my $peer = ($scfg->{prefer_ipv4} // 1) ? _host_ipv4($host) : $host;
    my $path = '/api/current';

    # Add small delay to avoid rate limiting
    usleep(DEVICE_READY_TIMEOUT_US); # 100ms delay

    my $sock;
    if ($scheme eq 'wss') {
        $sock = IO::Socket::SSL->new(
            PeerHost => $peer,
            PeerPort => $port,
            SSL_verify_mode => $scfg->{api_insecure} ? 0x00 : 0x02,
            SSL_hostname    => $host,
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
        params  => [ $scfg->{api_key} ],
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
            return undef;  # socket not readable within 30s — connection stale
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

# ======== Persistent WebSocket Connection Management ========
my %_ws_connections; # Global connection cache
my $_ws_creator_pid = $$; # Track PID to detect fork

sub _ws_connection_key($scfg) {
    # Create a unique key for this storage configuration
    my $host = $scfg->{api_host};
    my $key = $scfg->{api_key};
    return "$host:$key";
}

sub _ws_get_persistent($scfg) {
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

    # Test if existing connection is still alive
    if ($conn && $conn->{sock}) {
        # Quick connection test - try to send a ping
        eval {
            # Test with a lightweight method call
            _ws_rpc($conn, {
                jsonrpc => "2.0", id => 999999, method => "core.ping", params => [],
            });
        };
        if ($@) {
            # Connection is dead, close socket properly before removing from cache
            # This prevents "free unreferenced scalar" errors from IO::Socket::SSL
            if ($conn && $conn->{sock}) {
                eval { $conn->{sock}->close(); };
            }
            delete $_ws_connections{$key};
            $conn = undef;
        }
    }

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

# ======== Ephemeral WebSocket Connection for Write Operations ========
# Creates a fresh, isolated connection for write operations to avoid
# race conditions when multiple processes share persistent connections.
# Each write operation gets its own connection that is closed after use.

sub _ws_open_ephemeral($scfg) {
    # Create a new WebSocket connection that will NOT be cached
    # This is identical to _ws_open() but the caller is responsible
    # for closing it after use via _ws_close_ephemeral()
    return _ws_open($scfg);
}

sub _ws_close_ephemeral($conn, $scfg = undef) {
    # Close an ephemeral connection after use
    return unless $conn && $conn->{sock};
    eval {
        # Send minimal WebSocket close frame per RFC 6455 (FIN + close opcode, no payload)
        my $close_frame = pack('CC', 0x88, 0x00);
        $conn->{sock}->syswrite($close_frame);
        $conn->{sock}->close();
    };
    if ($@ && $scfg) {
        _log($scfg, 2, 'debug', "[TrueNAS] Failed to close ephemeral connection cleanly: $@");
    }
    # Ignore errors during close - connection may already be dead
}

# ======== Bulk Operations Helper ========
sub _api_bulk_call($scfg, $method_name, $params_array, $description = undef) {
    # Use core.bulk to batch multiple calls of the same method
    # $params_array should be an array of parameter arrays

    # Check if bulk operations are enabled (default: enabled)
    my $bulk_enabled = $scfg->{enable_bulk_operations} // 1;
    if (!$bulk_enabled) {
        die "Bulk operations are disabled in storage configuration";
    }

    # Bulk operations are always write operations, use ephemeral connection
    return _api_call_write($scfg, 'core.bulk', [$method_name, $params_array, $description],
        sub { die "Bulk operations require WebSocket transport (TrueNAS 25.10+ only)\n"; });
}

# Bulk snapshot deletion helper
sub _bulk_snapshot_delete($scfg, $snapshot_list) {
    return [] if !$snapshot_list || !@$snapshot_list;

    # Prepare parameter arrays for each snapshot deletion
    my @params_array = map { [$_] } @$snapshot_list;

    my $results = _api_bulk_call($scfg, 'zfs.snapshot.delete', \@params_array,
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
    my $bulk_enabled = $scfg->{enable_bulk_operations} // 1;

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
            my $full_ds = $scfg->{dataset} . '/' . $dataset;
            my $id = URI::Escape::uri_escape($full_ds);
            my $payload = { recursive => JSON::PP::true, force => JSON::PP::true };
            _api_call($scfg, 'pool.dataset.delete', [$full_ds, $payload]);
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
    my $full = $scfg->{dataset} . '/' . $zname;

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
            $job_status = _api_call($scfg, 'core.call', ['core.get_jobs', [{ id => int($job_id) }]]);
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
            my $result = _api_call_write($scfg,'pool.dataset.delete',[ $full_ds, $payload ]);

            my $job_result = _handle_api_result_with_job_support($scfg, $result, "dataset deletion for $full_ds", DATASET_DELETE_TIMEOUT_S);
            if (!$job_result->{success}) {
                die $job_result->{error};
            }
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
#   - use_ephemeral: if true, use an ephemeral connection (for write operations)
sub _api_call($scfg, $ws_method, $ws_params, $opts = undef) {
    my $use_ephemeral = $opts && $opts->{use_ephemeral};

    # Level 2: Verbose - log all API calls with parameters
    my $conn_type = $use_ephemeral ? 'ephemeral' : 'persistent';
    if ($ws_params && ref($ws_params) eq 'ARRAY' && @$ws_params) {
        _log($scfg, 2, 'debug', "[TrueNAS] _api_call: method=$ws_method, conn=$conn_type, params=" . encode_json($ws_params));
    } else {
        _log($scfg, 2, 'debug', "[TrueNAS] _api_call: method=$ws_method, conn=$conn_type");
    }

    if ($use_ephemeral) {
        # Use ephemeral connection for write operations to avoid race conditions
        # Each write gets its own isolated connection
        return _retry_with_backoff($scfg, "WS $ws_method", sub {
            my $conn = _ws_open_ephemeral($scfg);
            my $res;
            eval {
                $res = _ws_rpc($conn, {
                    jsonrpc => "2.0", id => $conn->{next_id}++, method => $ws_method, params => $ws_params // [],
                });
            };
            my $err = $@;
            # Always close ephemeral connection, even on error
            _ws_close_ephemeral($conn);
            die $err if $err;

            # Level 2: Verbose - log API response
            _log($scfg, 2, 'debug', "[TrueNAS] _api_call: response from $ws_method: " . (ref($res) ? encode_json($res) : ($res // 'undef')));

            return $res;
        });
    } else {
        # Use persistent connection for read operations (original behavior)
        return _retry_with_backoff($scfg, "WS $ws_method", sub {
            my $conn = _ws_get_persistent($scfg);
            my $res = _ws_rpc($conn, {
                jsonrpc => "2.0", id => $conn->{next_id}++, method => $ws_method, params => $ws_params // [],
            });

            # Level 2: Verbose - log API response
            _log($scfg, 2, 'debug', "[TrueNAS] _api_call: response from $ws_method: " . (ref($res) ? encode_json($res) : ($res // 'undef')));

            return $res;
        });
    }
}

# Convenience wrapper for write operations that need ephemeral connections
# Use this for create, update, delete operations to avoid WebSocket race conditions
sub _api_call_write($scfg, $ws_method, $ws_params) {
    return _api_call($scfg, $ws_method, $ws_params, { use_ephemeral => 1 });
}

# ======== TrueNAS API ops (WebSocket) ========
sub _tn_get_target($scfg) {
    return _api_call($scfg, 'iscsi.target.query', []);
}
sub _tn_targetextents($scfg) {
    my $storage_id = $scfg->{storeid} || 'unknown';

    # Try cache first (but with shorter TTL since mappings change more frequently)
    my $cached = _get_cached($storage_id, 'targetextents');
    return $cached if $cached;

    # Cache miss - fetch from API
    my $res = _api_call($scfg, 'iscsi.targetextent.query', []);

    # Cache with shorter TTL for dynamic data
    return _set_cache($storage_id, 'targetextents', $res);
}
sub _tn_extents($scfg) {
    my $storage_id = $scfg->{storeid} || 'unknown';

    # Try cache first
    my $cached = _get_cached($storage_id, 'extents');
    return $cached if $cached;

    # Cache miss - fetch from API
    my $res = _api_call($scfg, 'iscsi.extent.query', []);

    # Cache and return
    return _set_cache($storage_id, 'extents', $res);
}

sub _tn_snapshots($scfg) {
    return _api_call($scfg, 'zfs.snapshot.query', []);
}

sub _tn_global($scfg) {
    return _api_call($scfg, 'iscsi.global.config', []);
}

# PVE passes size in KiB; TrueNAS expects bytes (volsize) and supports 'sparse'
sub _tn_dataset_create($scfg, $full, $size_kib, $blocksize) {
    my $bytes = int($size_kib) * 1024;
    my $payload = {
        name   => $full,
        type   => 'VOLUME',
        volsize=> $bytes,
        sparse => ($scfg->{tn_sparse} // 1) ? JSON::PP::true : JSON::PP::false,
    };
    # Normalize blocksize to uppercase for TrueNAS 25.10+ compatibility
    if ($blocksize) {
        $payload->{volblocksize} = _normalize_blocksize($blocksize);
    }
    return _api_call_write($scfg, 'pool.dataset.create', [ $payload ]);
}
sub _tn_dataset_delete($scfg, $full) {
    my $id = uri_escape($full);

    _log($scfg, 1, 'info', "[TrueNAS] _tn_dataset_delete: deleting $full (recursive=true)");
    my $result = _api_call_write($scfg, 'pool.dataset.delete', [ $full, { recursive => JSON::PP::true } ]);

    # Handle potential async job for dataset deletion
    my $job_result = _handle_api_result_with_job_support($scfg, $result, "dataset deletion (helper) for $full", 60);
    if (!$job_result->{success}) {
        die $job_result->{error};
    }

    _log($scfg, 1, 'info', "[TrueNAS] _tn_dataset_delete: deleted $full");
    return $job_result->{result};
}
sub _tn_dataset_get($scfg, $full) {
    return _api_call($scfg, 'pool.dataset.get_instance', [ $full ]);
}
sub _tn_dataset_resize($scfg, $full, $new_bytes) {
    my $payload = { volsize => int($new_bytes) }; # grow-only
    return _api_call_write($scfg, 'pool.dataset.update', [ $full, $payload ]);
}
sub _tn_dataset_clone($scfg, $source_snapshot, $target_dataset) {
    # Clone a ZFS snapshot to create a new dataset
    # source_snapshot: pool/dataset@snapshot
    # target_dataset: pool/new-dataset
    my $payload = {
        snapshot => $source_snapshot,
        dataset_dst => $target_dataset,
    };
    return _api_call_write($scfg, 'zfs.snapshot.clone', [ $payload ]);
}

# ---- WebSocket-only snapshot rollback (TrueNAS 25.10+) ----
sub _tn_snapshot_rollback($scfg, $snap_full, $force_bool, $recursive_bool) {
    my $FORCE     = $force_bool     ? JSON::PP::true  : JSON::PP::false;
    my $RECURSIVE = $recursive_bool ? JSON::PP::true  : JSON::PP::false;

    # WebSocket-only for snapshot rollback (requires TrueNAS 25.10+)
    # TrueNAS 25.10+ uses: zfs.snapshot.rollback(snapshot_name, {force: bool, recursive: bool})
    my $attempt_rollback = sub {
        my $conn = _ws_open_ephemeral($scfg);
        my $result;
        eval {
            $result = _ws_rpc($conn, {
                jsonrpc => "2.0", id => 1,
                method  => "zfs.snapshot.rollback",
                params  => [ $snap_full, { force => $FORCE, recursive => $RECURSIVE } ],
            });
        };
        my $err = $@;
        _ws_close_ephemeral($conn);
        die $err if $err;
        return $result;
    };

    eval { $attempt_rollback->(); };
    if ($@) {
        my $err = $@;
        # Check if it's a ZFS constraint error (newer snapshots exist)
        if ($err =~ /more recent snapshots or bookmarks exist/ && $err =~ /use '-r' to force deletion/) {
            # If force=1 but recursive=0, and newer snapshots exist, we need recursive=1
            if ($force_bool && !$recursive_bool) {
                # Retry with recursive=1 to delete newer snapshots
                eval {
                    my $conn = _ws_open_ephemeral($scfg);
                    my $result;
                    eval {
                        $result = _ws_rpc($conn, {
                            jsonrpc => "2.0", id => 2,
                            method  => "zfs.snapshot.rollback",
                            params  => [ $snap_full, { force => $FORCE, recursive => JSON::PP::true } ],
                        });
                    };
                    my $inner_err = $@;
                    _ws_close_ephemeral($conn);
                    die $inner_err if $inner_err;
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
        clone => { snap => 1, current => 1 },  # Support cloning from snapshots and current volumes
        copy => { snap => 1, current => 1 },   # Support copying from snapshots and current volumes
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
    my $full = $scfg->{dataset} . '/' . $zname;

    _log($scfg, 1, 'info', "[TrueNAS] volume_resize: volname=$volname, target_size=$new_size_bytes");

    # Fetch current zvol info from TrueNAS
    my $ds = _tn_dataset_get($scfg, $full) // {};
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
    my $pds = _tn_dataset_get($scfg, $scfg->{dataset}) // {};
    my $avail_bytes = _normalize_value($pds->{available}); # parent dataset/pool available
    my $max_grow    = $avail_bytes ? int($avail_bytes * 0.80) : 0;
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

    # Initiator-side rescan so Linux sees the new size (transport-specific)
    my $mode = $scfg->{transport_mode} // 'iscsi';
    if ($mode eq 'iscsi') {
        _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan failed");
        if ($scfg->{use_multipath}) {
            _try_run(['multipath','-r'], "multipath map reload failed");
        }
    } elsif ($mode eq 'nvme-tcp') {
        # NVMe namespace size updates automatically when zvol is resized
        # Trigger device rescan to ensure kernel sees updated size
        # Find NVMe controllers connected to our subsystem and rescan them
        my $nqn = $scfg->{subsystem_nqn};
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
    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{dataset} . '/' . $zname; # pool/dataset/.../vm-<id>-disk-<n>
    my $snap_full = $full . '@' . $snapname;    # full snapshot name for logging

    _log($scfg, 1, 'info', "[TrueNAS] volume_snapshot: creating $snap_full");

    # Create ZFS snapshot for the disk
    my $payload = { dataset => $full, name => $snapname, recursive => JSON::PP::false };
    my $result = _api_call_write(
        $scfg, 'zfs.snapshot.create', [ $payload ],
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
}

# Delete a ZFS snapshot on the zvol.
# Note: vmstate cleanup is handled automatically by Proxmox
sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{dataset} . '/' . $zname; # pool/dataset/.../vm-<id>-disk-<n>
    my $snap_full = $full . '@' . $snapname;    # full snapshot name
    my $id = URI::Escape::uri_escape($snap_full); # '@' must be URL-encoded in path

    _log($scfg, 1, 'info', "[TrueNAS] volume_snapshot_delete: deleting $snap_full");

    my $result = _api_call_write(
        $scfg, 'zfs.snapshot.delete', [ $snap_full ],
    );

    # Handle potential async job for snapshot deletion
    my $job_result = _handle_api_result_with_job_support($scfg, $result, "individual snapshot deletion for $snap_full", SNAPSHOT_DELETE_TIMEOUT_S);
    if (!$job_result->{success}) {
        die $job_result->{error};
    }

    _log($scfg, 1, 'info', "[TrueNAS] volume_snapshot_delete: deleted $snap_full");
    return undef;
}

# Roll back the zvol to a specific ZFS snapshot and rescan iSCSI/multipath.
# Now supports restoring VM state for live snapshots.
sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    my (undef, $zname, $vmid) = $class->parse_volname($volname);
    my $full = $scfg->{dataset} . '/' . $zname;
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

    # WS-first rollback with safe fallbacks; allow non-latest rollback (destroy newer snaps)
    _tn_snapshot_rollback($scfg, $snap_full, 1, 0);

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

    # Refresh initiator view
    eval { PVE::Tools::run_command(['iscsiadm','-m','session','-R'], outfunc=>sub{}) };
    if ($scfg->{use_multipath}) {
        eval { PVE::Tools::run_command(['multipath','-r'], outfunc=>sub{}) };
    }
    eval { PVE::Tools::run_command(['udevadm','settle'], outfunc=>sub{}) };

    _log($scfg, 1, 'info', "[TrueNAS] volume_snapshot_rollback: rolled back to $snap_full");
    return undef;
}

# Return a hash describing available snapshots for this volume.
# Shape: { <snapname> => { id => <snapname>, timestamp => <epoch> }, ... }
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;
    my (undef, $zname) = $class->parse_volname($volname);
    my $full = $scfg->{dataset} . '/' . $zname;

    _log($scfg, 2, 'debug', "[TrueNAS] volume_snapshot_info: querying snapshots for $full");

    my $list = _api_call($scfg, 'zfs.snapshot.query', []) // [];

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

# List TrueNAS iSCSI targets (array of hashes; each has at least {id, name, ...}).
sub _tn_targets {
    my ($scfg) = @_;
    my $list = _api_call($scfg, 'iscsi.target.query', []);
    return $list // [];
}

# Find the first free disk name for a VM using a single batch query.
# Replaces the naive loop that called _tn_dataset_get per candidate name.
sub _find_free_disk_name {
    my ($scfg, $vmid) = @_;
    my $dataset = $scfg->{dataset};
    my $prefix = "vm-$vmid-disk-";

    # Single query: fetch all children of the parent dataset matching our VM's prefix
    # Escape regex special chars in dataset path (TrueNAS uses Python regex)
    (my $dataset_escaped = $dataset) =~ s/([.+*?^()\[\]{}|\\])/\\$1/g;
    my $children = eval {
        _api_call($scfg, 'pool.dataset.query', [
            [["pool", "=", (split('/', $dataset))[0]], ["name", "~", "^${dataset_escaped}/${prefix}"]]
        ]);
    };
    my %existing;
    if ($children && ref($children) eq 'ARRAY') {
        %existing = map { $_->{id} => 1 } @$children;
    }

    for (my $n = 0; $n < 1000; $n++) {
        my $candidate = "${prefix}$n";
        if (!$existing{"$dataset/$candidate"}) {
            return $candidate;
        }
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

    my $full_path = $scfg->{dataset} . "/" . $zname;
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

# Resolve an iSCSI extent by its disk (zvol) path instead of by name.
# Returns the first matching extent hashref, or undef if none found.
sub _resolve_extent_by_disk($scfg, $zname) {
    my $zvol_path = "zvol/" . $scfg->{dataset} . "/" . $zname;
    my $extents = _tn_extents($scfg) // [];
    my ($match) = grep { ($_->{disk} // '') eq $zvol_path } @$extents;
    return $match;
}

sub _tn_extent_create($scfg, $zname, $full, $extent_name=undef) {
    my $payload = {
        name => $extent_name // $zname, type => 'DISK', disk => "zvol/$full", insecure_tpc => JSON::PP::true,
    };
    my $result = _api_call_write($scfg, 'iscsi.extent.create', [ $payload ]);
    # Invalidate cache since extents list has changed
    _clear_cache($scfg->{storeid}) if $result;
    return $result;
}
sub _tn_extent_delete($scfg, $extent_id) {
    my $result = _api_call_write($scfg, 'iscsi.extent.delete', [ $extent_id ]);
    # Invalidate cache since extents list has changed
    _clear_cache($scfg->{storeid}) if $result;
    return $result;
}
sub _tn_targetextent_create($scfg, $target_id, $extent_id, $lun) {
    # Check if this mapping already exists
    my $maps = _tn_targetextents($scfg) // [];
    my ($existing_map) = grep {
        (($_->{target}//-1) == $target_id) && (($_->{extent}//-1) == $extent_id)
    } @$maps;

    if ($existing_map) {
        # Mapping already exists - idempotent behavior
        _log($scfg, 2, 'debug', "[TrueNAS] Target-extent mapping already exists for extent_id=$extent_id (LUN $existing_map->{lunid})");
        return $existing_map;
    }

    # Mapping doesn't exist, create it
    my $payload = { target => $target_id, extent => $extent_id };
    $payload->{lunid} = $lun if defined $lun;
    my $result = _api_call_write($scfg, 'iscsi.targetextent.create', [ $payload ]);
    # Invalidate cache since targetextents list has changed
    _clear_cache($scfg->{storeid}) if $result;
    return $result;
}
sub _tn_targetextent_delete($scfg, $tx_id) {
    my $result = _api_call_write($scfg, 'iscsi.targetextent.delete', [ $tx_id ]);
    # Invalidate cache since targetextents list has changed
    _clear_cache($scfg->{storeid}) if $result;
    return $result;
}
sub _current_lun_for_zname($scfg, $zname) {
    my $extents = _tn_extents($scfg) // [];
    my $zvol_path = "zvol/$scfg->{dataset}/$zname";
    my ($extent) = grep { ($_->{disk} // '') eq $zvol_path } @$extents;
    return undef if !$extent || !defined $extent->{id};
    my $target_id = _resolve_target_id($scfg);
    my $maps = _tn_targetextents($scfg) // [];
    my ($tx) = grep {
        (($_->{target} // -1) == $target_id)
        && (($_->{extent} // -1) == $extent->{id})
    } @$maps;
    return defined($tx) ? $tx->{lunid} : undef;
}

# Pre-flight validation checks before volume allocation
# Returns arrayref of error messages (empty if all checks pass)
# Results are cached for 30 seconds to avoid redundant checks during multi-disk creation.
sub _preflight_check_alloc {
    my ($scfg, $size_bytes) = @_;

    # Skip redundant preflight checks when allocating multiple disks rapidly
    if (time() - $_preflight_last_ok < 30) {
        _log($scfg, 2, 'debug', "[TrueNAS] _preflight_check_alloc: skipping (recently validated " . (time() - $_preflight_last_ok) . "s ago)");
        return [];
    }

    my @errors;
    my $mode = $scfg->{transport_mode} // 'iscsi';

    # Check 1: TrueNAS API is reachable
    eval {
        _api_call($scfg, 'core.ping', []);
    };
    if ($@) {
        push @errors, "TrueNAS API is unreachable: $@";
    }

    # Check 2: Service is running (transport-specific)
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

    # Check 3: Sufficient space available (with 20% overhead)
    if (defined $size_bytes) {
        my $bytes = int($size_bytes);
        my $required = $bytes * 1.2;

        eval {
            my $ds_info = _tn_dataset_get($scfg, $scfg->{dataset});
            if ($ds_info) {
                my $available = _normalize_value($ds_info->{available}) || 0;

                if ($available < $required) {
                    push @errors, sprintf(
                        "Insufficient space on dataset '%s': need %s (with 20%% overhead), have %s available",
                        $scfg->{dataset},
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

    # Check 4: Target/subsystem exists and is configured (transport-specific)
    if ($mode eq 'iscsi') {
        eval {
            my $target_id = _resolve_target_id($scfg);
            if (!defined $target_id) {
                push @errors, sprintf(
                    "iSCSI target not found: %s\n" .
                    "  Verify target exists in TrueNAS: Shares > Block Shares (iSCSI) > Targets",
                    $scfg->{target_iqn}
                );
            }
        };
        if ($@) {
            push @errors, "Cannot verify iSCSI target: $@";
        }
    } elsif ($mode eq 'nvme-tcp') {
        eval {
            my $nqn = $scfg->{subsystem_nqn};
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

    # Check 5: Parent dataset exists
    eval {
        my $ds = _tn_dataset_get($scfg, $scfg->{dataset});
        if (!$ds) {
            push @errors, sprintf(
                "Parent dataset does not exist: %s\n" .
                "  Create the dataset in TrueNAS: Storage > Pools",
                $scfg->{dataset}
            );
        }
    };
    if ($@) {
        push @errors, "Cannot verify parent dataset: $@";
    }

    # Cache successful result for 30s to speed up multi-disk creation
    $_preflight_last_ok = time() if !@errors;

    return \@errors;
}

# Robustly resolve the TrueNAS target id for a configured fully-qualified IQN.
# Result is cached per IQN to avoid redundant API calls within the same process.
sub _resolve_target_id {
    my ($scfg) = @_;
    my $want = $scfg->{target_iqn} // die "target_iqn not set in storage.cfg\n";

    # Return cached result if available
    if (exists $_target_id_cache{$want}) {
        _log($scfg, 2, 'debug', "[TrueNAS] _resolve_target_id: using cached target_id=$_target_id_cache{$want} for $want");
        return $_target_id_cache{$want};
    }

    # 1) Get targets; if empty, surface a clear diagnostic
    my $targets = _tn_targets($scfg) // [];
    if (!@$targets) {
        # Try to fetch the base name for a more helpful message
        my $global   = eval { _api_call($scfg, 'iscsi.global.config', []) } // {};
        my $basename = $global->{basename} // '(unknown)';
        my $portal   = $scfg->{discovery_portal} // '(none)';
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
    $_target_id_cache{$want} = $found->{id};
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
# Check if target sessions are already active
sub _target_sessions_active($scfg) {
    my $iqn = $scfg->{target_iqn};

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
    my $iqn = $scfg->{target_iqn};
    my $norm_portal = _normalize_portal($portal);

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
    }
    return 0;
}

# Check if all configured portals have active sessions for this target
sub _all_portals_connected($scfg) {
    my $iqn = $scfg->{target_iqn};

    # Get all configured portals
    my @portals = ();
    push @portals, _normalize_portal($scfg->{discovery_portal}) if $scfg->{discovery_portal};
    push @portals, map { _normalize_portal($_) } split(/\s*,\s*/, $scfg->{portals}) if $scfg->{portals};

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

    my $primary = _normalize_portal($scfg->{discovery_portal});
    my @extra   = $scfg->{portals} ? map { _normalize_portal($_) } split(/\s*,\s*/, $scfg->{portals}) : ();

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

    # Get current session list once for efficiency
    my @session_lines = eval { _run_lines(['iscsiadm', '-m', 'session']) };

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
        # Skip login if this portal is already connected
        next if _portal_connected($scfg, $portal, \@session_lines);
        _try_run(['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'--login'],
                 "iscsiadm login failed ($portal)");
    }
    # attempt direct login for any extra portals not already in -m node
    for my $p (@extra) {
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
    my $iqn = $scfg->{target_iqn};
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

sub _logout_target_all_portals {
    my ($scfg) = @_;
    my $iqn = $scfg->{target_iqn};
    my @portals = ();
    push @portals, _normalize_portal($scfg->{discovery_portal}) if $scfg->{discovery_portal};
    push @portals, map { _normalize_portal($_) } split(/\s*,\s*/, ($scfg->{portals}//''));
    for my $p (@portals) {
        eval { PVE::Tools::run_command(['iscsiadm','-m','node','-p',$p,'--targetname',$iqn,'--logout'], errfunc=>sub{} ) };
        eval { PVE::Tools::run_command(['iscsiadm','-m','node','-p',$p,'--targetname',$iqn,'-o','delete'], errfunc=>sub{} ) };
    }
}
sub _login_target_all_portals {
    my ($scfg) = @_;
    my $iqn = $scfg->{target_iqn};
    my @portals = ();
    push @portals, _normalize_portal($scfg->{discovery_portal}) if $scfg->{discovery_portal};
    push @portals, map { _normalize_portal($_) } split(/\s*,\s*/, ($scfg->{portals}//''));
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
    my $max_retries = $scfg->{device_ready_retries} // 200; # up to ~20s with 100ms sleep
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
        my $iqn = $scfg->{target_iqn} // '';
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

# ======== NVMe/TCP Helper Functions ========

# Get or read host NQN from /etc/nvme/hostnqn
sub _nvme_get_hostnqn {
    my ($scfg) = @_;

    # If explicitly configured, use that
    return $scfg->{hostnqn} if $scfg->{hostnqn};

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

sub _nvme_untaint_cli_nqn {
    my ($value, $label) = @_;
    $label //= 'NVMe NQN';

    die "Invalid $label: missing value\n"
        if !defined($value) || $value eq '';

    if ($value =~ /^(nqn\.\d{4}-\d{2}\.[A-Za-z0-9.-]+:[A-Za-z0-9][A-Za-z0-9._:-]*)$/) {
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

# Check if connected to a subsystem
sub _nvme_is_connected {
    my ($scfg) = @_;
    my $nqn = $scfg->{subsystem_nqn};

    my $in_our_subsys = 0;
    my $connected = 0;
    eval {
        run_command(['nvme', 'list-subsys'],
            outfunc => sub {
                my $line = shift;
                if ($line =~ /NQN=/) {
                    # New subsystem section — check if it's ours
                    $in_our_subsys = ($line =~ /\Q$nqn\E/) ? 1 : 0;
                } elsif ($in_our_subsys && $line =~ /tcp\s.*\blive\b/) {
                    # Found a live TCP transport controller for our subsystem
                    $connected = 1;
                }
            },
            errfunc => sub {}
        );
    };

    return $connected;
}

# Connect to NVMe/TCP subsystem (all portals)
sub _nvme_connect {
    my ($scfg) = @_;

    _log($scfg, 1, 'info', "[TrueNAS] nvme_connect: connecting to subsystem $scfg->{subsystem_nqn}");

    # Check if already connected
    return if _nvme_is_connected($scfg);

    my $nqn = _nvme_untaint_cli_nqn($scfg->{subsystem_nqn}, 'NVMe subsystem NQN');
    my @portals = ();

    # Primary portal
    push @portals, $scfg->{discovery_portal} if $scfg->{discovery_portal};

    # Additional portals
    if ($scfg->{portals}) {
        push @portals, split(/\s*,\s*/, $scfg->{portals});
    }

    die "No portals configured for NVMe/TCP storage\n" unless @portals;

    my $hostnqn = _nvme_untaint_cli_nqn(_nvme_get_hostnqn($scfg), 'NVMe host NQN');
    my $dhchap_secret = _nvme_untaint_cli_secret($scfg->{nvme_dhchap_secret}, 'NVMe DH-HMAC secret');
    my $dhchap_ctrl_secret = _nvme_untaint_cli_secret($scfg->{nvme_dhchap_ctrl_secret}, 'NVMe controller DH-HMAC secret');
    my $connected_count = 0;

    for my $portal (@portals) {
        my ($host, $port) = _nvme_parse_portal($portal);
        $host = _nvme_untaint_cli_host($host);
        $port = _nvme_untaint_cli_port($port);

        _log($scfg, 2, 'debug', "[TrueNAS] nvme_connect: connecting to $host:$port");

        my @cmd = ('nvme', 'connect', '-t', 'tcp', '-n', $nqn, '-a', $host, '-s', $port);

        # Add host NQN if not default
        push @cmd, '--hostnqn', $hostnqn if $hostnqn;

        # Add DH-HMAC-CHAP authentication if configured
        if (defined($dhchap_secret)) {
            push @cmd, '--dhchap-secret', $dhchap_secret;
        }
        if (defined($dhchap_ctrl_secret)) {
            push @cmd, '--dhchap-ctrl-secret', $dhchap_ctrl_secret;
        }

        my $connect_stderr = '';
        eval {
            run_command(\@cmd,
                outfunc => sub { _log($scfg, 2, 'debug', "[TrueNAS] nvme connect: " . shift); },
                errfunc => sub { $connect_stderr .= shift; }
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
            }
        }
    }

    die "Failed to connect to any NVMe/TCP portal for subsystem $nqn\n" if $connected_count == 0;

    # Wait for devices to settle
    run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {});
    usleep(UDEV_SETTLE_TIMEOUT_US);

    _log($scfg, 1, 'info', "[TrueNAS] nvme_connect: connected to $connected_count portal(s)");
}

# Disconnect from NVMe/TCP subsystem
# Tries controller-specific disconnect first to avoid disrupting other storages
# sharing the same subsystem NQN. Falls back to NQN-wide disconnect if needed.
sub _nvme_disconnect {
    my ($scfg) = @_;
    my $nqn = _nvme_untaint_cli_nqn($scfg->{subsystem_nqn}, 'NVMe subsystem NQN');

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

    my $nqn = $scfg->{subsystem_nqn};

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

    my $nqn = $scfg->{subsystem_nqn};
    my @controllers;

    # Build set of portals to match against
    my %portal_set;
    for my $portal_str ($scfg->{discovery_portal}, $scfg->{portals} ? split(/\s*,\s*/, $scfg->{portals}) : ()) {
        next unless $portal_str;
        my ($host, $port) = _nvme_parse_portal($portal_str);
        $portal_set{"$host:$port"} = 1;
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
            my ($ctrl_host, $ctrl_port);
            if ($address =~ /traddr=([^,\s]+)/) {
                $ctrl_host = $1;
            }
            if ($address =~ /trsvcid=(\d+)/) {
                $ctrl_port = $1;
            }
            next unless $ctrl_host;
            $ctrl_port //= 4420;

            # If we have portals configured, only include controllers matching them
            if (%portal_set) {
                next unless $portal_set{"$ctrl_host:$ctrl_port"};
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

    return 'api_namespace_not_visible_in_linux'
        if defined($api_namespace_count) && $api_namespace_count > 0 && $linux_device_count == 0;
    return 'single_visible_device_but_api_reports_multiple_namespaces'
        if defined($api_namespace_count) && $linux_device_count == 1 && $api_namespace_count > 1;
    return 'linux_api_namespace_count_mismatch'
        if defined($api_namespace_count) && $linux_device_count != $api_namespace_count;
    return 'namespace_metadata_did_not_match_visible_devices';
}

my %NVME_SELECTOR_REASON_LABELS = (
    namespace_metadata_query_failed                       => 'TrueNAS API namespace metadata query failed',
    api_subsystem_not_found                               => 'TrueNAS API did not return the target subsystem',
    namespace_uuid_not_returned                           => 'TrueNAS API did not return the target namespace UUID',
    api_namespace_not_visible_in_linux                    => 'subsystem is connected in TrueNAS but no Linux block devices are visible',
    single_visible_device_but_api_reports_multiple_namespaces => 'one Linux block device is visible but TrueNAS reports multiple namespaces',
    linux_api_namespace_count_mismatch                    => 'Linux-visible namespace count does not match the TrueNAS API namespace count',
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

    my $nqn = $scfg->{subsystem_nqn};
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
        my $subsys_namespaces = _api_call($scfg, 'nvmet.namespace.query', [
            [["subsys", "=", $subsys_id]]
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
            _log($scfg, 1, 'warning', "[TrueNAS] nvme_find_device: subsystem $scfg->{subsystem_nqn} was not returned by TrueNAS API");
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

    my $nqn = $scfg->{subsystem_nqn};

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

    my $nqn = $scfg->{subsystem_nqn};
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

    my $nqn = $scfg->{subsystem_nqn};

    _log($scfg, 2, 'debug', "[TrueNAS] nvme_device_for_uuid: searching for namespace with UUID $device_uuid in subsystem $nqn");

    # Wait for device to appear with progressive backoff (up to 5 seconds)
    my $ever_saw_devices = 0;  # Track if any block devices were ever seen (safety guard for reconnect)
    my $nguid_ever_matched = 0;  # Track if NGUID matching ever succeeded (stale detection)
    my $reconnect_attempted = 0;
    my $last_result;

    for (my $i = 0; $i < 50; $i++) {
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
        $scfg->{api_host},
        $namespace_detail,
    );

    die $err_msg;
}

# Ensure NVMe subsystem exists on TrueNAS
sub _nvme_ensure_subsystem {
    my ($scfg) = @_;
    my $nqn = $scfg->{subsystem_nqn};

    _log($scfg, 2, 'debug', "[TrueNAS] nvme_ensure_subsystem: checking for subsystem $nqn");

    # Query existing subsystems
    my $subsystems = _api_call($scfg, 'nvmet.subsys.query', [
        [["subnqn", "=", $nqn]]
    ]);

    if ($subsystems && @$subsystems) {
        my $subsys = $subsystems->[0];
        _log($scfg, 2, 'debug', "[TrueNAS] nvme_ensure_subsystem: subsystem exists with id=$subsys->{id}");
        return $subsys->{id};
    }

    # Create subsystem if it doesn't exist
    _log($scfg, 1, 'info', "[TrueNAS] nvme_ensure_subsystem: creating subsystem $nqn");

    # Generate short name from NQN (last part after :)
    my $name = $nqn;
    $name = $1 if $nqn =~ /:([^:]+)$/;
    $name =~ s/[^a-zA-Z0-9_\-]/_/g;

    # TrueNAS 25.10+ no longer accepts serial parameter in subsystem creation
    my $subsys = _api_call_write($scfg, 'nvmet.subsys.create', [{
        name => $name,
        subnqn => $nqn,
        allow_any_host => JSON::PP::true,  # TODO: Make configurable for auth
    }]);

    my $subsys_id = ref($subsys) eq 'HASH' ? $subsys->{id} : $subsys;

    # Create ports for all configured portals
    my @portals = ();
    push @portals, $scfg->{discovery_portal} if $scfg->{discovery_portal};
    push @portals, split(/\s*,\s*/, $scfg->{portals}) if $scfg->{portals};

    for my $portal (@portals) {
        my ($host, $port) = _nvme_parse_portal($portal);

        _log($scfg, 2, 'debug', "[TrueNAS] nvme_ensure_subsystem: creating port for $host:$port");

        eval {
            _api_call_write($scfg, 'nvmet.port.create', [{
                subsys_id => $subsys_id,
                trtype => 'TCP',
                traddr => $host,
                trsvcid => "$port",  # Must be string
            }]);
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
    my $ns = _api_call_write($scfg, 'nvmet.namespace.create', [{
        device_type => 'ZVOL',
        device_path => $zvol_path,  # Already has 'zvol/' prefix
        subsys_id => $subsys_id,
        enabled => JSON::PP::true,
    }]);

    my $device_uuid = $ns->{device_uuid};
    die "Failed to get device_uuid from namespace creation\n" unless $device_uuid;

    _log($scfg, 1, 'info', "[TrueNAS] nvme_create_namespace: created namespace with UUID $device_uuid");

    # Connect to subsystem if not already connected
    _nvme_connect($scfg);

    # Wait for device to appear
    my $dev = _nvme_device_for_uuid($scfg, $device_uuid, allow_reconnect => 1);
    _log($scfg, 1, 'info', "[TrueNAS] nvme_create_namespace: device ready at $dev");

    return $device_uuid;
}

# Delete NVMe namespace
sub _nvme_delete_namespace {
    my ($scfg, $zname, $full_ds) = @_;

    _log($scfg, 1, 'info', "[TrueNAS] nvme_delete_namespace: deleting namespace for $zname");

    # Get subsystem ID
    my $nqn = $scfg->{subsystem_nqn};
    my $subsystems = _api_call($scfg, 'nvmet.subsys.query', [
        [["subnqn", "=", $nqn]]
    ]);

    return unless $subsystems && @$subsystems;
    my $subsys_id = $subsystems->[0]{id};

    # Find namespace for this zvol
    my $zvol_path = "zvol/$full_ds";
    my $namespaces = _api_call($scfg, 'nvmet.namespace.query', [
        [["subsys_id", "=", $subsys_id], ["device_path", "=", $zvol_path]]
    ]);

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
#   iSCSI:    vol-<zname>-lun<N>, where <zname> is usually vm-<vmid>-disk-<n>
#   NVMe/TCP: vol-<zname>-ns<uuid>, where uuid is the device_uuid from TrueNAS
sub parse_volname {
    my ($class, $volname) = @_;

    # iSCSI format: vol-<zname>-lun<N>
    if ($volname =~ m/^vol-([A-Za-z0-9:_\.\-]+)-lun(\d+)$/) {
        my ($zname, $lun) = ($1, $2);
        my $vmid;
        $vmid = $1 if $zname =~ m/^vm-(\d+)-/; # derive owner if named vm-<vmid>-...
        # return shape mimics other block plugins:
        # ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format, $metadata)
        # For iSCSI, metadata = lun number
        return ('images', $zname, $vmid, undef, undef, undef, 'raw', $lun);
    }

    # NVMe format: vol-<zname>-ns<uuid>
    if ($volname =~ m/^vol-([A-Za-z0-9:_\.\-]+)-ns([a-f0-9\-]+)$/) {
        my ($zname, $uuid) = ($1, $2);
        my $vmid;
        $vmid = $1 if $zname =~ m/^vm-(\d+)-/; # derive owner if named vm-<vmid>-...
        # For NVMe, metadata = device_uuid
        return ('images', $zname, $vmid, undef, undef, undef, 'raw', $uuid);
    }

    die "unable to parse volname '$volname'\n";
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    # Note: snapname is used during clone operations - we support snapshots via ZFS
    my (undef, $zname, $vmid, undef, undef, undef, undef, $metadata) = $class->parse_volname($volname);

    my $mode = $scfg->{transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        # iSCSI: metadata is LUN number
        my $lun = $metadata;
        _iscsi_login_all($scfg);
        my $dev;
        eval { $dev = _device_for_lun($scfg, $lun); };
        if ($@ || !$dev) {
            # try to re-resolve LUN mapping from TrueNAS
            my $real_lun = eval { _current_lun_for_zname($scfg, $zname) };
            if (defined $real_lun && (!defined($lun) || $real_lun != $lun)) {
                $dev = _device_for_lun($scfg, $real_lun);
            } else {
                die $@ if $@; # bubble up original cause
                die "Could not locate device for LUN $lun (IQN $scfg->{target_iqn})\n";
            }
        }
        return ($dev, $vmid, 'images');

    } elsif ($mode eq 'nvme-tcp') {
        # NVMe: metadata is device_uuid
        my $uuid = $metadata;
        _nvme_connect($scfg);
        my $dev = _nvme_device_for_uuid($scfg, $uuid);
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

    # Level 0: Always log (errors only logged elsewhere)
    # Level 1: Light - function entry with key parameters
    _log($scfg, 1, 'info', "[TrueNAS] alloc_image: vmid=$vmid, name=" . ($name // 'undef') . ", size=$size_kib KiB");

    die "only raw is supported\n" if defined($fmt) && $fmt ne 'raw';
    die "invalid size\n" if !defined($size_kib) || $size_kib <= 0;

    # Convert KiB to bytes for TrueNAS API
    my $bytes = int($size_kib) * 1024;

    # Level 2: Verbose - unit conversion details
    _log($scfg, 2, 'debug', "[TrueNAS] alloc_image: converting $size_kib KiB → $bytes bytes");

    # Parse configured blocksize to bytes for alignment
    my $bs_bytes = _parse_blocksize($scfg->{zvol_blocksize});

    # Align to volblocksize if configured (mirrors volume_resize logic at line 1307-1311)
    if ($bs_bytes && $bs_bytes > 0) {
        my $original_bytes = $bytes;
        my $rem = $bytes % $bs_bytes;
        if ($rem) {
            $bytes += ($bs_bytes - $rem);
            _log($scfg, 1, 'info', "[TrueNAS] " . sprintf(
                "alloc_image: size alignment: requested %d bytes → aligned %d bytes (volblocksize: %s)",
                $original_bytes, $bytes, $scfg->{zvol_blocksize}
            ));
        }
    }

    # Pre-flight checks: validate all prerequisites before expensive operations
    _log($scfg, 1, 'info', "[TrueNAS] alloc_image: running pre-flight checks for $bytes bytes");
    my $errors = _preflight_check_alloc($scfg, $bytes);
    if (@$errors) {
        my $error_msg = "Pre-flight validation failed:\n  - " . join("\n  - ", @$errors);
        _log($scfg, 0, 'err', "[TrueNAS] alloc_image: pre-flight check failed for VM $vmid: " . join("; ", @$errors));
        die "$error_msg\n";
    }

    # Log successful pre-flight checks
    _log($scfg, 1, 'info', sprintf(
        "[TrueNAS] alloc_image: pre-flight checks passed for %s volume allocation on '%s' (VM %d)",
        _format_bytes($bytes), $scfg->{dataset}, $vmid
    ));

    # Determine a disk name under our dataset: vm-<vmid>-disk-<n>
    my $zname = $name;
    if (!$zname) {
        $zname = _find_free_disk_name($scfg, $vmid);
    }

    my $full_ds = $scfg->{dataset} . '/' . $zname;

    # 1) Create the zvol (VOLUME) on TrueNAS with requested size
    # Note: $bytes already calculated above in space check (size in KiB * 1024)
    my $blocksize = $scfg->{zvol_blocksize};

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

        my $create_payload = {
            name     => $full_ds,
            type     => 'VOLUME',
            volsize  => $bytes,
            sparse   => ($scfg->{tn_sparse} // 1) ? JSON::PP::true : JSON::PP::false,
            comments => 'Autocreated by Proxmox Plugin',
        };
        # Normalize blocksize to uppercase for TrueNAS 25.10+ compatibility
        $create_payload->{volblocksize} = _normalize_blocksize($blocksize) if $blocksize;

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
                    $full_ds = $scfg->{dataset} . '/' . $zname;
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

    # If pool.dataset.create returns a job ID, wait for it to complete
    # This ensures the zvol is fully created before we try to use it
    if (defined $create_result && !ref($create_result) && $create_result =~ /^\d+$/) {
        _log($scfg, 1, 'info', "[TrueNAS] alloc_image: waiting for zvol creation job $create_result to complete");
        my $job_result = _wait_for_job_completion($scfg, $create_result, 30);
        unless ($job_result->{success}) {
            die "Failed to create zvol $full_ds: " . ($job_result->{error} // 'Unknown error') . "\n";
        }
        _log($scfg, 1, 'info', "[TrueNAS] alloc_image: zvol $full_ds created successfully");
    }

    # 2) Transport-specific volume exposure
    my $zvol_path = 'zvol/' . $full_ds;
    my $mode = $scfg->{transport_mode} // 'iscsi';

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
    {
        my $ext = _api_call(
            $scfg,
            'iscsi.extent.create',
            [ $extent_payload ],
        );
        # normalize id from WebSocket result (hashref)
        $extent_id = ref($ext) eq 'HASH' ? $ext->{id} : $ext;
    }
    if (!defined $extent_id) {
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

    # 3) Map extent to our shared target (targetextent.create); lunid is auto-assigned if not given
    my $target_id = _resolve_target_id($scfg);

    # First check if this mapping already exists
    my $maps = _tn_targetextents($scfg) // [];
    my ($existing_map) = grep {
        (($_->{target}//-1) == $target_id) && (($_->{extent}//-1) == $extent_id)
    } @$maps;

    my $lun;
    if (!$existing_map) {
        # Mapping doesn't exist, create it
        _log($scfg, 2, 'debug', "[TrueNAS] alloc_image: creating target-extent mapping for extent_id=$extent_id to target_id=$target_id");
        my $tx_payload = { target => $target_id, extent => $extent_id };
        my $tx = _api_call(
            $scfg,
            'iscsi.targetextent.create',
            [ $tx_payload ],
        );

        # Extract LUN directly from create response (avoids a re-fetch query)
        $lun = ref($tx) eq 'HASH' ? $tx->{lunid} : undef;

        # Invalidate cache after creating new mapping
        _clear_cache($scfg->{storeid} || 'unknown');

        # Fallback: re-fetch if create response didn't include lunid
        if (!defined $lun) {
            $maps = _tn_targetextents($scfg) // [];
            ($existing_map) = grep {
                (($_->{target}//-1) == $target_id) && (($_->{extent}//-1) == $extent_id)
            } @$maps;
            $lun = $existing_map->{lunid} if $existing_map;
        }
    } else {
        _log($scfg, 1, 'info', "[TrueNAS] alloc_image: target-extent mapping already exists for extent_id=$extent_id (LUN $existing_map->{lunid})");
        $lun = $existing_map->{lunid};
    }
    if (!defined $lun) {
        die sprintf(
            "Could not determine assigned LUN for disk '%s'\n\n" .
            "Target ID: %d\n" .
            "Extent ID: %d\n" .
            "Extent name: %s\n" .
            "Total target-extent mappings found: %d\n\n" .
            "This usually means:\n" .
            "  1. Target-extent mapping creation failed silently\n" .
            "  2. TrueNAS cache not yet updated (rare)\n" .
            "  3. API query returned stale data\n\n" .
            "Troubleshooting:\n" .
            "  - Check TrueNAS GUI: Shares > iSCSI > Targets > Associated Targets\n" .
            "  - Verify extent '%s' is mapped to target ID %d\n" .
            "  - Check TrueNAS logs: /var/log/middlewared.log\n" .
            "  - Verify API has 'Sharing' read permissions\n",
            $zname, $target_id, $extent_id, $zname, scalar(@$maps), $zname, $target_id
        );
    }

    # 5) Return volname immediately — device discovery is deferred after lock release.
    # activate_volume handles authoritative device discovery before any VM uses the disk.
    my $volname = "vol-$zname-lun$lun";

    # Defer local I/O operations (iSCSI login, rescan, device polling) to run after CFS lock release
    my $deferred_scfg = $scfg;  # capture for closure
    my $deferred_lun = $lun;
    _defer_after_lock(sub {
        _log($deferred_scfg, 2, 'debug', "[TrueNAS] alloc_image deferred: starting iSCSI device discovery for LUN $deferred_lun");

        # Ensure iSCSI login
        if (!_target_sessions_active($deferred_scfg)) {
            _log($deferred_scfg, 1, 'info', "[TrueNAS] alloc_image deferred: logging in to target $deferred_scfg->{target_iqn}");
            eval { _iscsi_login_all($deferred_scfg); };
            if ($@) {
                _log($deferred_scfg, 1, 'warning', "[TrueNAS] alloc_image deferred: iSCSI login failed (activate_volume will retry): $@");
                return;
            }
        }

        # Rescan to detect the new LUN
        eval { _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan failed"); };
        if ($deferred_scfg->{use_multipath}) {
            eval { _try_run(['multipath','-r'], "multipath reload failed"); };
        }
        eval { run_command(['udevadm','settle'], outfunc => sub {}); };

        # Best-effort device verification with reduced retries
        my $device_ready = 0;
        for my $attempt (1..8) {
            eval {
                my $dev = _device_for_lun($deferred_scfg, $deferred_lun);
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
    });

    return $volname;
}

# NVMe-specific allocation (create namespace, defer device discovery)
sub _alloc_image_nvme {
    my ($class, $scfg, $zname, $full_ds, $zvol_path) = @_;

    _log($scfg, 1, 'info', "[TrueNAS] _alloc_image_nvme: creating NVMe namespace for $zname");

    # Create namespace on TrueNAS (locked section — API calls only)
    my $subsys_id = _nvme_ensure_subsystem($scfg);
    my $ns = _api_call_write($scfg, 'nvmet.namespace.create', [{
        device_type => 'ZVOL',
        device_path => $zvol_path,
        subsys_id => $subsys_id,
        enabled => JSON::PP::true,
    }]);
    my $device_uuid = $ns->{device_uuid};
    die "Failed to get device_uuid from namespace creation\n" unless $device_uuid;
    _log($scfg, 1, 'info', "[TrueNAS] _alloc_image_nvme: created namespace with UUID $device_uuid");

    # Return volname immediately — defer connect + device discovery
    my $volname = "vol-$zname-ns$device_uuid";

    my $deferred_scfg = $scfg;
    my $deferred_uuid = $device_uuid;
    _defer_after_lock(sub {
        _log($deferred_scfg, 2, 'debug', "[TrueNAS] alloc_image_nvme deferred: connecting and discovering device for UUID $deferred_uuid");
        eval { _nvme_connect($deferred_scfg); };
        if ($@) {
            _log($deferred_scfg, 1, 'warning', "[TrueNAS] alloc_image_nvme deferred: NVMe connect failed (activate_volume will retry): $@");
            return;
        }
        # Settle + rescan to detect new namespace (mirrors clone_image_nvme deferred path)
        usleep(200_000);  # 200ms initial settle
        eval { run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {}) };
        eval { _nvme_rescan_subsystem_controllers($deferred_scfg) };
        my $dev = eval { _nvme_device_for_uuid($deferred_scfg, $deferred_uuid, allow_reconnect => 1) };
        if ($dev) {
            _log($deferred_scfg, 1, 'info', "[TrueNAS] alloc_image_nvme deferred: device ready at $dev");
        } else {
            _log($deferred_scfg, 1, 'info', "[TrueNAS] alloc_image_nvme deferred: device not yet visible (activate_volume will handle)");
        }
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
    my $full = $scfg->{dataset} . '/' . $zname;
    my $ds = _tn_dataset_get($scfg, $full) // {};
    my $bytes = _normalize_value($ds->{volsize});
    die "volume_size_info: missing volsize for $full\n" if !$bytes;
    return wantarray ? ($bytes, $fmt) : $bytes;
}

# Delete a VM disk: remove transport-specific resources, delete zvol, and clean up.
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    # Level 1: Light - function entry
    _log($scfg, 1, 'info', "[TrueNAS] free_image: volname=$volname");

    die "snapshots not supported on zvols\n" if $isBase;
    die "unsupported format '$format'\n" if defined($format) && $format ne 'raw';

    my (undef, $zname, undef, undef, undef, undef, undef, $metadata) = $class->parse_volname($volname);
    my $full_ds = $scfg->{dataset} . '/' . $zname;

    # Protect weight volume from deletion - it maintains target visibility
    # Match both old format (pve-plugin-weight) and new format (pve-weight-*)
    if ($zname eq 'pve-plugin-weight' || $zname =~ /^pve-weight-/) {
        die "Cannot delete weight volume '$volname' - it maintains target visibility and prevents storage outages.\n" .
            "Weight volumes are critical infrastructure and must persist to keep iSCSI targets discoverable.\n";
    }

    # Level 2: Verbose - parsed details
    _log($scfg, 2, 'debug', "[TrueNAS] free_image: zname=$zname, metadata=$metadata, full_ds=$full_ds");

    # Dispatch to transport-specific deletion
    my $mode = $scfg->{transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        return _free_image_iscsi($class, $storeid, $scfg, $volname, $zname, $full_ds, $metadata);
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
            my $iqn = $scfg->{target_iqn};
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
    my $extents = _tn_extents($scfg) // [];
    my $zvol_path_match = "zvol/$scfg->{dataset}/$zname";
    my ($extent) = grep { ($_->{disk}//'') eq $zvol_path_match } @$extents;
    my $maps = _tn_targetextents($scfg) // [];
    my ($tx) = ($extent && $target_id)
        ? grep { (($_->{target}//-1) == $target_id) && (($_->{extent}//-1) == $extent->{id}) } @$maps
        : ();

    my $in_use = sub { my ($e)=@_; return ($e && $e =~ /in use/i) ? 1 : 0; };
    my $need_force_logout = 0;

    # 1) Delete targetextent mapping
    if ($tx && defined $tx->{id}) {
        my $id = $tx->{id};
        my $ok = eval {
            _api_call($scfg,'iscsi.targetextent.delete',[ $id ]);
            1;
        };
        if (!$ok) {
            my $err = $@ // '';
            if ($scfg->{force_delete_on_inuse} && $in_use->($err)) {
                $need_force_logout = 1;
            } elsif ($err !~ /does not exist|ENOENT|InstanceNotFound/i) {
                # Only warn if resource actually exists - ENOENT means already cleaned up
                warn "warning: delete targetextent id=$id failed: $err";
            }
            # Silently ignore "does not exist" errors - resource already gone
        }
    }

    # 2) Delete extent (may still be mapped if step 1 failed)
    if ($extent && defined $extent->{id}) {
        my $eid = $extent->{id};
        my $ok = eval {
            _api_call($scfg,'iscsi.extent.delete',[ $eid ]);
            1;
        };
        if (!$ok) {
            my $err = $@ // '';
            if ($scfg->{force_delete_on_inuse} && $in_use->($err)) {
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
        # Check how many LUNs are currently mapped to this target
        my $active_luns = 0;
        eval {
            my $all_maps = _tn_targetextents($scfg) // [];
            my @target_maps = grep { ($_->{target}//-1) == $target_id } @$all_maps;
            $active_luns = scalar(@target_maps);
        };

        # Only logout if this is the last LUN, or if we can't determine LUN count
        # This prevents breaking multi-disk restore/creation operations
        if ($active_luns <= 1 || $@) {
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: logging out to retry extent deletion (active LUNs: $active_luns)");
            _logout_target_all_portals($scfg);
            # Wait for iSCSI session to fully disconnect before retrying deletion
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: waiting for iSCSI session to disconnect");
            sleep(DEVICE_SETTLE_DELAY_S);  # Reduced from 2s to 1s - modern systems settle faster
            eval { run_command(['udevadm','settle'], outfunc => sub {}) };
        } else {
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: skipping logout - $active_luns other LUNs active");
            $need_force_logout = 0;  # Skip retry since we're not logging out
        }
        # Retry mapping delete
        if ($tx && defined $tx->{id}) {
            my $id = $tx->{id};
            eval {
                _api_call($scfg,'iscsi.targetextent.delete',[ $id ]);
            };
            if ($@) {
                # In cluster environments, other nodes may have active sessions causing "in use" errors
                # This is expected - TrueNAS will clean up orphaned extents when all sessions close
                _log($scfg, 1, 'info', "[TrueNAS] _free_image_iscsi: could not delete targetextent id=$id (may be in use by other cluster nodes)");
            }
        }
        # Retry extent delete (re-query extent by disk path)
        $extents = _tn_extents($scfg) // [];
        ($extent) = grep { ($_->{disk}//'') eq $zvol_path_match } @$extents;
        if ($extent && defined $extent->{id}) {
            my $eid = $extent->{id};
            eval {
                _api_call($scfg,'iscsi.extent.delete',[ $eid ]);
            };
            if ($@) {
                _log($scfg, 1, 'info', "[TrueNAS] _free_image_iscsi: could not delete extent id=$eid (may be in use by other cluster nodes)");
            }
        }
    }

    # 4) CRITICAL: Ensure devices are fully disconnected BEFORE dataset deletion
    # This fixes the race condition where dataset deletion fails with "busy" errors
    # because the kernel still has active device references
    if ($need_force_logout || @scsi_devices_to_cleanup) {
        # Logout to disconnect iSCSI sessions
        if ($need_force_logout) {
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: logging out before dataset deletion to prevent race condition");
            _logout_target_all_portals($scfg);
            sleep(DEVICE_SETTLE_DELAY_S);
        }

        # Clean up orphaned SCSI device entries from kernel
        # This must happen BEFORE dataset deletion to prevent "busy" errors
        if (@scsi_devices_to_cleanup) {
            _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: cleaning up " . scalar(@scsi_devices_to_cleanup) . " SCSI device(s) before dataset deletion");
            my @device_paths;
            for my $dev (@scsi_devices_to_cleanup) {
                my $delete_path = "/sys/block/$dev/device/delete";
                push @device_paths, $delete_path if -e $delete_path;
                if (-e $delete_path && -w $delete_path) {
                    eval {
                        _log($scfg, 2, 'debug', "[TrueNAS] _free_image_iscsi: deleting SCSI device $dev for LUN $lun");
                        if (open my $fh, '>', $delete_path) {
                            print $fh "1";
                            close $fh;
                        }
                    };
                    # Ignore errors - device may already be gone
                }
            }

            # Verify devices are disconnected before proceeding
            _verify_devices_disconnected($scfg, \@device_paths);
        }

        # Run udevadm settle to ensure kernel has processed all changes
        eval { run_command(['udevadm','settle'], outfunc => sub {}) };
        $need_force_logout = 1;  # Mark that we need to handle reconnection later
    }

    # 5) Delete the zvol dataset using retry logic with exponential backoff
    # The new helper function handles "busy" errors robustly with retry logic
    eval {
        # Safety check: Verify dataset has no child datasets (only snapshots allowed)
        # This prevents accidental deletion of manually created child datasets
        my $ds_info = eval { _tn_dataset_get($scfg, $full_ds) };
        if ($ds_info && $ds_info->{children}) {
            my @children = grep { $_->{type} ne 'SNAPSHOT' } @{$ds_info->{children}};
            if (@children) {
                my $child_names = join(', ', map { $_->{name} // $_->{id} } @children);
                die "Cannot use recursive deletion: dataset $full_ds has child datasets: $child_names. " .
                    "Recursive deletion would destroy these child datasets. Please remove them manually first.";
            }
        }

        # Use the new retry helper - it handles async jobs, retries, and error parsing
        _delete_dataset_with_retry($scfg, $full_ds);
    };

    # Handle any errors from dataset deletion
    if ($@) {
        my $err = $@ // '';
        # Only warn if dataset actually exists - ENOENT means already cleaned up
        warn "warning: delete dataset $full_ds failed: $err" unless $err =~ /does not exist|ENOENT|InstanceNotFound/i;
    }

    # 6) Defer post-deletion cleanup after lock release (session rescan, self-healing, logout check)
    my $deferred_scfg = $scfg;
    my $deferred_need_force_logout = $need_force_logout;
    _defer_after_lock(sub {
        _log($deferred_scfg, 2, 'debug', "[TrueNAS] free_image_iscsi deferred: post-deletion cleanup");

        if ($deferred_need_force_logout) {
            # Just clean up stale multipath mappings without reconnecting
            if ($deferred_scfg->{use_multipath}) {
                eval { PVE::Tools::run_command(['multipath','-r'], outfunc=>sub{}, errfunc=>sub{}) };
            }
            eval { PVE::Tools::run_command(['udevadm','settle'], outfunc=>sub{}) };
        } else {
            eval { PVE::Tools::run_command(['iscsiadm','-m','session','-R'], outfunc=>sub{}) };
            if ($deferred_scfg->{use_multipath}) {
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
        if ($deferred_scfg->{logout_on_free}) {
            eval {
                if (_session_has_no_luns($deferred_scfg)) {
                    _logout_target_all_portals($deferred_scfg);
                }
            };
            _log($deferred_scfg, 1, 'warning', "[TrueNAS] free_image deferred: logout_on_free check failed: $@") if $@;
        }
    });

    return undef;
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
        if ($scfg->{force_delete_on_inuse} && $in_use->($err)) {
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
            my $nqn = $scfg->{subsystem_nqn};
            my $subsystems = _api_call($scfg, 'nvmet.subsys.query',
                [[ ["subnqn", "=", $nqn] ]]);

            if ($subsystems && @$subsystems) {
                my $subsys_id = $subsystems->[0]{id};
                my $namespaces = _api_call($scfg, 'nvmet.namespace.query',
                    [[ ["subsys_id", "=", $subsys_id] ]]);
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

    # 3) Delete the zvol dataset using retry logic with exponential backoff
    # The new helper function handles "busy" errors robustly with retry logic
    eval {
        # Safety check: Verify dataset has no child datasets (only snapshots allowed)
        my $ds_info = eval { _tn_dataset_get($scfg, $full_ds) };
        if ($ds_info && $ds_info->{children}) {
            my @children = grep { $_->{type} ne 'SNAPSHOT' } @{$ds_info->{children}};
            if (@children) {
                my $child_names = join(', ', map { $_->{name} // $_->{id} } @children);
                die "Cannot use recursive deletion: dataset $full_ds has child datasets: $child_names. " .
                    "Recursive deletion would destroy these child datasets. Please remove them manually first.";
            }
        }

        # Use the new retry helper - it handles async jobs, retries, and error parsing
        _delete_dataset_with_retry($scfg, $full_ds);
    };

    # Handle any errors from dataset deletion
    if ($@) {
        my $err = $@ // '';
        # Only warn if dataset actually exists - ENOENT means already cleaned up
        warn "warning: delete dataset $full_ds failed: $err" unless $err =~ /does not exist|ENOENT|InstanceNotFound/i;
    }

    # 4) Defer udev cleanup after lock release
    my $deferred_scfg = $scfg;
    _defer_after_lock(sub {
        _log($deferred_scfg, 2, 'debug', "[TrueNAS] free_image_nvme deferred: udev settle");
        eval { run_command(['udevadm','settle'], outfunc=>sub{}) };
    });

    return undef;
}

# Heuristic: returns true if our target session shows no "Attached SCSI devices" with LUNs.
# Conservative: we only logout if we see a session for the IQN AND there are zero LUNs listed.
sub _session_has_no_luns {
    my ($scfg) = @_;
    my $target_iqn = $scfg->{target_iqn} // return 0;

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

    my $mode = $scfg->{transport_mode} // 'iscsi';

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
    my $extents    = _tn_extents($scfg) // [];
    my $maps       = _tn_targetextents($scfg) // [];
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
    eval {
        # Query TrueNAS for all child datasets under our storage dataset
        # This is significantly faster than individual _tn_dataset_get() calls per volume
        my $datasets = _api_call($scfg, 'pool.dataset.query', [
            [["id", "^", "$scfg->{dataset}/"]]
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
        next MAPPING unless $ds_full =~ m{^\Q$scfg->{dataset}\E/(.+)$};
        my $zname = $1;

        # Determine assigned LUN id
        my $lun = $tx->{lunid};
        next MAPPING if !defined $lun;

        # Owner (vmid) from our naming convention
        my $owner;
        $owner = $1 if $zname =~ /^vm-(\d+)-/;

        # Honor $vmid filter
        if (defined $vmid) {
            # Skip if no owner detected (e.g., weight zvol) or owner doesn't match
            next MAPPING if !defined $owner || $owner != $vmid;
        }

        # Compose plugin volname + volid
        my $volname = "vol-$zname-lun$lun";
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
    my $nqn = $scfg->{subsystem_nqn};
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
            [["id", "^", "$scfg->{dataset}/"]]
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
        next unless $ds_full =~ m{^\Q$scfg->{dataset}\E/(.+)$};
        my $zname = $1;  # e.g., "vm-998-disk-0"

        # Owner (vmid) from naming convention
        my $owner;
        $owner = $1 if $zname =~ /^vm-(\d+)-/;

        # Honor $vmid filter
        if (defined $vmid) {
            next if !defined $owner || $owner != $vmid;
        }

        # Compose volname using device_uuid
        my $device_uuid = $ns->{device_uuid} // next;
        my $volname = "vol-$zname-ns$device_uuid";
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

# ======== status(): dataset capacity ========
# total = quota (if set) else (written/used + available)
# avail = (quota - written/used) when quota present, else dataset available
# used  = dataset "written" (preferred), fallback to "used"
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    my $active = 1;
    my ($total, $avail, $used) = (0,0,0);
    eval {
        my $ds = _tn_dataset_get($scfg, $scfg->{dataset});
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

        # Distinguish between connectivity issues and actual errors
        if ($err =~ /timeout|timed out|connection refused|connection reset|unreachable|network|ssl.*error/i) {
            # Network/connectivity issue - mark as inactive (temporary)
            _log($scfg, 0, 'info', "[TrueNAS] status: storage '$storeid' marked inactive (connectivity issue): $err");
            $active = 0;
        } elsif ($err =~ /does not exist|ENOENT|InstanceNotFound/i) {
            # Dataset doesn't exist - this is a configuration error
            _log($scfg, 0, 'err', "[TrueNAS] status: storage '$storeid' configuration error (dataset not found): $err");
            $active = 0;
        } elsif ($err =~ /401|403|authentication|unauthorized|forbidden/i) {
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
    my ($scfg) = @_;

    my $iqn = $scfg->{target_iqn};
    my $portal = _normalize_portal($scfg->{discovery_portal});

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

    my $weight_name = "pve-weight-$target_suffix";
    my $weight_zname = $scfg->{dataset} . '/' . $weight_name;

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
        _log($scfg, 0, 'err', "[TrueNAS] Pre-flight: failed to query targets: $@");
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
    eval {
        my $ds = _tn_dataset_get($scfg, $weight_zname);
        $weight_exists = 1 if $ds;
    };

    if (!$weight_exists) {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: creating weight zvol $weight_zname (1GB)");
        eval {
            _tn_dataset_create($scfg, $weight_zname, 1048576, '64K'); # 1GB in KiB
        };
        if ($@) {
            _log($scfg, 0, 'err', "[TrueNAS] Pre-flight: failed to create weight zvol: $@");
            die "Failed to create weight zvol: $@\n";
        }
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight zvol created");
    } else {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight zvol already exists");
    }

    # Step 4: Create extent for weight zvol if it doesn't exist
    my $weight_extent_exists = 0;
    eval {
        my $extents = _tn_extents($scfg);
        for my $ext (@$extents) {
            if (($ext->{name} // '') eq $weight_name) {
                $weight_extent_exists = 1;
                last;
            }
        }
    };

    if (!$weight_extent_exists) {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: creating extent for weight zvol");
        eval {
            _tn_extent_create($scfg, $weight_name, $weight_zname);
        };
        if ($@) {
            _log($scfg, 0, 'err', "[TrueNAS] Pre-flight: failed to create weight extent: $@");
            die "Failed to create weight extent: $@\n";
        }
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight extent created");
    } else {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight extent already exists");
    }

    # Step 5: Ensure extent is mapped to THIS target (not just any target)
    my $weight_mapped = 0;
    my $weight_extent_id;
    eval {
        my $extents = _tn_extents($scfg);
        for my $ext (@$extents) {
            if (($ext->{name} // '') eq $weight_name) {
                $weight_extent_id = $ext->{id};
                last;
            }
        }

        if ($weight_extent_id) {
            my $targetextents = _tn_targetextents($scfg);
            for my $te (@$targetextents) {
                # Check if extent is mapped to THIS specific target
                if ($te->{extent} == $weight_extent_id && $te->{target} == $target_id) {
                    $weight_mapped = 1;
                    last;
                }
            }
        }
    };

    if (!$weight_mapped && $weight_extent_id && $target_id) {
        _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: mapping weight extent to target");
        eval {
            _tn_targetextent_create($scfg, $target_id, $weight_extent_id, 0);
        };
        if ($@) {
            if ($@ =~ /LUN ID is already being used|lunid.*already/i) {
                _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: LUN 0 in use, retrying weight mapping with auto-assigned LUN");
                eval { _tn_targetextent_create($scfg, $target_id, $weight_extent_id, undef); };
                if ($@) {
                    _log($scfg, 0, 'warning', "[TrueNAS] Pre-flight: failed to map weight extent with auto LUN: $@");
                } else {
                    _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight extent mapped to target (auto LUN)");
                }
            } else {
                _log($scfg, 0, 'warning', "[TrueNAS] Pre-flight: failed to map weight extent: $@");
            }
            # Non-fatal - extent may already be mapped
        } else {
            _log($scfg, 1, 'info', "[TrueNAS] Pre-flight: weight extent mapped to target");
        }
    }

    # Step 6: Verify target is now discoverable
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
        return 1;
    } else {
        _log($scfg, 0, 'warning', "[TrueNAS] Pre-flight: target $iqn not discoverable despite weight volume - may need manual intervention");
        # Don't die - let iSCSI login handle the error with better diagnostics
        return 0;
    }
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $mode = $scfg->{transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        # Run pre-flight check to ensure target is visible
        eval {
            _ensure_target_visible($scfg);
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
            _nvme_connect($scfg);
        };
        if ($@) {
            _log($scfg, 1, 'warning', "[TrueNAS] activate_storage: NVMe/TCP subsystem connection failed for $storeid: $@");
        }
    }

    return 1;
}

sub deactivate_storage { return 1; }

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    # Note: snapname is used for snapshot operations, we support snapshots via ZFS

    _log($scfg, 2, 'debug', "[TrueNAS] activate_volume: volname=$volname");

    my $mode = $scfg->{transport_mode} // 'iscsi';

    # Parse volname to extract metadata (LUN for iSCSI, UUID for NVMe)
    my (undef, $zname, $vmid, undef, undef, undef, undef, $metadata) = $class->parse_volname($volname);

    if ($mode eq 'iscsi') {
        _iscsi_login_all($scfg);
        if ($scfg->{use_multipath}) { run_command(['multipath','-r'], outfunc => sub {}); }

        # Wait for the specific LUN device to appear (up to ~20s, configurable)
        my $lun = $metadata;
        _log($scfg, 2, 'debug', "[TrueNAS] activate_volume: waiting for LUN $lun device");
        eval {
            my $dev = _device_for_lun($scfg, $lun);
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
        _nvme_connect($scfg);

        # Wait for the specific namespace device to appear (up to 5s)
        my $device_uuid = $metadata;
        _log($scfg, 2, 'debug', "[TrueNAS] activate_volume: waiting for device UUID $device_uuid");
        eval {
            my $dev = _nvme_device_for_uuid($scfg, $device_uuid, allow_reconnect => 1);
            _log($scfg, 2, 'debug', "[TrueNAS] activate_volume: device ready at $dev");
        };
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
sub deactivate_volume { return 1; }

# Note: snapshot functions are implemented above and MUST NOT be overridden here.

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname, $name, $format) = @_;

    die "clone not supported without snapshot\n" unless $snapname;
    die "only raw format is supported\n" if defined($format) && $format ne 'raw';

    _log($scfg, 1, 'info', "[TrueNAS] clone_image: volname=$volname, vmid=$vmid, snapname=$snapname");

    # Dispatch by transport mode
    my $mode = $scfg->{transport_mode} // 'iscsi';
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

    # Parse source volume information
    my (undef, $source_zname) = $class->parse_volname($volname);
    my $source_full = $scfg->{dataset} . '/' . $source_zname;
    my $source_snapshot = $source_full . '@' . $snapname;

    _log($scfg, 2, 'debug', "[TrueNAS] _clone_image_iscsi: cloning from $source_snapshot");

    # Determine target dataset name
    my $target_zname = $name;
    if (!$target_zname) {
        $target_zname = _find_free_disk_name($scfg, $vmid);
    }

    my $target_full = $scfg->{dataset} . '/' . $target_zname;

    # 1) Create ZFS clone from snapshot
    my $clone_result = _tn_dataset_clone($scfg, $source_snapshot, $target_full);

    # Wait for clone job to complete if it returned a job ID
    if (defined $clone_result && !ref($clone_result) && $clone_result =~ /^\d+$/) {
        _log($scfg, 1, 'info', "[TrueNAS] _clone_image_iscsi: waiting for clone job $clone_result to complete");
        my $job_result = _wait_for_job_completion($scfg, $clone_result, 30);
        unless ($job_result->{success}) {
            die "Failed to clone zvol $source_snapshot to $target_full: " . ($job_result->{error} // 'Unknown error') . "\n";
        }
        _log($scfg, 1, 'info', "[TrueNAS] _clone_image_iscsi: clone completed successfully");
    }

    # 2) Create iSCSI extent for the cloned zvol
    my $zvol_path = 'zvol/' . $target_full;

    # Check if extent for this zvol already exists (by disk path)
    my $extents = _tn_extents($scfg) // [];
    my ($existing_extent) = grep { ($_->{disk} // '') eq $zvol_path } @$extents;

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

        my $ext = eval {
            _api_call(
                $scfg,
                'iscsi.extent.create',
                [ $extent_payload ],
            );
        };
        if ($@) {
            # Cleanup: delete the zvol clone if extent creation failed
            eval { _tn_dataset_delete($scfg, $target_full) };
            die "Failed to create iSCSI extent for clone: $@\n";
        }
        $extent_id = ref($ext) eq 'HASH' ? $ext->{id} : $ext;
    }

    die "failed to create extent for clone $target_zname\n" if !defined $extent_id;

    # 3) Map extent to target
    my $target_id = _resolve_target_id($scfg);

    # First check if this mapping already exists
    my $maps = _tn_targetextents($scfg) // [];
    my ($existing_map) = grep {
        (($_->{target}//-1) == $target_id) && (($_->{extent}//-1) == $extent_id)
    } @$maps;

    my $lun;
    if (!$existing_map) {
        # Mapping doesn't exist, create it
        _log($scfg, 2, 'debug', "[TrueNAS] _clone_image_iscsi: creating target-extent mapping for extent_id=$extent_id to target_id=$target_id");
        my $tx_payload = { target => $target_id, extent => $extent_id };
        my $tx = eval {
            _api_call(
                $scfg,
                'iscsi.targetextent.create',
                [ $tx_payload ],
            );
        };
        if ($@) {
            # Cleanup: delete extent and zvol if mapping creation failed
            eval {
                _api_call($scfg, 'iscsi.extent.delete', [$extent_id]);
            };
            eval { _tn_dataset_delete($scfg, $target_full) };
            die "Failed to create target-extent mapping for clone: $@\n";
        }

        # Extract LUN directly from create response (avoids a re-fetch query)
        $lun = ref($tx) eq 'HASH' ? $tx->{lunid} : undef;

        # Invalidate cache after creating new mapping
        _clear_cache($scfg->{storeid} || 'unknown');

        # Fallback: re-fetch if create response didn't include lunid
        if (!defined $lun) {
            $maps = _tn_targetextents($scfg) // [];
            ($existing_map) = grep {
                (($_->{target}//-1) == $target_id) && (($_->{extent}//-1) == $extent_id)
            } @$maps;
            $lun = $existing_map->{lunid} if $existing_map;
        }
    } else {
        _log($scfg, 1, 'info', "[TrueNAS] _clone_image_iscsi: target-extent mapping already exists for extent_id=$extent_id (LUN $existing_map->{lunid})");
        $lun = $existing_map->{lunid};
    }

    die "could not determine assigned LUN for clone $target_zname\n" if !defined $lun;

    # 5) Return clone volume name — defer initiator rescan after lock release
    my $clone_volname = "vol-$target_zname-lun$lun";

    my $deferred_scfg = $scfg;
    _defer_after_lock(sub {
        _log($deferred_scfg, 2, 'debug', "[TrueNAS] clone_image_iscsi deferred: refreshing initiator view");
        eval { _try_run(['iscsiadm','-m','session','-R'], "iscsi session rescan failed"); };
        if ($deferred_scfg->{use_multipath}) {
            eval { _try_run(['multipath','-r'], "multipath reload failed"); };
        }
        eval { run_command(['udevadm','settle'], outfunc => sub {}); };
    });

    return $clone_volname;
}

# NVMe-specific clone implementation
sub _clone_image_nvme {
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname, $name) = @_;

    # Parse source volume information
    my (undef, $source_zname) = $class->parse_volname($volname);
    my $source_full = $scfg->{dataset} . '/' . $source_zname;
    my $source_snapshot = $source_full . '@' . $snapname;

    _log($scfg, 2, 'debug', "[TrueNAS] _clone_image_nvme: cloning from $source_snapshot");

    # Determine target dataset name
    my $target_zname = $name;
    if (!$target_zname) {
        $target_zname = _find_free_disk_name($scfg, $vmid);
    }

    my $target_full = $scfg->{dataset} . '/' . $target_zname;

    # 1) Create ZFS clone from snapshot
    my $clone_result = _tn_dataset_clone($scfg, $source_snapshot, $target_full);

    # Wait for clone job to complete if it returned a job ID
    if (defined $clone_result && !ref($clone_result) && $clone_result =~ /^\d+$/) {
        _log($scfg, 1, 'info', "[TrueNAS] _clone_image_nvme: waiting for clone job $clone_result to complete");
        my $job_result = _wait_for_job_completion($scfg, $clone_result, 30);
        unless ($job_result->{success}) {
            die "Failed to clone zvol $source_snapshot to $target_full: " . ($job_result->{error} // 'Unknown error') . "\n";
        }
        _log($scfg, 1, 'info', "[TrueNAS] _clone_image_nvme: clone completed successfully");
    }

    # Verify cloned zvol exists and get its properties
    my $cloned_ds = eval { _tn_dataset_get($scfg, $target_full) };
    if (!$cloned_ds) {
        die "Failed to verify cloned zvol $target_full: $@\n";
    }
    my $cloned_size = _normalize_value($cloned_ds->{volsize});
    _log($scfg, 1, 'info', "[TrueNAS] _clone_image_nvme: verified cloned zvol size = $cloned_size bytes");

    # 2) Create NVMe namespace for the cloned zvol
    my $nqn = $scfg->{subsystem_nqn};

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

    my $ns = eval {
        _api_call_write($scfg, 'nvmet.namespace.create', [ $ns_payload ]);
    };
    if ($@) {
        # Cleanup: delete the zvol clone if namespace creation failed
        eval { _tn_dataset_delete($scfg, $target_full) };
        die "Failed to create NVMe namespace for clone: $@\n";
    }

    my $device_uuid = $ns->{device_uuid} // die "No device_uuid returned from namespace creation\n";

    # 3) Return clone volume name — defer device discovery after lock release.
    # The namespace and dataset are created successfully at this point.
    # activate_volume handles authoritative device discovery before any VM uses the disk.
    my $clone_volname = "vol-$target_zname-ns$device_uuid";

    my $deferred_scfg = $scfg;
    my $deferred_uuid = $device_uuid;
    _defer_after_lock(sub {
        _log($deferred_scfg, 2, 'debug', "[TrueNAS] clone_image_nvme deferred: discovering device for UUID $deferred_uuid");
        usleep(200_000);  # 200ms initial settle
        eval { run_command(['udevadm', 'settle'], outfunc => sub {}, errfunc => sub {}) };
        eval { _nvme_rescan_subsystem_controllers($deferred_scfg) };
        my $dev = eval { _nvme_device_for_uuid($deferred_scfg, $deferred_uuid, allow_reconnect => 1) };
        if ($dev) {
            _log($deferred_scfg, 1, 'info', "[TrueNAS] clone_image_nvme deferred: device ready at $dev");
        } else {
            _log($deferred_scfg, 1, 'info', "[TrueNAS] clone_image_nvme deferred: device not yet visible (activate_volume will handle)");
        }
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

sub create_base { die "base images not supported"; }

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
    my $lock_timeout = $scfg->{storage_lock_timeout} // DEFAULT_LOCK_TIMEOUT;

    # Override the timeout if not explicitly provided or if it's the Proxmox default
    $timeout = $lock_timeout if !defined($timeout) || $timeout < $lock_timeout;

    # Localize @_deferred_work for re-entrancy safety (nested lock calls get their own queue)
    local @_deferred_work = ();

    # Run the locked callback via parent implementation
    my $result = $class->SUPER::cluster_lock_storage($storeid, $shared, $timeout, $func, @param);

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
