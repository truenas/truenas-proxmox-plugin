#!/usr/bin/perl
# Unit tests for the #124 fixes. Reporter matobodo caught a prefix-match
# bug in every substring-based IQN/NQN comparison the plugin does:
# when one target IQN is a prefix of another (classic case: a
# ":proxmox-nvme-protected" and a ":proxmox-nvme-protected-16k" against
# the same portal), the shorter IQN's checks match the longer IQN's
# session/subsystem lines, so _iscsi_login_all skips a login that
# should have run, _target_sessions_active returns true for a target
# that has no session, and _nvme_is_connected reports a subsystem as
# connected when only a longer-NQN subsystem is live. The fix anchors
# every IQN/NQN comparison with (?![\w.:-]) (IQN syntax permits those
# chars in the suffix, so the lookahead refuses any legal suffix
# continuation), except the by-path diagnostic which uses the -lun-
# natural anchor that by-path already has.
#
# What we assert:
#   - _target_sessions_active returns 1 for a session line that is this
#     IQN exactly, and 0 for a session line that is this IQN plus a
#     "-16k" suffix.
#   - _portal_connected mirrors that behavior per portal.
#   - _nvme_is_connected gates on the exact NQN, not a prefix of it.
#   - The raw regex /\Q$iqn\E(?![\w.:-])/ matches end-of-line, space,
#     '/', and refuses continuation on word char / '-' / '.' / ':'.
#
# No TN, no broker, no run_command execution — we monkey-patch
# _run_lines and PVE::Tools::run_command to inject deterministic
# fixture output.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;

my $plugin_loaded = eval {
    require PVE::Storage::Custom::TrueNASPlugin;
    1;
};
if (!$plugin_loaded) {
    plan skip_all => "PVE::Storage::Custom::TrueNASPlugin not loadable: $@";
}

my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';

# These helpers use prototype signatures (sub _target_sessions_active($scfg))
# so they must be called as functions, not methods, or Perl passes $pkg as
# the first argument and the prototype rejects it. (Same gotcha as #123's
# _is_retryable_error.)
my $target_sessions_active = \&PVE::Storage::Custom::TrueNASPlugin::_target_sessions_active;
my $portal_connected       = \&PVE::Storage::Custom::TrueNASPlugin::_portal_connected;
my $nvme_is_connected      = \&PVE::Storage::Custom::TrueNASPlugin::_nvme_is_connected;

# ============================================================
# Raw end-anchor regex: /\Q$iqn\E(?![\w.:-])/
# ============================================================
my $iqn       = 'iqn.2022-08.com.example:proxmox-nvme-protected';
my $iqn_long  = 'iqn.2022-08.com.example:proxmox-nvme-protected-16k';
my $iqn_other = 'iqn.2022-08.com.example:proxmox-ssd-protected';

my @match = (
    ["tcp: [1] 10.0.0.1:3260,1 $iqn",         'IQN exact at EOL'],
    ["tcp: [2] 10.0.0.1:3260,1 $iqn (flag)",  'IQN followed by space'],
    ["$iqn/path",                              'IQN followed by /'],
    ["prefix $iqn\tsuffix",                   'IQN followed by tab'],
);
for my $t (@match) {
    my ($line, $label) = @$t;
    ok($line =~ /\Q$iqn\E(?![\w.:-])/, "match: $label");
}

my @no_match = (
    ["tcp: [1] 10.0.0.1:3260,1 $iqn_long",    'longer IQN with -16k'],
    ["$iqn-16k",                               'IQN followed by -'],
    ["$iqn.extra",                             'IQN followed by .'],
    ["$iqn:extra",                             'IQN followed by :'],
    ["${iqn}more",                             'IQN followed by word char'],
);
for my $t (@no_match) {
    my ($line, $label) = @$t;
    ok($line !~ /\Q$iqn\E(?![\w.:-])/, "NOT match: $label");
}

# ============================================================
# _target_sessions_active: short IQN against long-IQN session
# ============================================================
my $run_lines_output;
{
    no warnings 'redefine';
    *PVE::Storage::Custom::TrueNASPlugin::_run_lines = sub {
        return @$run_lines_output;
    };
}

my $scfg_short = { tn_target_iqn => $iqn };

# Case: a session exists for the LONGER IQN only. Pre-fix, this
# returned true (bug). Post-fix, it should return false.
$run_lines_output = [
    "tcp: [1] 10.0.0.1:3260,1 $iqn_long",
    "tcp: [2] 10.0.0.1:3260,1 $iqn_other",
];
is($target_sessions_active->($scfg_short), 0,
    'Fix #124: _target_sessions_active returns 0 when only longer-IQN session exists');

# Case: a session exists for the short IQN directly. Should return true.
$run_lines_output = [
    "tcp: [1] 10.0.0.1:3260,1 $iqn",
    "tcp: [2] 10.0.0.1:3260,1 $iqn_other",
];
is($target_sessions_active->($scfg_short), 1,
    'Fix #124: _target_sessions_active returns 1 for the exact IQN session');

# Case: a session exists for BOTH short and long. Still true for short.
$run_lines_output = [
    "tcp: [1] 10.0.0.1:3260,1 $iqn_long",
    "tcp: [2] 10.0.0.1:3260,1 $iqn",
];
is($target_sessions_active->($scfg_short), 1,
    'Fix #124: _target_sessions_active returns 1 even if a longer-IQN session is also present');

# ============================================================
# _portal_connected: short IQN against long-IQN session on same portal
# ============================================================
my $scfg_portal = {
    tn_target_iqn      => $iqn,
    tn_discovery_portal=> '10.0.0.1:3260',
};

$run_lines_output = [
    "tcp: [1] 10.0.0.1:3260,1 $iqn_long",
];
is($portal_connected->($scfg_portal, '10.0.0.1:3260'), 0,
    'Fix #124: _portal_connected returns 0 when only longer-IQN session is on the portal');

$run_lines_output = [
    "tcp: [1] 10.0.0.1:3260,1 $iqn",
];
is($portal_connected->($scfg_portal, '10.0.0.1:3260'), 1,
    'Fix #124: _portal_connected returns 1 for the exact IQN on the portal');

# ============================================================
# _nvme_is_connected: short NQN against long-NQN subsystem
# ============================================================
# _nvme_is_connected reads controller state from sysfs ($NVME_SYSFS_CLASS,
# matching each controller's subsysnqn with eq) instead of parsing
# `nvme list-subsys`, so the fixture is a fake sysfs tree, not command output.
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $sysfs_root = tempdir(CLEANUP => 1);
{
    no strict 'refs';
    ${"PVE::Storage::Custom::TrueNASPlugin::NVME_SYSFS_CLASS"} = $sysfs_root;
}

# Replace the fake sysfs with the given controllers: [name, nqn, state].
my $set_controllers = sub {
    my (@ctrls) = @_;
    opendir(my $dh, $sysfs_root) or die "opendir: $!";
    for my $e (grep { /^nvme\d+$/ } readdir($dh)) {
        for my $f (glob("$sysfs_root/$e/*")) { unlink $f }
        rmdir "$sysfs_root/$e";
    }
    closedir($dh);
    for my $c (@ctrls) {
        my ($name, $subnqn, $state) = @$c;
        make_path("$sysfs_root/$name");
        my %attr = (
            subsysnqn => $subnqn,
            transport => 'tcp',
            state     => $state,
            address   => 'traddr=10.0.0.2,trsvcid=4420,src_addr=10.0.0.3',
        );
        for my $k (keys %attr) {
            open(my $fh, '>', "$sysfs_root/$name/$k") or die "open: $!";
            print {$fh} "$attr{$k}
";
            close($fh);
        }
    }
};

my $nqn      = 'nqn.2011-06.com.truenas:uuid:abc:proxmox-nvme-protected';
my $nqn_long = 'nqn.2011-06.com.truenas:uuid:abc:proxmox-nvme-protected-16k';

my $scfg_nvme_short = { tn_subsystem_nqn => $nqn };

$set_controllers->(['nvme0', $nqn_long, 'live']);
is($nvme_is_connected->($scfg_nvme_short), 0,
    'Fix #124: _nvme_is_connected returns 0 when only longer-NQN subsystem is live');

$set_controllers->(['nvme0', $nqn, 'live']);
is($nvme_is_connected->($scfg_nvme_short), 1,
    'Fix #124: _nvme_is_connected returns 1 for the exact NQN');

# Two subsystems, long one first (live), short one second (also live):
# the short-NQN controller must be seen, but the long-only case above must
# not have been fooled into returning 1.
$set_controllers->(['nvme0', $nqn_long, 'live'], ['nvme1', $nqn, 'live']);
is($nvme_is_connected->($scfg_nvme_short), 1,
    'Fix #124: _nvme_is_connected returns 1 when exact NQN is one of multiple subsystems');

done_testing();
