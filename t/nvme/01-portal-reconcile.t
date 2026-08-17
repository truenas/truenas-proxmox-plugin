#!/usr/bin/perl
# Offline tests for NVMe/TCP portal reconciliation.
#
# Unlike t/rate-limit/, this needs neither TrueNAS nor a configured storage: it
# builds a fixture sysfs tree, points $NVME_SYSFS_CLASS at it, and stubs the
# command execution. Two things are under test:
#
#   1. _nvme_controller_portals() - which configured portals currently have a
#      controller, and in what state.
#   2. _nvme_connect() - that the hot path never issues a connect to a portal
#      that is down, and that repair mode connects only what is missing.
#
# Run with:  prove -v t/nvme/01-portal-reconcile.t

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";

unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG  = 'PVE::Storage::Custom::TrueNASPlugin';
my $OURS = 'nqn.2011-06.com.truenas:uuid:1111-2222:pve';

my @RAN;
my %CONNECT_FAILS;   # "host:port" => 1  -> nvme connect dies for that portal
my $DNS_DOWN = 0;    # when true, every hostname lookup fails
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::run_command"} = sub {
        my ($cmd, %opts) = @_;
        push @RAN, join(' ', @$cmd);
        if ($cmd->[0] eq 'nvme' && ($cmd->[1] // '') eq 'connect') {
            my %a = @{$cmd}[2 .. $#$cmd];
            if ($CONNECT_FAILS{"$a{-a}:$a{-s}"}) {
                $opts{errfunc}->('connect failed') if $opts{errfunc};
                die "command 'nvme connect' failed: exit code 1\n";
            }
        }
        return 0;
    };
    *{"${PKG}::_log"}    = sub { 1 };
    # Lets the DNS-failure case be exercised without touching the host resolver.
    my $real_gai = \&Socket::getaddrinfo;
    *{"Socket::getaddrinfo"} = sub { return ('EAI_AGAIN') if $DNS_DOWN; $real_gai->(@_) };
    *{"${PKG}::usleep"}  = sub ($) { 1 };
}

# Build a fixture sysfs tree. Each controller is a hash of attribute => value.
sub sysfs {
    my (@ctrls) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $i = 0;
    for my $c (@ctrls) {
        my $dir = "$root/nvme" . $i++;
        mkdir $dir or die "mkdir $dir: $!";
        for my $attr (keys %$c) {
            open my $fh, '>', "$dir/$attr" or die "open $dir/$attr: $!";
            print $fh $c->{$attr}, "\n";
            close $fh;
        }
    }
    no strict 'refs';
    ${"${PKG}::NVME_SYSFS_CLASS"} = $root;
    return $root;
}

sub ctrl {
    my ($nqn, $addr, $state, %extra) = @_;
    return { subsysnqn => $nqn, transport => 'tcp', address => $addr,
             state => $state, %extra };
}

sub portals { return $PKG->can('_nvme_controller_portals')->({ tn_subsystem_nqn => $OURS }) }

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

sysfs(ctrl($OURS, 'traddr=192.0.2.10,trsvcid=4420',     'live'),
      ctrl($OURS, 'traddr=198.51.100.10,trsvcid=4420',  'live'));
is_deeply(portals(), { '192.0.2.10:4420' => 'live', '198.51.100.10:4420' => 'live' },
    'both portals of a dual-fabric subsystem report live');

sysfs(ctrl($OURS, 'traddr=192.0.2.10,trsvcid=4420',    'live'),
      ctrl($OURS, 'traddr=198.51.100.10,trsvcid=4420', 'connecting'));
is_deeply(portals(), { '192.0.2.10:4420' => 'live', '198.51.100.10:4420' => 'connecting' },
    'a reconnecting controller keeps its state rather than vanishing');

# The case the previous version of this test got wrong. It compared NQNs with a
# regex, so it only caught foreign subsystems whose NQN differed in the middle.
# A common prefix - the realistic shape, e.g. one storage per purpose against
# the same TrueNAS - slipped straight through and its controllers were counted
# as ours.
sysfs(ctrl("$OURS-backup", 'traddr=192.0.2.10,trsvcid=4420',    'live'),
      ctrl("${OURS}2",     'traddr=198.51.100.10,trsvcid=4420', 'live'));
is_deeply(portals(), {},
    'a subsystem whose NQN merely shares our prefix is not counted as ours');

sysfs(ctrl($OURS, 'traddr=192.0.2.10,trsvcid=4420', 'live'),
      ctrl('nqn.2011-06.com.truenas:uuid:9999-8888:other',
           'traddr=203.0.113.9,trsvcid=4420', 'live'));
is_deeply(portals(), { '192.0.2.10:4420' => 'live' },
    'an unrelated subsystem is ignored');

# The initiator address the kernel actually emits is src_addr=, covered by the
# cases above. host_traddr= only appears when a controller was created with
# --host-traddr, which this plugin never passes - so this is a defensive case,
# and the order is deliberately hostile.
sysfs(ctrl($OURS, 'host_traddr=192.0.2.99,traddr=192.0.2.10,trsvcid=4420', 'live'));
is_deeply(portals(), { '192.0.2.10:4420' => 'live' },
    'host_traddr does not create a phantom portal');

sysfs(ctrl($OURS, 'traddr=192.0.2.10', 'live'));
is_deeply(portals(), { '192.0.2.10:4420' => 'live' },
    'a controller without trsvcid defaults to port 4420');

sysfs(ctrl($OURS, 'traddr=192.0.2.10,trsvcid=4420', 'live', transport => 'rdma'));
is_deeply(portals(), {}, 'non-TCP transports are out of scope');

sysfs();
is_deeply(portals(), {}, 'an empty controller class yields no portals');

{
    no strict 'refs';
    ${"${PKG}::NVME_SYSFS_CLASS"} = '/nonexistent/nvme-class';
    is_deeply(portals(), {}, 'a missing sysfs tree fails safe rather than dying');
}

# ---------------------------------------------------------------------------
# _nvme_connect behaviour
# ---------------------------------------------------------------------------

my $connect = $PKG->can('_nvme_connect');

sub scfg {
    return {
        tn_subsystem_nqn    => $OURS,
        tn_hostnqn          => 'nqn.2014-08.org.nvmexpress:uuid:aaaa-bbbb',
        tn_discovery_portal => '192.0.2.10:4420',
        tn_portals          => '198.51.100.10:4420',
    };
}

sub run_connect {
    my (%opts) = @_;
    @RAN = ();
    eval { $connect->(scfg(), %opts) };
    my $err = $@;
    return ($err, grep { /^nvme connect/ } @RAN);
}

sysfs(ctrl($OURS, 'traddr=192.0.2.10,trsvcid=4420',    'live'),
      ctrl($OURS, 'traddr=198.51.100.10,trsvcid=4420', 'live'));
{
    my ($err, @c) = run_connect();
    is($err, '', 'healthy: no error');
    is(scalar(@c), 0, 'healthy: no connect issued');
    is(scalar(@RAN), 0, "healthy: nothing is executed at all");
}

# One fabric down. On the hot path this must stay cheap: report, do not repair.
sysfs(ctrl($OURS, 'traddr=192.0.2.10,trsvcid=4420', 'live'));
{
    my ($err, @c) = run_connect();
    is($err, '', 'degraded hot path: no error');
    is(scalar(@c), 0, 'degraded hot path: no connect to the missing portal');
}
{
    my ($err, @c) = run_connect(repair => 1);
    is($err, '', 'repair: no error');
    is(scalar(@c), 1, 'repair: exactly one connect');
    like($c[0], qr/198\.51\.100\.10/, 'repair: connects the missing portal');
    unlike($c[0], qr/-a 192\.0\.2\.10/, 'repair: leaves the live portal alone');
}

# A controller the kernel is already retrying must not get a second connect;
# that is what makes tn_nvme_ctrl_loss_tmo=-1 safe, since it parks controllers
# in 'connecting' indefinitely by design.
sysfs(ctrl($OURS, 'traddr=192.0.2.10,trsvcid=4420',    'live'),
      ctrl($OURS, 'traddr=198.51.100.10,trsvcid=4420', 'connecting'));
{
    my ($err, @c) = run_connect(repair => 1);
    is(scalar(@c), 0, 'connecting: no duplicate connect');
    is(scalar(@RAN), 0,
       "connecting: nothing executed - the kernel is already retrying that path");
}

# ---------------------------------------------------------------------------
# Config validation
# ---------------------------------------------------------------------------

# ctrl_loss_tmo 0 removes the controller on the first error without retrying at
# all, which is strictly worse than the kernel default this option exists to
# override. The schema minimum of -1 cannot express "-1 or positive", so
# check_config carries the rule.
{
    no warnings "redefine";
    local *PVE::Storage::Plugin::check_config = sub { my (undef, undef, $c) = @_; return { %$c } };

    my $err = "";
    eval { $PKG->check_config("t", { tn_nvme_ctrl_loss_tmo => 0 }, 1, 1); 1 } or $err = $@;
    like($err, qr/tn_nvme_ctrl_loss_tmo must be -1/,
        "a ctrl_loss_tmo of 0 is rejected at config time");

    $err = "";
    eval { $PKG->check_config("t", { tn_nvme_ctrl_loss_tmo => -1 }, 1, 1); 1 } or $err = $@;
    unlike($err, qr/tn_nvme_ctrl_loss_tmo/,
        "a ctrl_loss_tmo of -1 passes its own check");
}

# A port written with a leading zero keys the same as its canonical form, so a
# live portal is recognised rather than reconnected forever. It must also survive
# a real connect: the untainter rejects ^0, and its die sits outside the
# per-portal eval, so an unnormalised value would take the other portals with it.
sysfs(ctrl($OURS, "traddr=192.0.2.10,trsvcid=4420,src_addr=192.0.2.10", "live"));
{
    my $s = scfg();
    $s->{tn_discovery_portal} = "192.0.2.10:04420";
    $s->{tn_portals}          = "198.51.100.10:04420";
    @RAN = ();
    my $err = "";
    eval { $connect->($s, repair => 1); 1 } or $err = $@;
    is($err, "", "leading-zero ports do not abort the connect");
    my @c = grep { /^nvme connect/ } @RAN;
    is(scalar(@c), 1, "leading-zero port: only the missing portal is connected");
    like($c[0], qr{ -s 4420(?![0-9])}, "leading-zero port is normalised for nvme connect");
}

# ---------------------------------------------------------------------------
# Address normalisation
# ---------------------------------------------------------------------------

# This is where a phantom portal comes from: the kernel only ever writes the
# canonical dotted quad, so a config entry that is the same address written
# differently keys differently and gets reconnected on every poll. Note that
# 010 must read as ten and not as octal eight, which is a different host.
{
    my $norm = $PKG->can("_nvme_normalize_addr");
    is($norm->("192.000.002.010"), "192.0.2.10",  "leading zeros are stripped, decimally");
    is($norm->("010.1.1.1"),       "10.1.1.1",    "a leading-zero first octet is not octal");
    is($norm->("192.0.2.10"),      "192.0.2.10",  "an already canonical address is unchanged");
    is($norm->("192.0.2.999"),     "192.0.2.999", "an out-of-range octet is left alone");

    my $key = $PKG->can("_nvme_portal_key");
    is($key->("192.000.002.010", "04420"), $key->("192.0.2.10", "4420"),
        "config and sysfs spellings of one address produce one key");
}

# ---------------------------------------------------------------------------
# Failure branch
# ---------------------------------------------------------------------------

# A portal that fails to connect must not be retried on every poll: status()
# runs on pvestatd's timer, and each attempt is bounded but not free.
sysfs(ctrl($OURS, "traddr=192.0.2.10,trsvcid=4420,src_addr=192.0.2.10", "live"));
{
    %CONNECT_FAILS = ("198.51.100.10:4420" => 1);
    @RAN = ();
    eval { $connect->(scfg(), repair => 1) };
    my $first = scalar(grep { /^nvme connect/ } @RAN);
    @RAN = ();
    eval { $connect->(scfg(), repair => 1) };
    my $second = scalar(grep { /^nvme connect/ } @RAN);
    is($first,  1, "a failing portal is attempted once");
    is($second, 0, "and is then held off by the backoff window");
}

# The same backoff must hold when NOTHING is live, which is the common shape of
# the target being down entirely. Without it every poll attempts every portal,
# each bounded by the connect timeout, forever - stalling the poll loop for
# every storage on the node, not just this one.
sysfs();
{
    %CONNECT_FAILS = ("192.0.2.10:4420" => 1, "198.51.100.10:4420" => 1);
    @RAN = ();
    eval { $connect->(scfg(), repair => 1) };
    @RAN = ();
    eval { $connect->(scfg(), repair => 1) };
    is(scalar(grep { /^nvme connect/ } @RAN), 0,
        "with no live path at all, repair mode still respects the backoff");
}

# The hot path is the deliberate exception: that call is the one deciding
# whether a VM gets its disk.
{
    @RAN = ();
    eval { $connect->(scfg()) };
    cmp_ok(scalar(grep { /^nvme connect/ } @RAN), ">", 0,
        "the hot path with nothing live always tries, backoff or not");
    %CONNECT_FAILS = ();
}

# ---------------------------------------------------------------------------
# Reconnection options reach the command line
# ---------------------------------------------------------------------------

sysfs(ctrl($OURS, "traddr=192.0.2.10,trsvcid=4420,src_addr=192.0.2.10", "live"));
{
    # Backoff is keyed by subsystem, so a distinct NQN gives this block its own
    # window and the failures staged above cannot suppress the connect measured
    # here. With no controller for that NQN, both portals are missing.
    my $s = scfg();
    $s->{tn_subsystem_nqn}        = $OURS . "-options";
    $s->{tn_nvme_ctrl_loss_tmo}   = -1;
    $s->{tn_nvme_reconnect_delay} = 5;
    $s->{tn_nvme_keep_alive_tmo}  = 7;
    @RAN = ();
    eval { $connect->($s, repair => 1) };
    my ($c) = grep { /^nvme connect/ } @RAN;
    like($c, qr/--ctrl-loss-tmo -1/,  "ctrl-loss-tmo reaches nvme connect");
    like($c, qr/--reconnect-delay 5/, "reconnect-delay reaches nvme connect");
    like($c, qr/--keep-alive-tmo 7/,  "keep-alive-tmo reaches nvme connect");
}

# ---------------------------------------------------------------------------
# Cannot-tell is not the same as absent
# ---------------------------------------------------------------------------

# A portal configured by name cannot be matched against the numeric traddr that
# sysfs reports if the name does not currently resolve. Treating "no match" as
# "no controller" would fire a connect at a perfectly healthy subsystem, from
# the hot path, exactly when the network is already unwell.
sysfs(ctrl($OURS, "traddr=192.0.2.10,trsvcid=4420,src_addr=192.0.2.10", "live"));
{
    my $s = scfg();
    $s->{tn_api_host}         = "dns-under-test";
    $s->{tn_discovery_portal} = "nas.example.com:4420";
    $s->{tn_portals}          = "";

    $DNS_DOWN = 1;
    @RAN = ();
    eval { $connect->($s) };
    is(scalar(grep { /^nvme connect/ } @RAN), 0,
        "an unresolvable named portal does not trigger a connect on the hot path");
    $DNS_DOWN = 0;
}

# ---------------------------------------------------------------------------
# The redundancy summary must not count attempts
# ---------------------------------------------------------------------------

# nvme connect returns as soon as the controller exists, which may be in
# 'connecting', and the "already connected" branch counts one never inspected.
# Reporting attempts as live would reintroduce the blindness this change
# removes, and would suppress its own warning.
sysfs();
{
    my @logs;
    no strict "refs";
    no warnings "redefine";
    local *{"${PKG}::_log"} = sub { my (undef, undef, undef, $m) = @_; push @logs, $m; 1 };

    my $s = scfg();
    $s->{tn_api_host} = "recount-under-test";
    @RAN = ();
    eval { $connect->($s, repair => 1) };

    my ($summary) = grep { /configured portal\(s\) live/ } @logs;
    unlike($summary // "", qr/: 2 of 2 configured/,
        "connects that produced no controller are not reported as live paths");
}

# A dotted quad with a leading-zero octet means one thing to this plugin (which
# normalises it) and another to nvme connect (which hands it to inet_aton, where
# 010 is octal). Rather than pick a reading, the config is rejected.
{
    no warnings "redefine";
    local *PVE::Storage::Plugin::check_config = sub { my (undef, undef, $c) = @_; return { %$c } };

    my $nvme = sub { return { tn_transport_mode => "nvme-tcp", @_ } };

    my $err = "";
    eval { $PKG->check_config("t", $nvme->(tn_discovery_portal => "192.000.002.010:4420"), 1, 1); 1 }
        or $err = $@;
    like($err, qr/leading-zero octet/, "a leading-zero octet in a portal is rejected");

    $err = "";
    eval { $PKG->check_config("t", $nvme->(tn_portals => "10.0.0.1:4420,192.0.02.5:4420"), 1, 1); 1 }
        or $err = $@;
    like($err, qr/leading-zero octet/, "...including in tn_portals");

    # split() trims around commas but not at the ends of the string, while the
    # runtime trims every entry - so a leading space used to hide the first
    # portal from this check and then have it used anyway.
    $err = "";
    eval { $PKG->check_config("t", $nvme->(tn_portals => " 010.0.0.1:4420,10.0.0.2:4420"), 1, 1); 1 }
        or $err = $@;
    like($err, qr/leading-zero octet/, "...and when a leading space precedes it");

    $err = "";
    eval { $PKG->check_config("t", $nvme->(tn_discovery_portal => "192.0.2.10:4420"), 1, 1); 1 }
        or $err = $@;
    unlike($err, qr/leading-zero octet/, "a plain decimal quad passes");

    $err = "";
    eval { $PKG->check_config("t", $nvme->(tn_discovery_portal => "nas.example.com:4420"), 1, 1); 1 }
        or $err = $@;
    unlike($err, qr/leading-zero octet/, "a hostname is not mistaken for a quad");

    # iSCSI configs must keep parsing across an upgrade: the rule is about what
    # nvme connect does with the string, and iSCSI never sees it.
    $err = "";
    eval { $PKG->check_config("t", { tn_transport_mode => "iscsi",
                                     tn_discovery_portal => "192.168.010.5:3260" }, 1, 1); 1 }
        or $err = $@;
    unlike($err, qr/leading-zero octet/, "an existing iSCSI portal is left alone");
}

# ---------------------------------------------------------------------------
# Neither die may fire while the subsystem has controllers
# ---------------------------------------------------------------------------

# A portal that cannot be resolved never reaches the connect loop, so it can
# never contribute to the success count. With a second portal simply down, that
# sum reaches zero and the closing die used to fire - from path() and
# activate_volume(), neither of which is wrapped in eval - while the storage was
# perfectly usable through a live controller.
sysfs(ctrl($OURS, "traddr=192.0.2.10,trsvcid=4420,src_addr=192.0.2.10", "live"));
{
    my $s = scfg();
    $s->{tn_subsystem_nqn}    = $OURS;
    $s->{tn_discovery_portal} = "nas.example.com:4420";   # unresolvable
    $s->{tn_portals}          = "10.99.0.20:4420";        # literal, no controller
    $CONNECT_FAILS{"10.99.0.20:4420"} = 1;

    $DNS_DOWN = 1;
    my $err = "";
    @RAN = ();
    eval { $connect->($s); 1 } or $err = $@;
    is($err, "", "the hot path does not fail while a live controller exists");
    $DNS_DOWN = 0;
    %CONNECT_FAILS = ();
}

# ---------------------------------------------------------------------------
# The die must still fire on a real outage
# ---------------------------------------------------------------------------

# An unresolvable portal can never reach the connect loop, so it can never
# contribute to the success count - which is why guarding the closing die on
# "no unresolved portals" swallowed real failures: adding a portal by name to
# tn_portals made a total outage return success. Only the absence of any
# controller for the subsystem distinguishes the two.
sysfs();
{
    my $s = scfg();
    $s->{tn_subsystem_nqn}    = $OURS . "-outage";
    $s->{tn_discovery_portal} = "nas.example.com:4420";   # unresolvable
    $s->{tn_portals}          = "10.99.0.20:4420";        # literal, unreachable
    $CONNECT_FAILS{"10.99.0.20:4420"} = 1;

    $DNS_DOWN = 1;
    my $err = "";
    eval { $connect->($s); 1 } or $err = $@;
    like($err, qr/Failed to connect to any NVMe/,
        "a total outage still fails even with an unresolvable portal in the list");
    $DNS_DOWN = 0;
    %CONNECT_FAILS = ();
}

# ---------------------------------------------------------------------------
# Reduced redundancy must be visible without turning on debugging
# ---------------------------------------------------------------------------

# _log drops anything above tn_debug, which defaults to 0. A warning emitted at
# level 1 is therefore invisible on a default install - and the whole point of
# this change is to stop losing a path silently.
# A distinct subsystem gives this block its own throttle window, so warnings
# stamped by the blocks above cannot demote the one measured here.
my $LOGNQN = $OURS . "-loglevel";
sysfs(ctrl($LOGNQN, "traddr=192.0.2.10,trsvcid=4420,src_addr=192.0.2.10", "live"));
{
    my @levels;
    no strict "refs";
    no warnings "redefine";
    local *{"${PKG}::_log"} = sub {
        my (undef, $lvl, $sev, $msg) = @_;
        push @levels, [$lvl, $msg] if $msg =~ /reduced path redundancy/;
        1;
    };

    my $s = scfg();
    $s->{tn_subsystem_nqn} = $LOGNQN;
    eval { $connect->($s) };

    ok(scalar(@levels), "the degraded-redundancy warning is emitted");
    is($levels[0][0], 0,
        "...at a level that survives the default tn_debug of 0")
        if @levels;
}

# ---------------------------------------------------------------------------
# Do not warn about what cannot be known
# ---------------------------------------------------------------------------

# The hot path does not resolve names, so a portal configured by name always
# lands in @unknown there. Warning on that alone means a perfectly healthy
# storage reports reduced redundancy on every VM start. Each block below uses
# its own subsystem so the per-process throttle cannot mask the result.
{
    my @warned;
    no strict "refs";
    no warnings "redefine";
    local *{"${PKG}::_log"} = sub {
        my (undef, $lvl, undef, $msg) = @_;
        push @warned, $lvl if $msg =~ /reduced path redundancy/;
        1;
    };

    # Healthy: the only portal without a controller is one we could not resolve.
    my $healthy = $OURS . "-quiet";
    sysfs(ctrl($healthy, "traddr=10.0.0.1,trsvcid=4420,src_addr=10.0.0.1", "live"));
    my $s = scfg();
    $s->{tn_subsystem_nqn}    = $healthy;
    $s->{tn_discovery_portal} = "10.0.0.1:4420";
    $s->{tn_portals}          = "nas.example.com:4420";
    @warned = ();
    eval { $connect->($s) };
    is(scalar(grep { $_ == 0 } @warned), 0,
        "an unresolvable portal alone does not raise a visible warning");

    # Genuinely degraded: a literal portal with no controller.
    my $degraded = $OURS . "-noisy";
    sysfs(ctrl($degraded, "traddr=10.0.0.1,trsvcid=4420,src_addr=10.0.0.1", "live"));
    $s = scfg();
    $s->{tn_subsystem_nqn}    = $degraded;
    $s->{tn_discovery_portal} = "10.0.0.1:4420";
    $s->{tn_portals}          = "10.0.0.2:4420";
    @warned = ();
    eval { $connect->($s) };
    is(scalar(grep { $_ == 0 } @warned), 1,
        "a portal that is genuinely missing still warns, visibly");
}

done_testing();
