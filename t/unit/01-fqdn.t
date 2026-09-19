#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Socket qw(getaddrinfo getnameinfo AF_INET SOCK_STREAM NI_NUMERICHOST NIx_NOSERV);

# Contract tests for FQDN handling. The plugin itself cannot be loaded
# here (it needs PVE::Storage), so this file pins the matching rules
# that TrueNASPlugin.pm::_portal_match_needles / _portal_connected and
# tools/truenas-plugin-broker::_host_ipv4 must keep.

sub portal_needles {
    my ($portal, @ips) = @_;
    my $norm = $portal // '';
    $norm =~ s/^\s+|\s+$//g;
    $norm =~ s/,\d+$//;
    return () unless $norm;
    my @needles = ($norm);
    if ($norm =~ /^([^:]+):(\d+)$/) {
        my ($host, $port) = ($1, $2);
        if ($host !~ /^\d+\.\d+\.\d+\.\d+$/) {
            push @needles, map { "$_:$port" } @ips;
        }
    }
    my %seen;
    return grep { !$seen{$_}++ } @needles;
}

sub portal_connected {
    my ($iqn, $portal, $session_lines, @ips) = @_;
    return 0 unless $iqn;
    my @needles = portal_needles($portal, @ips);
    return 0 unless @needles;
    for my $line (@$session_lines) {
        next unless index($line, $iqn) >= 0;
        for my $needle (@needles) {
            return 1 if index($line, $needle) >= 0;
        }
    }
    return 0;
}

my $iqn = 'iqn.2025-10.ru.fivegen.local.vm-storage.ctl:iscsi-vm-storage-hdd';
my @session = (
    "tcp: [1] 192.168.135.129:3260,1 $iqn",
);

ok(
    !portal_connected($iqn, 'vm-storage.local.fivegen.ru:3260', \@session),
    'hostname portal does not match an IP session without DNS'
);
ok(
    portal_connected($iqn, 'vm-storage.local.fivegen.ru:3260', \@session, '192.168.135.129'),
    'hostname portal matches after resolving the A record'
);
ok(
    portal_connected($iqn, '192.168.135.129:3260', \@session),
    'IPv4 portal still matches the IP session'
);
ok(
    !portal_connected($iqn, 'other.example.com:3260', \@session, '10.0.0.9'),
    'a different hostname/IP does not steal the session'
);
ok(
    !portal_connected(
        'iqn.other:target',
        'vm-storage.local.fivegen.ru:3260',
        \@session,
        '192.168.135.129'
    ),
    'same portal IP on a different IQN is not a match'
);

is_deeply(
    [ portal_needles('nas.example.com:3260', '192.0.2.10', '192.0.2.11') ],
    [ 'nas.example.com:3260', '192.0.2.10:3260', '192.0.2.11:3260' ],
    'needles include the FQDN and every resolved A record'
);

# Resolver used by _host_ipv4 / broker must not depend on Socket::gethostbyname.
my ($err, @res) = getaddrinfo('localhost', '', {
    family   => AF_INET,
    socktype => SOCK_STREAM,
});
ok(!$err && @res, "getaddrinfo(localhost) works ($err)");
if (!$err && @res) {
    my ($nerr, $ip) = getnameinfo($res[0]{addr}, NI_NUMERICHOST, NIx_NOSERV);
    ok(!$nerr && $ip =~ /^\d+\.\d+\.\d+\.\d+$/, "getnameinfo returned IPv4 $ip");
} else {
    fail('getnameinfo skipped because getaddrinfo failed');
}

if (defined &Socket::gethostbyname) {
    ok(eval { Socket::gethostbyname('localhost'); 1 },
       'Socket::gethostbyname still callable on this Perl');
} else {
    ok(!eval { Socket::gethostbyname('localhost'); 1 },
       'Socket::gethostbyname is absent — calling it must not be the resolver');
}

done_testing();
