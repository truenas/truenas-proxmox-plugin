#!/usr/bin/perl
# Issue #140: IPv6 iSCSI portals. The plugin used to strip the brackets from
# "[fd00::1]:3260", probe with the IPv4-only IO::Socket::INET and match
# iscsiadm session lines by substring, so an IPv6 portal was reported
# unreachable and could never be recognised as connected. These tests pin the
# parsed-portal behaviour: brackets kept for iscsiadm, equivalent IPv6
# spellings matched, IPv4/FQDN behaviour unchanged, and the probe reaching an
# IPv6 listener.
#
# Run with:  prove -v -I t/nvme/lib t/ipv6/01-portal-ipv6.t

use strict;
use warnings;
use Test::More;
use FindBin;
use IO::Socket::IP;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my %f = map { $_ => $PKG->can("_$_") } qw(parse_portal normalize_portal portal_key probe_portal portal_connected bypath_portal);
plan skip_all => "portal helpers not found" if grep { !$_ } values %f;

# --- _parse_portal -----------------------------------------------------------
is_deeply([$f{parse_portal}->('192.0.2.10:3260')],      ['192.0.2.10', 3260],  'v4 host:port');
is_deeply([$f{parse_portal}->('192.0.2.10:3260,1')],    ['192.0.2.10', 3260],  'v4 with ,tpgt dropped');
is_deeply([$f{parse_portal}->('nas.example.com')],      ['nas.example.com', undef], 'bare hostname, no port');
is_deeply([$f{parse_portal}->('[fd00::1]:3260')],       ['fd00::1', 3260],     'bracketed v6 with port');
is_deeply([$f{parse_portal}->('[fd00::1]:3260,1')],     ['fd00::1', 3260],     'bracketed v6 with ,tpgt dropped');
is_deeply([$f{parse_portal}->('[fd00::1]')],            ['fd00::1', undef],    'bracketed v6, no port');
is_deeply([$f{parse_portal}->('fd00::1')],              ['fd00::1', undef],    'bare v6 is a host, not host:port');
is_deeply([$f{parse_portal}->('  [fd00::1]:3260  ')],   ['fd00::1', 3260],     'whitespace trimmed');
is_deeply([$f{parse_portal}->('')],                     [undef, undef],        'empty');

# --- _normalize_portal keeps the brackets iscsiadm needs ----------------------
is($f{normalize_portal}->('[fd00::1]:3260'),   '[fd00::1]:3260', 'v6 normalized keeps brackets (was fd00::1:3260)');
is($f{normalize_portal}->('[fd00::1]:3260,1'), '[fd00::1]:3260', 'v6 ,tpgt dropped');
is($f{normalize_portal}->('fd00::1'),          '[fd00::1]',      'bare v6 gets brackets');
is($f{normalize_portal}->('192.0.2.10:3260,1'),'192.0.2.10:3260','v4 unchanged');
is($f{normalize_portal}->(' nas:3260 '),       'nas:3260',       'hostname unchanged');

# --- _portal_key folds equivalent spellings ---------------------------------
is($f{portal_key}->('[2001:DB8:0:0::1]:3260'), $f{portal_key}->('[2001:db8::1]:3260'), 'v6 spellings fold');
is($f{portal_key}->('[fd00::1]'), '[fd00::1]:3260', 'missing port defaults to 3260 in the key');
isnt($f{portal_key}->('[fd00::1]:3260'), $f{portal_key}->('[fd00::2]:3260'), 'different v6 hosts differ');

# --- _portal_connected on iscsiadm session lines ----------------------------
my $iqn  = 'iqn.2005-10.org.freenas.ctl:proxmox';
my $scfg = { tn_target_iqn => $iqn };
my @sessions = (
    'tcp: [1] 192.168.1.68:3260,1 iqn.2005-10.org.freenas.ctl:proxmox (non-flash)',
    'tcp: [2] [fd00:0:0:0::10]:3260,1 iqn.2005-10.org.freenas.ctl:proxmox (non-flash)',
    'tcp: [3] [fd00::20]:3260,1 iqn.2005-10.org.freenas.ctl:proxmox-nvme-protected-16k (non-flash)',
);
ok( $f{portal_connected}->($scfg, '192.168.1.68:3260', \@sessions),   'v4 portal matched');
ok( $f{portal_connected}->($scfg, '[fd00::10]:3260', \@sessions),     'v6 portal matched against a differently spelled session line');
ok( $f{portal_connected}->($scfg, '[fd00:0:0:0::10]:3260', \@sessions), 'v6 portal matched as written');
ok(!$f{portal_connected}->($scfg, '[fd00::30]:3260', \@sessions),     'other v6 portal not matched');
ok(!$f{portal_connected}->($scfg, '[fd00::20]:3260', \@sessions),     'session for a longer IQN does not count (issue #124)');
ok(!$f{portal_connected}->($scfg, '192.168.1.68:3261', \@sessions),   'different port not matched');
ok(!$f{portal_connected}->({ tn_target_iqn => 'iqn.2005-10.org.freenas.ctl:other' }, '192.168.1.68:3260', \@sessions),
   'different IQN not matched');

# --- _bypath_portal: udev's spelling (no brackets, port always present) -------
is($f{bypath_portal}->('[fd42:7f7f:1::70]:3260'), 'fd42:7f7f:1::70:3260', 'v6 by-path portal unbracketed (observed udev name)');
is($f{bypath_portal}->('[fd42:7f7f:1::70]'),      'fd42:7f7f:1::70:3260', 'v6 without port gets 3260');
is($f{bypath_portal}->('192.168.1.68:3260,1'),    '192.168.1.68:3260',    'v4 unchanged, tpgt dropped');
is($f{bypath_portal}->('nas.example.com'),        'nas.example.com:3260', 'hostname gets 3260');

# --- _probe_portal reaches an IPv6 listener --------------------------------
SKIP: {
    my $lsn = IO::Socket::IP->new(LocalHost => '::1', LocalPort => 0, Listen => 1, Proto => 'tcp', V6Only => 1);
    skip "no IPv6 loopback", 3 unless $lsn;
    my $port = $lsn->sockport;
    ok(eval { $f{probe_portal}->("[::1]:$port"); 1 }, "probe connects to [::1]:$port") or diag $@;
    ok(eval { $f{probe_portal}->("::1"); 1 }, 'bare v6 without port is not probed (nothing to probe)');
    close $lsn;
    my $err = eval { $f{probe_portal}->("[::1]:$port"); 1 } ? '' : $@;
    like($err, qr/not reachable/, 'closed IPv6 port reported unreachable, not "host not found"');
}

done_testing();
