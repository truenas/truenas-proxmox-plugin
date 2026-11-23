#!/usr/bin/perl -T
# Run with:  perl -T -I t/nvme/lib t/nvme/10-nsid-cursor.t   (PVE daemons run under -T)
use strict; use warnings; use Test::More; use FindBin; use File::Temp qw(tempdir);
my ($PLUGIN) = ("$FindBin::Bin/../../TrueNASPlugin.pm" =~ /^(.*)$/);
require $PLUGIN;
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $dir = tempdir(CLEANUP => 1);
my %db;            # nsid => device_path
my @creates; my $collide_once = 0;
{
    no strict 'refs'; no warnings 'redefine';
    ${"${PKG}::TN_NSID_CURSOR_DIR"} = $dir;
    *{"${PKG}::_log"} = sub {};
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $m, $args) = @_;
        if ($m eq 'nvmet.namespace.query') {
            my $f = $args->[0][0];
            if ($f->[0] eq 'device_path') {
                return [ map { { nsid => $_, device_path => $db{$_}, device_uuid => "u$_" } }
                         grep { $db{$_} eq $f->[2] } keys %db ];
            }
            return [ map { { nsid => $_ } } keys %db ];
        }
        if ($m eq 'nvmet.namespace.create') {
            my $p = $args->[0];
            push @creates, $p->{nsid};
            die "nsid not given\n" unless defined $p->{nsid};
            if ($collide_once) { $collide_once = 0; $db{$p->{nsid}} = 'other'; die "nsid $p->{nsid} already in use\n"; }
            die "nsid $p->{nsid} already in use\n" if exists $db{$p->{nsid}};
            $db{$p->{nsid}} = $p->{device_path};
            return { nsid => $p->{nsid}, device_uuid => "u$p->{nsid}" };
        }
        die "unexpected $m";
    };
}
my $create = $PKG->can('_nvme_create_namespace_idempotent');
my $mk = sub { $create->({}, { subsys_id => 7, device_type => 'ZVOL', device_path => $_[0], enabled => 1 }) };

# Fresh subsystem, no cursor file: continue after max used (upstream monotonic).
$db{$_} = "y$_" for (1..5);
my $ns = $mk->('/dev/zvol/fresh');
is($ns->{nsid}, 6, 'no cursor file: seeded from max used, picks max+1');
delete $db{$_} for (1..6); unlink "$dir/nsid-cursor-7";
# The live state: high nsids occupied (ceiling reached), low ones free.
$db{$_} = "z$_" for (962, 1007, 1020, 1022, 1023, 1..20);
{   # at the ceiling with no cursor: random start, not lowest free
    my %seen; my $low = 0;
    for my $i (1..300) {
        unlink "$dir/nsid-cursor-7";
        my $r = $mk->("/dev/zvol/r$i"); $seen{$r->{nsid}}++; $low++ if $r->{nsid} == 21;
        delete $db{$r->{nsid}};
    }
    ok(keys(%seen) > 100 && $low < 30, 'no cursor at ceiling: random start, not always lowest free');
    unlink "$dir/nsid-cursor-7";
}
open(my $sf, '>', "$dir/nsid-cursor-7") or die; print $sf "20\n"; close $sf;
$ns = $mk->('/dev/zvol/a');
is($ns->{nsid}, 21, 'seeded cursor 20: picks 21 (never TN auto-assign)');
$ns = $mk->('/dev/zvol/b');
is($ns->{nsid}, 22, 'next create advances the cursor');
delete $db{21};                       # a slot freed just now
$ns = $mk->('/dev/zvol/c');
is($ns->{nsid}, 23, 'recently freed nsid 21 is NOT reused');
# wrap-around
open(my $fh, '>', "$dir/nsid-cursor-7") or die; print $fh "1021\n"; close $fh;
$ns = $mk->('/dev/zvol/d');
is($ns->{nsid}, 21, 'cursor 1021 skips used 1022/1023 and wraps to first free (21)');
# reuse path untouched
@creates = ();
$ns = $mk->('/dev/zvol/d');
is_deeply(\@creates, [], 'existing namespace for device_path is reused, no create');
# collision retry
$collide_once = 1;
$ns = $mk->('/dev/zvol/e');
is($ns->{nsid}, 25, 'collision on 24 retries with the next cursor nsid');
# corrupt cursor file: treated as missing
open(my $gf, '>', "$dir/nsid-cursor-7") or die; print $gf "garbage\n"; close $gf;
$ns = $mk->('/dev/zvol/g');
ok($ns->{nsid} >= 1 && $ns->{nsid} <= 1023 && $db{$ns->{nsid}} eq '/dev/zvol/g', 'corrupt cursor: treated as missing, picks a free nsid');
# unusable cursor dir: create fails rather than pick without the cursor
{ no strict 'refs'; ${"${PKG}::TN_NSID_CURSOR_DIR"} = '/proc/nonexistent/x'; }
my $before = scalar(@creates);
ok(!eval { $mk->('/dev/zvol/h'); 1 } && $@ =~ /cursor unavailable/, 'unusable cursor dir: create dies, no fallback pick');
is(scalar(@creates), $before, 'no nvmet.namespace.create was attempted');
{ no strict 'refs'; ${"${PKG}::TN_NSID_CURSOR_DIR"} = $dir; }
# perl -T (PVE daemons): a tainted subsys id must not reach open()
{
    my $tainted7 = substr($ENV{PATH}, 0, 0) . '7';
    SKIP: {
        skip 'not running under -T', 2 unless ${^TAINT};
        unlink "$dir/nsid-cursor-7";
        my $r = eval { $create->({}, { subsys_id => $tainted7, device_type => 'ZVOL', device_path => '/dev/zvol/taint', enabled => 1 }) };
        ok($r && $r->{nsid}, 'tainted subsys id: create succeeds under -T') or diag($@);
        open(my $cf, '<', "$dir/nsid-cursor-7"); my $c = $cf ? <$cf> : ''; chomp $c;
        is($c, $r ? $r->{nsid} : -1, 'tainted subsys id: cursor file written with the picked nsid');
    }
}
# full subsystem dies rather than auto-assign
$db{$_} //= "f$_" for 1..1023;
ok(!eval { $mk->('/dev/zvol/full'); 1 } && $@ =~ /no free nsid/, 'full subsystem dies, no auto-assign');
done_testing;
