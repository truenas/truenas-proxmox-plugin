#!/usr/bin/perl
# Fix 1: alloc_image idempotency
#
# _alloc_image_iscsi and _alloc_image_nvme must check whether an extent
# (iSCSI) or namespace (NVMe/TCP) already targets the zvol path being
# allocated, and reuse it if found, rather than colliding on the
# deterministic extent name (sha1_hex of dataset/zname). Without the
# check, an orphan extent from a prior failed cleanup (or a concurrent
# node that got there first) bricks every subsequent alloc for the same
# VMID/disk-index -- see test_run5/truenas-2026-08-06 cluster runs where
# the failure signature was:
#     [EINVAL] iscsi_extent_create.name: Extent name must be unique
#
# This test:
#   1. Pre-cleans any leftovers from a previous aborted run.
#   2. Creates a zvol at the target path.
#   3. Creates an iSCSI extent (or NVMe namespace) referencing that zvol.
#      This is the orphan.
#   4. Deletes the zvol -- the extent/namespace now dangles (its `disk`
#      field points at a nonexistent zvol, exactly the shape a failed
#      free_image would leave behind).
#   5. Runs pvesm alloc for the same zname. Fix 1 must find the orphan
#      by disk path and reuse it instead of trying to create a duplicate.
#   6. Verifies exactly one extent/namespace ends up referencing the
#      zvol path (no duplicate), and that its id matches the seeded
#      orphan id (proves reuse, not silent replacement).
#
# Runs against a real TrueNAS. Uses TEST_VMID_BASE + 40 for its VMID.
# On a plugin build WITHOUT Fix 1 the alloc step dies with the "Extent
# name must be unique" error and the reuse assertions fail loudly.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Digest::SHA qw(sha1_hex);
use JSON::PP;
use RateLimit::Harness qw(env_require env_get new_audit_conn test_scfg say_diag);

my $sid  = env_require('STORAGE_ID');
my $vmid = env_get('TEST_VMID_BASE', 99000) + 40;

my $scfg = test_scfg();
my $mode = $scfg->{tn_transport_mode} // $scfg->{transport} // 'iscsi';
say_diag("transport mode: $mode");
say_diag("using vmid: $vmid");

if ($mode ne 'iscsi' && $mode ne 'nvme-tcp') {
    plan skip_all => "unsupported transport '$mode'";
}
if ($mode eq 'nvme-tcp' && !$scfg->{tn_subsystem_nqn}) {
    plan skip_all => "nvme-tcp mode but tn_subsystem_nqn not configured";
}

plan tests => 6;

require PVE::Storage::Custom::TrueNASPlugin;

# test_scfg() re-keys a subset of the storage.cfg fields but does not
# include tn_dataset. Fetch it directly via pvesh so the test doesn't
# require an extra env var.
my $tn_dataset = $scfg->{tn_dataset};
if (!$tn_dataset) {
    my $json = `pvesh get /storage/$sid --output-format json 2>/dev/null`;
    if ($? == 0) {
        my $raw = decode_json($json);
        $tn_dataset = $raw->{tn_dataset};
    }
}
$tn_dataset //= env_require('TN_DATASET');
my $zname      = "vm-$vmid-disk-0";
my $full_ds    = "$tn_dataset/$zname";
my $zvol_path  = "zvol/$full_ds";

new_audit_conn();

# ---------------------------------------------------------------------
# 0. Pre-clean: remove anything from a prior aborted run at this vmid.
# ---------------------------------------------------------------------
sub _pre_clean {
    if ($mode eq 'iscsi') {
        my $extents = eval {
            PVE::Storage::Custom::TrueNASPlugin::_api_call(
                $scfg, 'iscsi.extent.query', [])
        } // [];
        for my $e (@$extents) {
            next unless ($e->{disk} // '') eq $zvol_path;
            # Also drop any target-extent mapping first
            my $txs = eval {
                PVE::Storage::Custom::TrueNASPlugin::_api_call(
                    $scfg, 'iscsi.targetextent.query',
                    [[["extent", "=", $e->{id}]]])
            } // [];
            for my $t (@$txs) {
                eval {
                    PVE::Storage::Custom::TrueNASPlugin::_api_call(
                        $scfg, 'iscsi.targetextent.delete', [$t->{id}])
                };
            }
            eval {
                PVE::Storage::Custom::TrueNASPlugin::_api_call(
                    $scfg, 'iscsi.extent.delete', [$e->{id}])
            };
        }
    } else {
        my $ns = eval {
            PVE::Storage::Custom::TrueNASPlugin::_api_call(
                $scfg, 'nvmet.namespace.query',
                [[["device_path", "=", $zvol_path]]])
        } // [];
        for my $n (@$ns) {
            eval {
                PVE::Storage::Custom::TrueNASPlugin::_api_call(
                    $scfg, 'nvmet.namespace.delete', [$n->{id}])
            };
        }
    }
    eval {
        PVE::Storage::Custom::TrueNASPlugin::_api_call(
            $scfg, 'pool.dataset.delete', [$full_ds])
    };
    # ignore result -- may not have existed
}
_pre_clean();

# ---------------------------------------------------------------------
# 1. Seed: create zvol so we can attach a legitimate extent/namespace.
# ---------------------------------------------------------------------
eval {
    PVE::Storage::Custom::TrueNASPlugin::_api_call(
        $scfg, 'pool.dataset.create', [{
            name    => $full_ds,
            type    => 'VOLUME',
            volsize => 1024 * 1024 * 1024,   # 1 GiB
            sparse  => JSON::PP::true,
        }]);
};
ok(!$@, "seed: created zvol $full_ds") or do {
    diag("zvol create failed: $@");
    _pre_clean();
    done_testing();
    exit;
};

# ---------------------------------------------------------------------
# 2. Seed the orphan extent (iSCSI) or namespace (NVMe).
#    Use the same deterministic extent name shape _generate_extent_name
#    would use, so the test also proves Fix 1 wins over a name-identical
#    collision, not just a name-different one.
# ---------------------------------------------------------------------
my $orphan_id;
if ($mode eq 'iscsi') {
    my $extent_name = "$zname-" . substr(sha1_hex($full_ds), 0, 8);
    my $r = eval {
        PVE::Storage::Custom::TrueNASPlugin::_api_call(
            $scfg, 'iscsi.extent.create', [{
                name         => $extent_name,
                type         => 'DISK',
                disk         => $zvol_path,
                insecure_tpc => JSON::PP::true,
            }]);
    };
    if ($@) {
        diag("seed extent create failed: $@");
        _pre_clean();
        fail("seed: could not create orphan extent");
        done_testing();
        exit;
    }
    $orphan_id = ref($r) eq 'HASH' ? $r->{id} : $r;
} else {
    my $subs = PVE::Storage::Custom::TrueNASPlugin::_api_call(
        $scfg, 'nvmet.subsys.query',
        [[["subnqn", "=", $scfg->{tn_subsystem_nqn}]]]) // [];
    unless (@$subs) {
        _pre_clean();
        fail("seed: subsystem $scfg->{tn_subsystem_nqn} not found on TN");
        done_testing();
        exit;
    }
    my $r = eval {
        PVE::Storage::Custom::TrueNASPlugin::_api_call(
            $scfg, 'nvmet.namespace.create', [{
                subsys_id   => $subs->[0]{id},
                device_type => 'ZVOL',
                device_path => $zvol_path,
                enabled     => JSON::PP::true,
            }]);
    };
    if ($@) {
        diag("seed namespace create failed: $@");
        _pre_clean();
        fail("seed: could not create orphan namespace");
        done_testing();
        exit;
    }
    $orphan_id = ref($r) eq 'HASH' ? $r->{id} : $r;
}
ok(defined $orphan_id, "seed: orphan " .
    ($mode eq 'iscsi' ? "extent" : "namespace") . " created id=$orphan_id");

# ---------------------------------------------------------------------
# 3. Delete the zvol. The extent/namespace now dangles: its disk field
#    still says zvol/<dataset>/vm-<vmid>-disk-0, but no such zvol exists.
#    This is the shape a failed free_image leaves behind.
# ---------------------------------------------------------------------
eval {
    PVE::Storage::Custom::TrueNASPlugin::_api_call(
        $scfg, 'pool.dataset.delete', [$full_ds])
};
ok(!$@, "seed: zvol deleted (orphan extent/namespace now dangles)")
    or diag("zvol delete failed: $@");

# Diagnostic: verify the orphan still exists on TN post-zvol-delete,
# and what its `disk` / `device_path` field looks like now. If TN
# cascade-deletes or clears the field, Fix 1's grep-by-disk-path
# cannot possibly reuse -- we need a different anchor.
if ($mode eq 'iscsi') {
    my $e = eval {
        PVE::Storage::Custom::TrueNASPlugin::_api_call(
            $scfg, 'iscsi.extent.query', [[["id", "=", $orphan_id]]])
    } // [];
    if (@$e) {
        say_diag("post-delete orphan extent id=$orphan_id still on TN; disk=[" .
            ($e->[0]{disk} // '<undef>') . "]");
    } else {
        say_diag("post-delete orphan extent id=$orphan_id CASCADE-DELETED by TN");
    }
} else {
    my $n = eval {
        PVE::Storage::Custom::TrueNASPlugin::_api_call(
            $scfg, 'nvmet.namespace.query', [[["id", "=", $orphan_id]]])
    } // [];
    if (@$n) {
        say_diag("post-delete orphan namespace id=$orphan_id still on TN; device_path=[" .
            ($n->[0]{device_path} // '<undef>') . "]");
    } else {
        say_diag("post-delete orphan namespace id=$orphan_id CASCADE-DELETED by TN");
    }
}

# ---------------------------------------------------------------------
# 4. Exercise: pvesm alloc for the same zname.
#    Fix 1 must query existing extents/namespaces, find the orphan by
#    disk path, and reuse it -- no collision on the deterministic name.
# ---------------------------------------------------------------------
say_diag("pvesm alloc $sid $vmid $zname 1G");
my $out = `pvesm alloc $sid $vmid $zname 1G 2>&1`;
my $rc  = $? >> 8;
chomp $out;
say_diag("pvesm alloc rc=$rc output=[$out]");

ok($rc == 0, "pvesm alloc succeeds (no 'name must be unique' collision)")
    or diag("pvesm alloc output: $out");

# ---------------------------------------------------------------------
# 5. Verify reuse: exactly one extent/namespace references the zvol path,
#    and its id matches the seed. Anything else = Fix 1 did not fire.
# ---------------------------------------------------------------------
my @matching;
if ($mode eq 'iscsi') {
    my $extents = PVE::Storage::Custom::TrueNASPlugin::_api_call(
        $scfg, 'iscsi.extent.query', []) // [];
    @matching = grep { ($_->{disk} // '') eq $zvol_path } @$extents;
} else {
    my $ns = PVE::Storage::Custom::TrueNASPlugin::_api_call(
        $scfg, 'nvmet.namespace.query',
        [[["device_path", "=", $zvol_path]]]) // [];
    @matching = @$ns;
}

is(scalar(@matching), 1,
    "exactly one " . ($mode eq 'iscsi' ? "extent" : "namespace") .
    " references $zvol_path (no duplicate)");

is($matching[0]{id}, $orphan_id,
    "the surviving id ($matching[0]{id}) is the seeded orphan id ($orphan_id) -- reuse confirmed");

# ---------------------------------------------------------------------
# 6. Cleanup.
# ---------------------------------------------------------------------
if ($rc == 0 && $out =~ /^\Q$sid\E:(\S+)/) {
    my $volid = "$sid:$1";
    say_diag("cleanup: pvesm free $volid");
    system("pvesm free $volid >/dev/null 2>&1");
}
# Belt-and-suspenders: brute-force any leftover state
_pre_clean();

done_testing();
