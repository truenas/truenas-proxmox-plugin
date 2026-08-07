#!/usr/bin/perl
# Fix B: post-hoc extent-name-conflict reuse (2.1.21~alpha5)
#
# When iscsi.extent.create returns
#   [EINVAL] iscsi_extent_create.name: Extent name must be unique
# the alloc path must check whether an extent for the same zvol path
# already exists, and reuse its id -- rather than dying. This handles
# two scenarios Fix 1's up-front check cannot catch on its own:
#
#   (a) a concurrent path committed the same extent between our
#       pre-check and our create call;
#   (b) _api_call_mutate retried after a connection failure whose
#       first attempt actually committed server-side; the second
#       attempt then sees "name must be unique" from its own prior
#       commit.
#
# Testing directly through pvesm alloc runs into TN's cascade-delete
# (which sweeps orphan extents) and the plugin's auto-increment (which
# picks a different disk name when the zvol exists). So this test has
# two tiers:
#
#   1. Classifier unit test -- verify _is_extent_name_conflict_error
#      matches the exact TN error string and rejects unrelated errors.
#      No TN required.
#
#   2. Direct-mutation integration test -- bypass alloc_image and
#      trigger a real TN uniqueness rejection with two direct
#      iscsi.extent.create calls, then invoke the Fix B recovery
#      logic manually and verify it finds+reuses the existing extent.
#      Runs against a real TN. Uses TEST_VMID_BASE + 41.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Digest::SHA qw(sha1_hex);
use JSON::PP;
use RateLimit::Harness qw(env_require env_get new_audit_conn test_scfg say_diag);

my $sid  = env_require('STORAGE_ID');
my $vmid = env_get('TEST_VMID_BASE', 99000) + 41;

require PVE::Storage::Custom::TrueNASPlugin;

# ============================================================
# Tier 1: classifier unit test (no TN required)
# ============================================================

my @positive = (
    "JSON-RPC error: {...} [EINVAL] iscsi_extent_create.name: Extent name must be unique\n",
    "iscsi_extent_create.name: Extent name must be unique",
    "prefix stuff iscsi_extent_create.name: EXTENT NAME MUST BE UNIQUE trailing",
);
for my $err (@positive) {
    ok(PVE::Storage::Custom::TrueNASPlugin::_is_extent_name_conflict_error($err),
        "matches: " . substr($err, 0, 60));
}

my @negative = (
    # Different validator (zvol-not-ready) -- must NOT match; that's a
    # different retry path.
    "iscsi_extent_create.disk: Device '/dev/zvol/tank/foo' for volume 'tank/foo' does not exist",
    # Namespace unique-ness (NVMe) -- irrelevant to this classifier.
    "nvmet_namespace_create.something: must be unique",
    # Auth failure.
    "401 Unauthorized",
    # Connection failure.
    "WS read failed: Broken pipe",
    # Empty / undef.
    "",
    undef,
    # Generic 'unique' in an unrelated context.
    "some.other.field: value must be unique across the fleet",
);
for my $err (@negative) {
    ok(!PVE::Storage::Custom::TrueNASPlugin::_is_extent_name_conflict_error($err),
        "does NOT match: " . (defined $err ? substr($err, 0, 60) : '(undef)'));
}

# ============================================================
# Tier 2: real TN uniqueness rejection + Fix B recovery
# ============================================================

my $scfg = test_scfg();
my $mode = $scfg->{tn_transport_mode} // $scfg->{transport} // 'iscsi';
if ($mode ne 'iscsi') {
    say_diag("transport is '$mode', skipping tier-2 integration test (Fix B is iSCSI-only)");
    done_testing();
    exit 0;
}

# Locate tn_dataset (test_scfg doesn't include it)
my $tn_dataset = $scfg->{tn_dataset};
if (!$tn_dataset) {
    my $json = `pvesh get /storage/$sid --output-format json 2>/dev/null`;
    if ($? == 0) {
        my $raw = decode_json($json);
        $tn_dataset = $raw->{tn_dataset};
    }
}
$tn_dataset //= env_require('TN_DATASET');

my $zname     = "vm-$vmid-disk-0";
my $full_ds   = "$tn_dataset/$zname";
my $zvol_path = "zvol/$full_ds";
my $extent_name = "$zname-" . substr(sha1_hex($full_ds), 0, 8);

new_audit_conn();
say_diag("tier-2: vmid=$vmid, zvol_path=$zvol_path, extent_name=$extent_name");

# ---- pre-clean ----
sub _tier2_pre_clean {
    my $extents = eval {
        PVE::Storage::Custom::TrueNASPlugin::_api_call(
            $scfg, 'iscsi.extent.query', [])
    } // [];
    for my $e (@$extents) {
        next unless ($e->{disk} // '') eq $zvol_path
                 || ($e->{name} // '') eq $extent_name;
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
    eval {
        PVE::Storage::Custom::TrueNASPlugin::_api_call(
            $scfg, 'pool.dataset.delete', [$full_ds])
    };
}
_tier2_pre_clean();

# ---- 1. Create zvol so extent creates have a valid disk path ----
eval {
    PVE::Storage::Custom::TrueNASPlugin::_api_call(
        $scfg, 'pool.dataset.create', [{
            name    => $full_ds,
            type    => 'VOLUME',
            volsize => 1024 * 1024 * 1024,
            sparse  => JSON::PP::true,
        }]);
};
if ($@) {
    diag("zvol create failed: $@");
    _tier2_pre_clean();
    done_testing();
    exit;
}

# ---- 2. First extent create -- succeeds and gives us the "committed" id
my $first = eval {
    PVE::Storage::Custom::TrueNASPlugin::_api_call_mutate(
        $scfg, 'iscsi.extent.create', [{
            name         => $extent_name,
            type         => 'DISK',
            disk         => $zvol_path,
            insecure_tpc => JSON::PP::true,
        }]);
};
if ($@) {
    diag("first extent create failed unexpectedly: $@");
    _tier2_pre_clean();
    done_testing();
    exit;
}
my $first_id = ref($first) eq 'HASH' ? $first->{id} : $first;
ok(defined $first_id, "tier-2: first iscsi.extent.create committed id=$first_id");

# ---- 3. Second extent create with SAME name -- must fail with the
#         exact uniqueness error the classifier is written to catch
my $second_err;
eval {
    PVE::Storage::Custom::TrueNASPlugin::_api_call_mutate(
        $scfg, 'iscsi.extent.create', [{
            name         => $extent_name,
            type         => 'DISK',
            disk         => $zvol_path,
            insecure_tpc => JSON::PP::true,
        }]);
};
$second_err = $@;
ok($second_err, "tier-2: second create dies (name-uniqueness rejection)");
ok(PVE::Storage::Custom::TrueNASPlugin::_is_extent_name_conflict_error($second_err),
    "tier-2: classifier recognizes the rejection error");

# ---- 4. Recovery: query by disk path, verify one hit at the same id.
#         This is what Fix B does inside _alloc_image_iscsi / _clone_image_iscsi
#         / _tn_extent_create when it catches the same error.
my $extents_after = PVE::Storage::Custom::TrueNASPlugin::_api_call(
    $scfg, 'iscsi.extent.query', []) // [];
my @hits = grep { ($_->{disk} // '') eq $zvol_path } @$extents_after;
is(scalar(@hits), 1, "tier-2: exactly one extent references $zvol_path (no dup landed)");
is($hits[0]{id}, $first_id, "tier-2: the extent Fix B would reuse is the committed one id=$first_id");

# ---- cleanup ----
_tier2_pre_clean();

done_testing();
