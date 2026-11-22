#!/usr/bin/perl
# Verifies the #151 fix: when a retried pool.dataset.create is answered
# "dataset already exists", alloc_image adopts the zvol only if the array
# reports a VOLUME of exactly the requested size created no earlier than the
# create attempt began (less the clock-skew allowance). Anything else keeps
# the old move-to-the-next-name path.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/13-alloc-adopt-own-retry.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
plan skip_all => "_alloc_zvol_is_own_retry helper missing"
    unless $PKG->can('_alloc_zvol_is_own_retry');

my ($reply, $die, @calls);
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_api_call"} = sub {
        push @calls, [ @_[1, 2] ];
        die $die if defined $die;
        return $reply;
    };
}
sub _own { no strict 'refs'; return &{"${PKG}::_alloc_zvol_is_own_retry"}(@_); }

my $DS = 'tank/pve/vm-9089-disk-1';
my $BYTES = 34359738368;
my $T0 = 1795309850;
sub row { my (%o) = @_; return [ {
    id => $DS, type => $o{type} // 'VOLUME',
    creation => exists $o{creation} ? $o{creation} : { rawvalue => "$T0", value => 'x' },
    volsize  => exists $o{volsize}  ? $o{volsize}  : { rawvalue => "$BYTES", parsed => $BYTES },
} ]; }

$reply = row();
is(_own({}, $DS, $BYTES, $T0), 1, 'created in the attempt second, same size -> own');
is($calls[0][0], 'pool.dataset.query', 'asks pool.dataset.query');
is_deeply($calls[0][1][0], [ [ 'id', '=', $DS ] ], 'filters on the exact dataset id');
is_deeply($calls[0][1][1]{extra}{properties}, [ 'creation', 'volsize' ], 'asks for creation and volsize');

$reply = row(creation => { rawvalue => $T0 + 9 });
is(_own({}, $DS, $BYTES, $T0), 1, 'created during the attempt -> own');
$reply = row(creation => { rawvalue => $T0 - 10 });
is(_own({}, $DS, $BYTES, $T0), 1, 'within the clock-skew allowance -> own');
$reply = row(creation => { rawvalue => $T0 - 11 });
is(_own({}, $DS, $BYTES, $T0), 0, 'older than the allowance (async-delete leftover) -> not own');
$reply = row(creation => { rawvalue => $T0 - 86400 });
is(_own({}, $DS, $BYTES, $T0), 0, 'a day old -> not own');

$reply = row(volsize => { rawvalue => $BYTES * 2 });
is(_own({}, $DS, $BYTES, $T0), 0, 'different size -> not own');
$reply = row(type => 'FILESYSTEM');
is(_own({}, $DS, $BYTES, $T0), 0, 'a filesystem -> not own');
$reply = row(creation => undef);
is(_own({}, $DS, $BYTES, $T0), 0, 'no creation -> not own');
$reply = row(creation => { rawvalue => 'Sat Nov 21' });
is(_own({}, $DS, $BYTES, $T0), 0, 'non-numeric creation -> not own');
$reply = row(volsize => { rawvalue => undef });
is(_own({}, $DS, $BYTES, $T0), 0, 'no volsize -> not own');
$reply = [];
is(_own({}, $DS, $BYTES, $T0), 0, 'dataset not found -> not own');
$reply = [ @{ row() }, @{ row() } ];
is(_own({}, $DS, $BYTES, $T0), 0, 'two rows -> not own');
$reply = { error => 1 };
is(_own({}, $DS, $BYTES, $T0), 0, 'not a list -> not own');
$die = "broker: read timeout\n";
is(_own({}, $DS, $BYTES, $T0), 0, 'query fails -> not own, does not die');
$die = undef;

# alloc_image must check before it moves on to the next name, and must
# stamp the attempt start before it sends the create.
my $src = do { local $/; open(my $fh, '<', $PLUGIN) or die; <$fh> };
like($src, qr/my \$attempt_started = time\(\);\n\s+eval \{\n\s+\$create_result = _api_call\(\s*\$scfg,\s*'pool\.dataset\.create'/,
    'attempt start is taken just before pool.dataset.create');
like($src, qr/dataset already exists\/i\) \{\n\s+if \(_alloc_zvol_is_own_retry\(\$scfg, \$full_ds, \$bytes, \$attempt_started\)\) \{/,
    'the own-retry check runs first on "already exists"');

done_testing();
