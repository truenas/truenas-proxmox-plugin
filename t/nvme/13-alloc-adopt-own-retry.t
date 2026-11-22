#!/usr/bin/perl
# Verifies the #151 fix: each pool.dataset.create attempt stamps a random marker
# into the zvol's comments, and when a retried create is answered "dataset
# already exists", alloc_image adopts the zvol only if the array reports a
# VOLUME of exactly the requested size whose comments equal that marker.
# Anything else keeps the old move-to-the-next-name path.
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
    unless $PKG->can('_alloc_zvol_is_own_retry') && $PKG->can('_alloc_create_marker');

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
sub _own    { no strict 'refs'; return &{"${PKG}::_alloc_zvol_is_own_retry"}(@_); }
sub _marker { no strict 'refs'; return &{"${PKG}::_alloc_create_marker"}(); }

# The marker
my $M = _marker();
like($M, qr/^Autocreated by Proxmox Plugin \([0-9a-f]{32}\)$/, 'marker keeps the old prefix plus 32 hex chars');
my %seen = map { _marker() => 1 } 1..200;
is(scalar(keys %seen), 200, '200 markers are all distinct');

my $other0 = _marker();
my $DS = 'tank/pve/vm-9089-disk-1';
my $BYTES = 34359738368;
sub row { my (%o) = @_; return [ {
    id => $DS, type => $o{type} // 'VOLUME',
    volsize  => exists $o{volsize}  ? $o{volsize}  : { rawvalue => "$BYTES", parsed => $BYTES },
    (exists $o{comments} ? (defined $o{comments} ? (comments => $o{comments}) : ())
                         : (comments => { value => $M, rawvalue => $M, source => 'LOCAL' })),
    ($o{user_properties} ? (user_properties => $o{user_properties}) : ()),
} ]; }

$reply = row();
is(_own({}, $DS, $BYTES, $M), 1, 'VOLUME, same size, our marker -> own');
is($calls[0][0], 'pool.dataset.query', 'asks pool.dataset.query');
is_deeply($calls[0][1][0], [ [ 'id', '=', $DS ] ], 'filters on the exact dataset id');

$reply = row(comments => $M);
is(_own({}, $DS, $BYTES, $M), 1, 'comments as a plain string -> own');
$reply = row(comments => undef, user_properties => { comments =>
    { parsed => $M, rawvalue => $M, value => $M, source => 'LOCAL', source_info => undef } });
is(_own({}, $DS, $BYTES, $M), 1, 'marker in user_properties.comments (how 25.10 returns a VOLUME) -> own');
$reply = row(comments => undef, user_properties => { comments => { value => $other0 } });
is(_own({}, $DS, $BYTES, $M), 0, 'another marker in user_properties.comments -> not own');
$reply = row(comments => undef, user_properties => { 'org.freenas:description' => { value => $M } });
is(_own({}, $DS, $BYTES, $M), 1, 'marker under the raw ZFS property name -> own');

my $other = _marker();
$reply = row(comments => { value => $other });
is(_own({}, $DS, $BYTES, $M), 0, 'another attempt\'s marker (same-name alloc elsewhere) -> not own');
$reply = row(comments => { value => 'Autocreated by Proxmox Plugin' });
is(_own({}, $DS, $BYTES, $M), 0, 'old unmarked comment (async-delete leftover) -> not own');
$reply = row(comments => undef);
is(_own({}, $DS, $BYTES, $M), 0, 'no comments -> not own');
$reply = row(comments => { value => "$M " });
is(_own({}, $DS, $BYTES, $M), 0, 'marker must match exactly');
$reply = row();
is(_own({}, $DS, $BYTES, ''), 0, 'empty marker never matches');
is(_own({}, $DS, $BYTES, undef), 0, 'undef marker never matches');

$reply = row(volsize => { rawvalue => $BYTES * 2 });
is(_own({}, $DS, $BYTES, $M), 0, 'different size -> not own');
$reply = row(type => 'FILESYSTEM');
is(_own({}, $DS, $BYTES, $M), 0, 'a filesystem -> not own');
$reply = row(volsize => { rawvalue => undef });
is(_own({}, $DS, $BYTES, $M), 0, 'no volsize -> not own');
$reply = [];
is(_own({}, $DS, $BYTES, $M), 0, 'dataset not found -> not own');
$reply = [ @{ row() }, @{ row() } ];
is(_own({}, $DS, $BYTES, $M), 0, 'two rows -> not own');
$reply = { error => 1 };
is(_own({}, $DS, $BYTES, $M), 0, 'not a list -> not own');
$die = "broker: read timeout\n";
is(_own({}, $DS, $BYTES, $M), 0, 'query fails -> not own, does not die');
$die = undef;

# alloc_image must stamp a fresh marker per attempt into the create payload,
# and check ownership against it before it moves on to the next name.
my $src = do { local $/; open(my $fh, '<', $PLUGIN) or die; <$fh> };
like($src, qr/while \(\$create_attempt < \$max_create_retries\) \{.*?my \$alloc_marker = _alloc_create_marker\(\);.*?comments\s+=> \$alloc_marker,.*?'pool\.dataset\.create'/s,
    'a fresh marker per attempt goes into the create payload');
like($src, qr/dataset already exists\/i\) \{\n\s+if \(_alloc_zvol_is_own_retry\(\$scfg, \$full_ds, \$bytes, \$alloc_marker\)\) \{/,
    'the own-retry check runs first on "already exists", against this attempt\'s marker');

done_testing();
