#!/usr/bin/env bash
#
# NVMe Namespace Publication Diagnostic
#
# Diagnoses why newly created NVMe namespaces may not appear on the Proxmox host.
# Related: https://github.com/truenas/truenas-proxmox-plugin/issues/12
#
# Usage: ./diag-nvme-namespace-publish.sh STORAGE_ID
#
# This script must be run on a Proxmox node with the TrueNAS plugin installed.
# It creates a temporary 1GB test zvol and namespace, checks for publication,
# and cleans up afterward.
#
# WARNING: This script will temporarily create and delete a test zvol on your
# TrueNAS storage. If AEN and ns-rescan both fail, the script will offer a
# disconnect/reconnect test — this WILL disrupt running VMs using this storage.
# You will be prompted before any disruptive action.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 STORAGE_ID"
    echo "  STORAGE_ID - The NVMe/TCP TrueNAS storage ID from storage.cfg"
    exit 1
fi

STORAGE_ID="$1"
NODE=$(hostname)
DIAG_PREFIX="diag-ns-publish"
DIAG_ZVOL_SUFFIX="${DIAG_PREFIX}-$(date +%s)"

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       NVMe Namespace Publication Diagnostic                        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Read storage config ──────────────────────────────────────────
echo "== Step 1: Storage Configuration =="
echo ""

SCFG=$(perl -e '
use lib "/usr/share/perl5";
use PVE::Storage;
use JSON::PP;
my $cfg = PVE::Storage::config();
my $scfg = $cfg->{ids}{"'"$STORAGE_ID"'"};
die "Storage '"$STORAGE_ID"' not found\n" unless $scfg;
print encode_json($scfg);
' 2>&1) || { echo "ERROR: $SCFG"; exit 1; }

TRANSPORT=$(echo "$SCFG" | perl -MJSON::PP -e '$s=decode_json(<STDIN>); print $s->{tn_transport_mode}//"iscsi"')
if [[ "$TRANSPORT" != "nvme-tcp" ]]; then
    echo "ERROR: Storage $STORAGE_ID uses tn_transport_mode=$TRANSPORT, not nvme-tcp"
    exit 1
fi

SUBSYSTEM_NQN=$(echo "$SCFG" | perl -MJSON::PP -e '$s=decode_json(<STDIN>); print $s->{tn_subsystem_nqn}//"?"')
DATASET=$(echo "$SCFG" | perl -MJSON::PP -e '$s=decode_json(<STDIN>); print $s->{tn_dataset}//"?"')
echo "  Storage ID:     $STORAGE_ID"
echo "  Transport:      $TRANSPORT"
echo "  Subsystem NQN:  $SUBSYSTEM_NQN"
echo "  Dataset:        $DATASET"
echo ""

# ── Step 2: TrueNAS system info ──────────────────────────────────────────
echo "== Step 2: TrueNAS System Info =="
echo ""

perl -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::TrueNASPlugin;
use PVE::Storage;
use JSON::PP;
my $cfg = PVE::Storage::config();
my $scfg = $cfg->{ids}{"'"$STORAGE_ID"'"};

my $info = PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, "system.info", []);
print "  TrueNAS Version: $info->{version}\n";
print "  Hostname:        $info->{hostname}\n";

my $global = PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, "nvmet.global.config", []);
my $kernel_mode = $global->{kernel} ? "YES (in-kernel nvmet)" : "NO (userspace)";
print "  Kernel NVMeT:    $kernel_mode\n";
print "  ANA:             " . ($global->{ana} ? "enabled" : "disabled") . "\n";
print "  Base NQN:        " . ($global->{basenqn} // "n/a") . "\n";
' 2>&1 || echo "  WARNING: Could not query TrueNAS system info"
echo ""

# ── Step 3: Subsystem and port binding check ─────────────────────────────
echo "== Step 3: Subsystem & Port Bindings =="
echo ""

perl -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::TrueNASPlugin;
use PVE::Storage;
use JSON::PP;
my $cfg = PVE::Storage::config();
my $scfg = $cfg->{ids}{"'"$STORAGE_ID"'"};

my $subsys = PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, "nvmet.subsys.query", [
    [["subnqn", "=", $scfg->{tn_subsystem_nqn}]]
]);
if (!$subsys || !@$subsys) {
    print "  ERROR: Subsystem not found on TrueNAS!\n";
    exit 1;
}
my $s = $subsys->[0];
print "  Subsystem:       $s->{name} (id=$s->{id})\n";
print "  Allow Any Host:  " . ($s->{allow_any_host} ? "yes" : "NO — may need host authorization") . "\n";

my $port_subsys = PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, "nvmet.port_subsys.query", []);
my @bindings = grep { $_->{subsys}{id} == $s->{id} } @$port_subsys;
if (!@bindings) {
    print "  PORT BINDINGS:   NONE — subsystem is not bound to any port!\n";
    print "  >>> This means no host can see namespaces even if they exist.\n";
} else {
    print "  Port Bindings:   " . scalar(@bindings) . " port(s)\n";
    for my $b (@bindings) {
        my $p = $b->{port};
        print "    - Port $p->{id}: $p->{addr_traddr}:$p->{addr_trsvcid} ($p->{addr_trtype})\n";
    }
}

my $sessions = PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, "nvmet.global.sessions", []);
my @our_sessions = grep { $_->{subsys_id} == $s->{id} } @$sessions;
print "  Active Sessions: " . scalar(@our_sessions) . "\n";
for my $sess (@our_sessions) {
    print "    - ctrl=$sess->{ctrl} from $sess->{host_traddr} on port $sess->{port_id}\n";
}
' 2>&1 || echo "  WARNING: Could not query subsystem info"
echo ""

# ── Step 4: Host-side NVMe state ─────────────────────────────────────────
echo "== Step 4: Host-Side NVMe State =="
echo ""

# Find our subsystem
SUBSYS_DIR=""
for d in /sys/class/nvme-subsystem/nvme-subsys*; do
    if [[ -f "$d/subsysnqn" ]]; then
        NQN_VAL=$(cat "$d/subsysnqn" 2>/dev/null || true)
        if [[ "$NQN_VAL" == "$SUBSYSTEM_NQN" ]]; then
            SUBSYS_DIR="$d"
            break
        fi
    fi
done

if [[ -z "$SUBSYS_DIR" ]]; then
    echo "  ERROR: Subsystem $SUBSYSTEM_NQN not found in /sys/class/nvme-subsystem/"
    echo "  The host is not connected to this subsystem."
    exit 1
fi

SUBSYS_NAME=$(basename "$SUBSYS_DIR")
echo "  Subsystem:   $SUBSYS_NAME"

# Count controllers and namespaces
CTRL_COUNT=0
NS_COUNT=0
for entry in "$SUBSYS_DIR"/nvme*; do
    name=$(basename "$entry")
    if [[ "$name" =~ ^nvme[0-9]+$ ]]; then
        CTRL_COUNT=$((CTRL_COUNT + 1))
    elif [[ "$name" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
        NS_COUNT=$((NS_COUNT + 1))
    fi
done
echo "  Controllers: $CTRL_COUNT"
echo "  Namespaces:  $NS_COUNT (visible on this host)"
echo ""

# ── Step 5: Capture dmesg baseline ───────────────────────────────────────
DMESG_BEFORE=$(dmesg | wc -l)

# ── Step 6: Create test namespace and observe ────────────────────────────
echo "== Step 5: Namespace Publication Test =="
echo ""

RESULT=$(perl -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::TrueNASPlugin;
use PVE::Storage;
use JSON::PP;
use Time::HiRes qw(time usleep);
my $cfg = PVE::Storage::config();
my $scfg = $cfg->{ids}{"'"$STORAGE_ID"'"};
my $dataset = $scfg->{tn_dataset};
my $zvol_name = "'"$DIAG_ZVOL_SUFFIX"'";
my $full_ds = "$dataset/$zvol_name";
my $zvol_path = "zvol/$full_ds";

# Create test zvol
print "  Creating test zvol: $full_ds\n";
eval { PVE::Storage::Custom::TrueNASPlugin::_tn_dataset_create($scfg, $full_ds, 1048576, "64K"); };
if ($@) { print "  ERROR creating zvol: $@\n"; exit 1; }

# Get subsystem ID
my $subsystems = PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, "nvmet.subsys.query", [
    [["subnqn", "=", $scfg->{tn_subsystem_nqn}]]
]);
my $subsys_id = $subsystems->[0]{id};

# Count API namespaces before
my $all_ns_before = PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, "nvmet.namespace.query", [[]]);
my @ns_before = grep { ($_->{subsys}{id} // -1) == $subsys_id } @$all_ns_before;
print "  API namespaces before: " . scalar(@ns_before) . "\n";

# Snapshot host namespace count before
my @host_before = glob("/sys/class/nvme-subsystem/'"$SUBSYS_NAME"'/nvme*n*");
my $host_count_before = scalar(@host_before);
print "  Host namespaces before: $host_count_before\n";

# Create namespace
print "  Creating test namespace...\n";
my $t0 = time();
my $ns = PVE::Storage::Custom::TrueNASPlugin::_api_call_write($scfg, "nvmet.namespace.create", [{
    device_type => "ZVOL",
    device_path => $zvol_path,
    subsys_id => $subsys_id,
    enabled => \1,
}]);
my $create_ms = int((time() - $t0) * 1000);
my $nsid = $ns->{nsid};
my $uuid = $ns->{device_uuid};
my $nguid = $ns->{device_nguid} // "n/a";
print "  Created in ${create_ms}ms: NSID=$nsid, UUID=$uuid, NGUID=$nguid\n";

# Verify it shows up in API
my $all_ns_after = PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, "nvmet.namespace.query", [[]]);
my @ns_after = grep { ($_->{subsys}{id} // -1) == $subsys_id } @$all_ns_after;
print "  API namespaces after: " . scalar(@ns_after) . "\n";

# Monitor host namespace count over time (5 seconds, checking every 200ms)
print "\n  Monitoring host namespace appearance:\n";
my $appeared_at = -1;
for (my $i = 0; $i < 25; $i++) {
    usleep(200_000);
    my @host_now = glob("/sys/class/nvme-subsystem/'"$SUBSYS_NAME"'/nvme*n*");
    my $host_count_now = scalar(@host_now);
    if ($host_count_now > $host_count_before) {
        $appeared_at = ($i + 1) * 200;
        print "  +${appeared_at}ms: NEW namespace appeared! (count: $host_count_before -> $host_count_now)\n";

        # Check if it has the right NGUID
        my %before_set = map { $_ => 1 } @host_before;
        my @new_devs = grep { !$before_set{$_} } @host_now;
        for my $nd (@new_devs) {
            my $dev_name = $nd;
            $dev_name =~ s|.*/||;
            my $dev_nguid = "";
            if (open(my $fh, "<", "$nd/nguid")) {
                $dev_nguid = <$fh>;
                chomp $dev_nguid;
                close $fh;
            }
            print "  New device: $dev_name, NGUID=$dev_nguid\n";
        }
        last;
    }
    if ($i == 4) { print "  +1000ms: not yet visible ($host_count_now namespaces)\n"; }
    if ($i == 14) { print "  +3000ms: not yet visible ($host_count_now namespaces)\n"; }
}

my $rescan_count = $host_count_before;

if ($appeared_at == -1) {
    print "  +5000ms: namespace DID NOT APPEAR on host\n\n";

    # Try ns-rescan
    print "  Attempting ns-rescan on all controllers...\n";
    for my $ctrl (glob("/sys/class/nvme-subsystem/'"$SUBSYS_NAME"'/nvme[0-9]*")) {
        next unless -d $ctrl;
        my $ctrl_name = $ctrl;
        $ctrl_name =~ s|.*/||;
        next unless $ctrl_name =~ /^nvme(\d+)$/;
        my $dev = "/dev/nvme$1";
        system("nvme ns-rescan $dev 2>&1");
        print "  Rescanned $dev\n";
    }
    usleep(1_000_000);
    my @host_rescan = glob("/sys/class/nvme-subsystem/'"$SUBSYS_NAME"'/nvme*n*");
    $rescan_count = scalar(@host_rescan);
    if ($rescan_count > $host_count_before) {
        print "  ns-rescan WORKED! Namespace appeared after rescan ($host_count_before -> $rescan_count)\n";
        print "  DIAGNOSIS: TrueNAS is not sending AEN notifications.\n";
        print "  WORKAROUND: The plugin can add ns-rescan after namespace creation.\n";
    } else {
        print "  ns-rescan did NOT help ($rescan_count namespaces, unchanged)\n";
    }
    $appeared_at = -1;
}

# Output result code for the shell script
if ($appeared_at > 0) {
    print "\n  RESULT=AUTO_APPEARED\n";
} elsif ($rescan_count > $host_count_before) {
    print "\n  RESULT=RESCAN_WORKED\n";
} else {
    print "\n  RESULT=RESCAN_FAILED\n";
}

# Store namespace ID for cleanup
print "  CLEANUP_NS_ID=$ns->{id}\n";
print "  CLEANUP_ZVOL=$full_ds\n";
' 2>&1)

echo "$RESULT"
echo ""

# ── Step 6: Check kernel dmesg for AEN ───────────────────────────────────
echo "== Step 6: Kernel Messages (AEN check) =="
echo ""

DMESG_AFTER=$(dmesg | wc -l)
NEW_LINES=$((DMESG_AFTER - DMESG_BEFORE))
if [[ $NEW_LINES -gt 0 ]]; then
    dmesg | tail -n "$NEW_LINES" | grep -iE "nvme|rescan|namespace|aen" | head -20 || echo "  No NVMe-related kernel messages"
else
    echo "  No new kernel messages"
fi
echo ""

# ── Step 7: Disconnect/reconnect test (only if AEN and ns-rescan both failed) ─
if echo "$RESULT" | grep -q "RESCAN_FAILED"; then
    echo "== Step 7: Disconnect/Reconnect Test =="
    echo ""
    echo "  WARNING: This step will disconnect ALL NVMe namespaces for this subsystem."
    echo "  Any running VMs using $STORAGE_ID storage will lose access to their disks"
    echo "  until the reconnect completes."
    echo ""
    read -r -p "  Proceed with disconnect/reconnect test? [y/N] " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo ""
        echo "  Disconnecting subsystem..."
        nvme disconnect -n "$SUBSYSTEM_NQN" 2>&1 || true
        sleep 1

        # Extract portal info
        PORTAL=$(echo "$SCFG" | perl -MJSON::PP -e '$s=decode_json(<STDIN>); print $s->{discovery_portal}//"?"')
        PORTAL_HOST=$(echo "$PORTAL" | sed 's/:.*//')
        PORTAL_PORT=$(echo "$PORTAL" | sed 's/.*://')

        echo "  Reconnecting to $PORTAL_HOST:$PORTAL_PORT..."
        nvme connect -t tcp -n "$SUBSYSTEM_NQN" -a "$PORTAL_HOST" -s "$PORTAL_PORT" 2>&1 || true

        # Check for additional portals
        PORTALS=$(echo "$SCFG" | perl -MJSON::PP -e '$s=decode_json(<STDIN>); print $s->{portals}//"?"')
        if [[ "$PORTALS" != "?" && -n "$PORTALS" ]]; then
            IFS=',' read -ra EXTRA_PORTALS <<< "$PORTALS"
            for p in "${EXTRA_PORTALS[@]}"; do
                p=$(echo "$p" | tr -d ' ')
                PH=$(echo "$p" | sed 's/:.*//')
                PP=$(echo "$p" | sed 's/.*://')
                echo "  Reconnecting to $PH:$PP..."
                nvme connect -t tcp -n "$SUBSYSTEM_NQN" -a "$PH" -s "$PP" 2>&1 || true
            done
        fi

        sleep 2
        udevadm settle 2>/dev/null || true

        NEW_NS_COUNT=0
        for entry in /sys/class/nvme-subsystem/nvme-subsys*/nvme*n*; do
            [[ -e "$entry" ]] || continue
            ENTRY_NQN=$(cat "$(dirname "$entry")/subsysnqn" 2>/dev/null || true)
            if [[ "$ENTRY_NQN" == "$SUBSYSTEM_NQN" ]]; then
                NEW_NS_COUNT=$((NEW_NS_COUNT + 1))
            fi
        done
        echo "  Namespaces after reconnect: $NEW_NS_COUNT (was: $NS_COUNT before test)"
        echo ""

        if [[ $NEW_NS_COUNT -gt $NS_COUNT ]]; then
            echo "  DIAGNOSIS: Disconnect/reconnect resolved the issue."
            echo "  TrueNAS is creating namespaces in its database but NOT pushing them"
            echo "  to the kernel nvmet configfs, OR the kernel nvmet is not sending AENs"
            echo "  to connected hosts."
            echo ""
            echo "  POSSIBLE CAUSES:"
            echo "    1. TrueNAS middleware bug — namespace created in DB but not in configfs"
            echo "    2. Kernel nvmet AEN disabled or broken on TrueNAS host"
            echo "    3. TrueNAS version-specific issue (check for updates)"
            echo ""
            echo "  NEXT STEPS:"
            echo "    - Report TrueNAS version and this diagnostic output to the plugin issue"
            echo "    - Check if TrueNAS has pending updates"
            echo "    - SSH to TrueNAS and check if namespaces appear in"
            echo "      /sys/kernel/config/nvmet/subsystems/<name>/namespaces/ after API create"
        fi
    else
        echo ""
        echo "  Skipped disconnect/reconnect test."
        echo ""
        echo "  DIAGNOSIS: Neither AEN nor ns-rescan made the namespace visible."
        echo "  To complete the diagnostic, re-run this script when no VMs are using"
        echo "  this storage and answer 'y' to the disconnect prompt."
    fi
fi

# ── Cleanup ──────────────────────────────────────────────────────────────
echo "== Cleanup =="
echo ""

NS_ID=$(echo "$RESULT" | grep "CLEANUP_NS_ID=" | sed 's/.*CLEANUP_NS_ID=//')
ZVOL=$(echo "$RESULT" | grep "CLEANUP_ZVOL=" | sed 's/.*CLEANUP_ZVOL=//')

if [[ -n "$NS_ID" && -n "$ZVOL" ]]; then
    perl -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::TrueNASPlugin;
use PVE::Storage;
my $cfg = PVE::Storage::config();
my $scfg = $cfg->{ids}{"'"$STORAGE_ID"'"};
eval { PVE::Storage::Custom::TrueNASPlugin::_api_call_write($scfg, "nvmet.namespace.delete", ['"$NS_ID"']); };
print "  Namespace deleted" . ($@ ? " (error: $@)" : "") . "\n";
eval { PVE::Storage::Custom::TrueNASPlugin::_api_call_write($scfg, "pool.dataset.delete", ["'"$ZVOL"'"]); };
print "  Zvol deleted" . ($@ ? " (error: $@)" : "") . "\n";
' 2>&1
else
    echo "  WARNING: Could not extract cleanup IDs — manual cleanup may be needed"
    echo "  Look for zvols matching: $DATASET/$DIAG_PREFIX-*"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Diagnostic complete. Please share this output in GitHub issue #12"
echo "════════════════════════════════════════════════════════════════════"
