#!/usr/bin/perl -T
# Run with:  perl -T -I t/nvme/lib t/nvme/11-nsid-reserved.t   (PVE daemons run under -T)
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

# Cursor at 20 with 21 and 23 reserved: skips both.
$db{$_} = "z$_" for (1..20);
open(my $rf, '>', "$dir/nsid-reserved") or die; print $rf "21\n23 99\n"; close $rf;
open(my $sf, '>', "$dir/nsid-cursor-7") or die; print $sf "20\n"; close $sf;
is($mk->('/dev/zvol/a')->{nsid}, 22, 'reserved 21 is skipped');
is($mk->('/dev/zvol/b')->{nsid}, 24, 'reserved 23 is skipped (space-separated list read)');
# Reserved nsids do not move the max_used seed.
unlink "$dir/nsid-cursor-7"; delete $db{$_} for (21..24);
open($rf, '>', "$dir/nsid-reserved") or die; print $rf "500\n"; close $rf;
is($mk->('/dev/zvol/c')->{nsid}, 21, 'reserved 500 does not raise the no-cursor seed');
# No reserved file: behaves as before.
unlink "$dir/nsid-reserved";
open($sf, '>', "$dir/nsid-cursor-7") or die; print $sf "498\n"; close $sf;
$db{499} = 'x';
is($mk->('/dev/zvol/d')->{nsid}, 500, 'no reserved file: 500 is usable');
done_testing;
