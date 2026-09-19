#!/usr/bin/perl
# The planner of import-snapshots, exercised directly: four things the
# review found, each of which produced a plan that looked right.
#
#   1. the timeline was not a total order. Two snapshots PVE already has can
#      share a snaptime and have NO createtxg at all (PVE never records one),
#      so the sort ended in a tie and the order came from hash order - the
#      same configuration planned twice could chain the imports differently;
#   2. createtxg was used as a tiebreaker even when only ONE disk reported
#      one, ordering a half-dated candidate as if the array had dated all of
#      it;
#   3. the name check used ^...$, so a name ending in a newline passed
#      pve-configid and would have gone into the config file as a section
#      header plus a stray line;
#   4. the CLI's allow-list was a list of NAMES, so a snapshot destroyed and
#      recreated under the same name between the listing and the operator's
#      "yes" was imported in place of the one that was confirmed.
#
# Run with:  prove -v t/import-snapshots/04-import-plan-backlog.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;

my $PLUGIN = File::Spec->rel2abs("$FindBin::Bin/../../TrueNASPlugin.pm");
plan skip_all => "TrueNASPlugin.pm not found at $PLUGIN" unless -f $PLUGIN;

eval { require PVE::Storage; 1 };

unless (eval { require $PLUGIN; 1 }) {
    my $err = $@ || 'unknown error';
    plan skip_all => "no PVE perl modules here (needs libpve-storage-perl)"
        if $err =~ m{Can't locate PVE/(?:Tools|JSONSchema|Storage/Plugin)\.pm};
    plan tests => 1;
    fail("the plugin did not load, and not for lack of PVE");
    diag($err);
    exit 1;
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';

my $plan_fn;
my $name_fn;
{
    no strict 'refs';
    $plan_fn = \&{"${PKG}::_plan_snapshot_import"};
    $name_fn = \&{"${PKG}::_tn_snapshot_name_problem"};
    *{"${PKG}::_log"} = sub { 1 };
}
unless (defined(&$plan_fn) && defined(&$name_fn)) {
    plan tests => 1;
    fail('_plan_snapshot_import y _tn_snapshot_name_problem existen');
    exit 1;
}

my @VOLS = ('tn:vol-vm-9993-disk-0-lun0', 'tn:vol-vm-9993-disk-1-lun1');

# Build the { volid => { name => { ts, txg } } } the planner consumes.
# $spec: { name => [ ts, txg_disk0, txg_disk1 ] }, txg undef where absent.
sub by_volid {
    my ($spec) = @_;
    my $out = { map { $_ => {} } @VOLS };
    for my $name (keys %$spec) {
        my ($ts, @txg) = @{ $spec->{$name} };
        for my $i (0, 1) {
            $out->{ $VOLS[$i] }{$name} = { ts => $ts, txg => $txg[$i] };
        }
    }
    return $out;
}

# ------------------------------------ 1-2. a name is checked end to end ---
is($name_fn->('Daily-1'), undef, 'un nombre valido pasa');
ok(defined($name_fn->("Daily-1\n")),
    'un nombre con salto de linea al final NO es valido (\A...\z, no ^...$)');

# ----------------------------- 3-4. createtxg parcial no desempata nada ---
# 'alpha' and 'beta' were created in the same second. 'alpha' has a
# createtxg on one disk only. With that half txg used as a tiebreaker the
# two look distinguishable and both get imported, in an order the array
# never stated.
{
    my $plan = $plan_fn->({}, by_volid({
        alpha => [ 1789700000, 77, undef ],
        beta  => [ 1789700000, 99, 99 ],
    }), {});
    is(scalar(@{ $plan->{import} }), 0,
        'txg presente en un solo disco: el empate no se rompe, no se importa nada');
    like($plan->{invalid}{alpha} // '', qr/same creation time/,
        '  ...y se dice por que');
}

# 5. The same pair with a complete txg on both IS orderable.
{
    my $plan = $plan_fn->({}, by_volid({
        alpha => [ 1789700000, 77, 77 ],
        beta  => [ 1789700000, 99, 99 ],
    }), {});
    is_deeply([ map { $_->{name} } @{ $plan->{import} } ], [ 'alpha', 'beta' ],
        'con txg en TODOS los discos, el orden transaccional si desempata');
}

# --------------------------------- 6-7. la linea de tiempo es un orden total ---
# Eight snapshots PVE already has, all with the same snaptime and none with a
# createtxg: nothing but the name can order them. The candidate is newer than
# all of them, so its parent is whichever of the eight the sort puts last -
# and that answer has to be the same every run, on every node, or the same
# config planned twice chains differently.
{
    my @tied = map { "pve-tie-$_" } qw(a b c d e f g h);
    my %existing = map { $_ => { snaptime => 1789700000 } } @tied;
    my $plan = $plan_fn->(\%existing, by_volid({
        newcand => [ 1789800000, 500, 500 ],
    }), {});
    is(scalar(@{ $plan->{import} }), 1, 'el candidato mas nuevo se importa');
    is($plan->{import}[0]{parent}, 'pve-tie-h',
        'el parent sale del desempate documentado (nombre), no del orden de hash');
}

# ---------------------- 8-12. la lista blanca va atada a la IDENTIDAD ---
# First plan: what the operator is shown, with the identity of each entry.
{
    my $first = $plan_fn->({}, by_volid({
        'Daily-1' => [ 1789700000, 101, 101 ],
    }), {});
    is(scalar(@{ $first->{import} }), 1, 'primera pasada: un candidato');
    my $confirmed = [ { name    => $first->{import}[0]{name},
                        identity => $first->{import}[0]{identity} } ];
    ok(defined $confirmed->[0]{identity},
        '  ...que lleva una identidad, no solo un nombre');

    # Same data: the confirmation still refers to the same snapshot.
    my $same = $plan_fn->({}, by_volid({
        'Daily-1' => [ 1789700000, 101, 101 ],
    }), { only => $confirmed });
    is(scalar(@{ $same->{import} }), 1,
        'el mismo snapshot sigue ahi: se importa lo confirmado');

    # The retention task destroyed Daily-1 and the periodic task made a new
    # one under the same name. Same name, different snapshot.
    my $swapped = $plan_fn->({}, by_volid({
        'Daily-1' => [ 1789900000, 404, 404 ],
    }), { only => $confirmed });
    is(scalar(@{ $swapped->{import} }), 0,
        'mismo nombre, otro snapshot: NO se importa el que nadie confirmo');
    like($swapped->{invalid}{'Daily-1'} // '', qr/changed on TrueNAS/,
        '  ...y se informa de por que');
}

done_testing();
