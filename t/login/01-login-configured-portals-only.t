#!/usr/bin/perl
# _iscsi_login_all must only log into portals the operator configured.
#
# SendTargets makes open-iscsi record a node for every address the target
# advertises; a TrueNAS portal on 0.0.0.0 / :: advertises every address on
# the box (docker/VM bridges, ULAs). Each --login to an unreachable address
# blocks for open-iscsi's whole retry budget, serially, before a real portal
# is reached. Before this change the loop over `iscsiadm -m node` logged into
# all of them.
#
# Run with:  prove -v -I t/nvme/lib t/login/01-login-configured-portals-only.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $login_all = $PKG->can('_iscsi_login_all') or plan skip_all => '_iscsi_login_all not found';

my $IQN = 'iqn.2011-08.org.truenas.ctl:proxmox';

# What `iscsiadm -m node` reports after a discovery against a TrueNAS portal
# bound to 0.0.0.0: the LAN address plus every bridge on the box.
my @NODES = map { "$_,1 $IQN" } (
    '192.168.1.68:3260',      # configured (primary)
    '192.168.1.69:3260',      # configured (tn_portals)
    '172.16.0.1:3260',        # docker bridge: unreachable
    '100.87.121.59:3260',     # tailscale: unreachable from this host
    '[fdd0::1]:3260',         # docker IPv6 bridge: unreachable
);

my (@cmds, @logs);
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_run_lines"} = sub {
        my ($cmd) = @_;
        return @NODES if $cmd->[1] eq '-m' && $cmd->[2] eq 'node';
        return ();                       # no sessions yet
    };
    *{"${PKG}::_try_run"}   = sub { push @cmds, [@{$_[0]}]; 1 };
    *{"${PKG}::_probe_portal"} = sub { 1 };
    *{"${PKG}::_iscsi_discover"} = sub { 1 };
    *{"${PKG}::_log"}       = sub { push @logs, $_[3]; 1 };
    *{"${PKG}::run_command"} = sub { 0 };
    *{"${PKG}::usleep"}     = sub ($) { 1 };
}

my $scfg = {
    tn_target_iqn       => $IQN,
    tn_discovery_portal => '192.168.1.68:3260',
    tn_portals          => '192.168.1.69:3260',
};

ok(eval { $login_all->($scfg); 1 }, '_iscsi_login_all runs') or diag $@;

# the portal is the argument after -p
sub portal_of { my ($c) = @_; for my $i (0..$#$c-1) { return $c->[$i+1] if $c->[$i] eq '-p' } return '' }
my @logins = map { portal_of($_) } grep { grep { $_ eq '--login' } @$_ } @cmds;
my %login_portals = map { $_ => 1 } @logins;

ok( $login_portals{'192.168.1.68:3260'}, 'logs into the configured primary portal');
ok( $login_portals{'192.168.1.69:3260'}, 'logs into the configured extra portal');
ok(!$login_portals{'172.16.0.1:3260'},    'does NOT log into the discovered docker-bridge address');
ok(!$login_portals{'100.87.121.59:3260'}, 'does NOT log into the discovered tailscale address');
ok(!grep({ /fdd0::1/ } @logins),          'does NOT log into the discovered IPv6 bridge address');

my @startup = grep { grep { $_ eq 'node.startup' } @$_ } @cmds;
is(scalar(@startup), 2, 'node.startup=automatic set only on the two configured records');

ok((grep { /skipped 3 discovered portal/ } @logs), 'skipped portals are logged once with a count')
    or diag explain \@logs;

# A configured portal that discovery did not list still gets the direct
# fallback login (issue #91 behaviour kept).
@cmds = (); @logs = ();
$scfg->{tn_portals} = '192.168.1.69:3260,192.168.1.70:3260';
$login_all->($scfg);
ok((grep { portal_of($_) eq '192.168.1.70:3260' && grep { $_ eq '--login' } @$_ } @cmds),
   'configured portal absent from the node list is still logged into directly');

# A hostname portal (#102) and a portless portal must still be recognised in
# the node list, or they lose node.startup/CHAP which only this loop applies.
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_host_ipv4"} = sub { my ($h) = @_; return $h eq 'nas.example.com' ? '192.168.1.68' : $h };
}
@cmds = (); @logs = ();
$login_all->({ tn_target_iqn => $IQN, tn_discovery_portal => 'nas.example.com:3260', tn_portals => '192.168.1.69' });
my @startup2 = map { portal_of($_) } grep { grep { $_ eq 'node.startup' } @$_ } @cmds;
ok((grep { $_ eq '192.168.1.68:3260' } @startup2), 'hostname-configured portal: its resolved-IP node record gets node.startup');
ok((grep { $_ eq '192.168.1.69:3260' } @startup2), 'portless-configured portal: its record (with :3260) gets node.startup');
is(scalar(@startup2), 2, 'still nothing applied to the unconfigured records');

done_testing();
