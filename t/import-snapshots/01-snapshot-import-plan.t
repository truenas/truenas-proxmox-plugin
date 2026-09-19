#!/usr/bin/perl
# The planner that decides which snapshots taken on the TrueNAS side may be
# imported into a guest configuration - and, just as important, which may not.
#
# Background: snapshots created on the array (a periodic task, or a human on
# the TrueNAS UI) are invisible to the Snapshots tab, because that tab reads
# only $conf->{snapshots} in /etc/pve/qemu-server/<vmid>.conf. They are not
# harmless, though: one of them being newer than s1 makes `qm rollback s1`
# fail with "not most recent snapshot", and a rollback past it destroys it.
# `truenas-proxmox-manage import-snapshots` writes the missing sections so the
# GUI can see and delete them.
#
# Importing the wrong thing is worse than importing nothing: a section that
# covers only some of the disks leaves the others in unusedN on rollback, a
# name PVE folds to 'pending' poisons the config file, and a section placed
# in the chain by guesswork rolls a VM back to a state that never existed.
# So the planner is fail-closed, and this file pins both directions - the
# candidates it must accept and the ones it must refuse.
#
# Run with:  prove -v t/import-snapshots/01-snapshot-import-plan.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use JSON::PP;

my $PLUGIN = File::Spec->rel2abs("$FindBin::Bin/../../TrueNASPlugin.pm");
plan skip_all => "TrueNASPlugin.pm not found at $PLUGIN" unless -f $PLUGIN;

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
my $query = $PKG->can('_tn_snapshot_query_datasets');
my $plan  = $PKG->can('_plan_snapshot_import');

# A missing subroutine is a failure, not a skip: the whole point of this file
# is to go red on a plugin that cannot plan an import.
unless ($query && $plan) {
    plan tests => 2;
    ok($query, '_tn_snapshot_query_datasets existe');
    ok($plan,  '_plan_snapshot_import existe');
    exit 1;
}

# ---------------------------------------------------------------- fixture ---
# Real shape of pool.snapshot.query captured on the array, with the datasets
# and names rewritten to the cases below.
my $FIXTURE = "$FindBin::Bin/fixtures/tn-pool-snapshot-query.json";
open(my $fh, '<', $FIXTURE) or die "cannot read $FIXTURE: $!";
my $raw = do { local $/; <$fh> };
close($fh);
my $RECORDS = JSON::PP->new->decode($raw);

my $DS0 = 'pool/pve/vm-9990-disk-0';
my $DS1 = 'pool/pve/vm-9990-disk-1';
my $V0  = 'tnnvme:vol-vm-9990-disk-0-lun0';
my $V1  = 'tnnvme:vol-vm-9990-disk-1-lun1';
my $LONG = 'a' . ('b' x 40);   # 41 chars: one over what pve-configid accepts

my @calls;
my $api_answer = sub { return $RECORDS };
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"}      = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        push @calls, [ $method, $params ];
        return $api_answer->($method, $params);
    };
}

my $scfg = { tn_dataset => 'pool/pve' };

# Build a { volid => { name => {ts,txg} } } map by hand, for the cases that
# are about the planner and not about the wire format.
#   build({ name => [ [ts,txg] for V0, [ts,txg] for V1 ] })
# undef in place of a disk's pair means "not on that disk".
sub build {
    my ($spec) = @_;
    my $by = { $V0 => {}, $V1 => {} };
    for my $name (keys %$spec) {
        my ($a, $b) = @{ $spec->{$name} };
        $by->{$V0}{$name} = { ts => $a->[0], txg => $a->[1] } if $a;
        $by->{$V1}{$name} = { ts => $b->[0], txg => $b->[1] } if $b;
    }
    return $by;
}

sub names_of { return [ map { $_->{name} } @{ $_[0]->{import} } ] }

# Read one snapshot entry defensively, so that a plugin answering with the
# older flat shape (just an epoch) fails these assertions instead of dying on
# the first one and hiding every later verdict.
sub ts_of  { my ($e) = @_; return ref($e) eq 'HASH' ? $e->{ts}  : $e }
sub txg_of { my ($e) = @_; return ref($e) eq 'HASH' ? $e->{txg} : undef }

# ------------------------------------------------- 1-5. the query itself ---
my $by_ds = $query->($scfg, [ $DS0, $DS1 ]);
is(scalar(@calls), 1, 'una sola llamada a la API para ambos datasets');
is($calls[0][0], 'pool.snapshot.query', '  ...y es pool.snapshot.query');
is_deeply($calls[0][1][0], [ [ 'dataset', 'in', [ $DS0, $DS1 ] ] ],
    '  ...filtrada por dataset in [...] (nada de traerse la cabina entera)');
is_deeply($calls[0][1][1], { extra => { properties => ['creation'] } },
    '  ...pidiendo explicitamente la propiedad creation');
is(ref($by_ds->{$DS0}{'Daily-1'}), 'HASH', 'cada snapshot llega como {ts,txg}');
is(ts_of($by_ds->{$DS0}{'Daily-1'}), 1789707600, 'creation.rawvalue llega como epoch');
ok((txg_of($by_ds->{$DS0}{'Daily-1'}) // 0) > 0, 'createtxg llega como entero');

# 7-11. An answer the plugin cannot understand is an error, never "no
#       snapshots": an empty hash here would make every candidate look absent
#       and would report a full array as having nothing to import. The last
#       case is the one that matters most - an identity that is not a string
#       is a malformed answer, not a snapshot without a name.
for my $bad ( [ undef, 'respuesta nula' ],
              [ { }, 'respuesta que no es lista' ],
              [ [ 'not-a-hash' ], 'registro que no es hash' ],
              [ [ { dataset => $DS0 } ], 'registro sin nombre de snapshot' ],
              [ [ { dataset => [], snapshot_name => 'snap01' } ],
                'registro cuyo dataset no es un nombre' ],
              [ [ { dataset => $DS0, snapshot_name => {} } ],
                'registro cuyo snapshot_name no es un nombre' ] ) {
    my ($answer, $what) = @$bad;
    $api_answer = sub { return $answer };
    my $ok = eval { $query->($scfg, [ $DS0 ]); 1 };
    ok(!$ok, "$what: muere en vez de responder 'sin snapshots'");
}
$api_answer = sub { return $RECORDS };

# 13. Snapshots of a dataset we did not ask about are dropped, so a filter the
#     middleware silently ignored cannot smuggle a neighbour's snapshot in.
{
    my $only0 = $query->($scfg, [ $DS0 ]);
    is_deeply([ sort keys %$only0 ], [ $DS0 ],
        'solo se conservan los datasets consultados');
}

# 14-15. A creation time that is not a plain integer is not a creation time.
{
    $api_answer = sub {
        return [ { dataset => $DS0, snapshot_name => 'garbage', createtxg => '10',
                   properties => { creation => { rawvalue => '1789707600garbage' } } },
                 { dataset => $DS0, snapshot_name => 'zero', createtxg => '11',
                   properties => { creation => { rawvalue => '0' } } } ];
    };
    my $got = $query->($scfg, [ $DS0 ]);
    is(ts_of($got->{$DS0}{garbage}), undef, 'creation con basura pegada: no es fecha');
    is(ts_of($got->{$DS0}{zero}), undef, 'creation = 0: no es fecha');
    $api_answer = sub { return $RECORDS };
}

# ----------------------------------------------------------- the planner ---
my $by_volid = { $V0 => $by_ds->{$DS0}, $V1 => $by_ds->{$DS1} };
my $existing = { s1 => { snaptime => 1789610000 } };

# The array also holds 'cloned-snap', which something else is cloned from.
# The caller establishes that separately (one pool.dataset.query per
# candidate) and hands the verdict to the planner.
my %BLOCK = ( clone_blocked => { 'cloned-snap' => 1 } );

my $p = $plan->($existing, $by_volid, { %BLOCK });

# 16-21. >=5 positives: complete on every volume, name PVE can parse.
my %imported = map { $_->{name} => $_ } @{ $p->{import} };
for my $good (qw(auto-2026-09-18_00-00 Daily-1 tn-weekly-7 manual_snap snap2026)) {
    ok($imported{$good}, "importable: $good");
}
is(scalar(@{ $p->{import} }), 5, 'y no se cuela nada mas en la lista de importables');

# 22-23. snaptime is the array's creation time, not the time of the import.
is($imported{'Daily-1'}{snaptime}, 1789707600, 'snaptime = creation del snapshot');
is($imported{'snap2026'}{snaptime}, 1789718400, '  ...para cada uno el suyo');

# 24-27. The chain: each imported snapshot hangs off the newest snapshot older
#        than itself, the ones PVE already had included.
is($imported{'auto-2026-09-18_00-00'}{parent}, 's1',
    'el mas antiguo importado cuelga del ultimo snapshot que ya tenia PVE');
is($imported{'Daily-1'}{parent}, 'auto-2026-09-18_00-00', 'cadena por snaptime (2)');
is($imported{'tn-weekly-7'}{parent}, 'Daily-1', 'cadena por snaptime (3)');
is($imported{'snap2026'}{parent}, 'manual_snap', 'cadena por snaptime (4)');

# 28. The list comes back oldest first, which is the order it must be applied
#     in for the parents to exist when they are referenced.
is_deeply(names_of($p),
    [ qw(auto-2026-09-18_00-00 Daily-1 tn-weekly-7 manual_snap snap2026) ],
    'los importables salen ordenados de mas antiguo a mas nuevo');

# 29. The newest of everything is imported, so the guest's parent moves to it.
is($p->{new_parent}, 'snap2026', 'conf.parent pasa al importado mas nuevo');

# 30-36. >=5 negatives: names PVE would refuse, and names PVE reserves.
my %invalid = %{ $p->{invalid} };
like($invalid{'auto.bad'} // '', qr/valid/i, 'invalido: punto en el nombre');
like($invalid{'vzdump'} // '', qr/reserv/i, 'invalido: vzdump esta reservado');
like($invalid{'__base__'} // '', qr/reserv/i, 'invalido: __base__ esta reservado');
like($invalid{'__replicate_9990-0_1789700300'} // '', qr/reserv/i,
    'invalido: __replicate_*');
like($invalid{'pending'} // '', qr/reserv/i, 'invalido: pending mata a write_vm_config');
like($invalid{'current'} // '', qr/reserv/i, 'invalido: current lo usa la API');
like($invalid{$LONG} // '', qr/40|long/i, 'invalido: 41 caracteres');

# 37. No creation time from the array: refuse rather than invent one. A
#     section with snaptime 0 shows as 1970 in the GUI and breaks the order.
like($invalid{'no-creation'} // '', qr/creation|timestamp/i,
    'invalido: sin creation no se inventa la fecha');

# 38-39. Partial coverage is listed, with the volume that is missing, and is
#        NOT imported: a section without one of the disks sends that disk to
#        unusedN on rollback.
ok(!$imported{'partial-one'}, 'parcial: no se importa');
is_deeply($p->{partial}{'partial-one'}, [ $V1 ],
    '  ...y se dice en que volumen falta');

# 40. Already in the configuration: nothing to do, and the existing section is
#     never rewritten.
is_deeply($p->{present}, [ 's1' ], 'lo ya presente se salta');

# 41-43. A snapshot with a dependent clone cannot be deleted from PVE later
#        (ZFS refuses), so it is not imported - and the guard is checked in
#        both directions: the same snapshot, with no clone reported, IS
#        importable. A rule that refuses everything passes the first half.
ok(!$imported{'cloned-snap'}, 'con clon dependiente: no se importa');
like($invalid{'cloned-snap'} // '', qr/clone/i, '  ...y el motivo lo dice');
{
    my $q = $plan->($existing, $by_volid, {});
    my %imp = map { $_->{name} => 1 } @{ $q->{import} };
    ok($imp{'cloned-snap'}, 'sin clones: el mismo snapshot si se importa');
}

# 44-45. --match narrows the candidates without changing any verdict.
{
    my $q = $plan->($existing, $by_volid, { match => '^Daily-' });
    is_deeply(names_of($q), [ 'Daily-1' ], '--match deja solo lo que coincide');
    is($q->{new_parent}, 'Daily-1', '  ...y el parent se recalcula sobre eso');
}

# 46-47. 'only' is the allow-list the CLI uses to import exactly what the
#        operator confirmed, no more.
{
    my $q = $plan->($existing, $by_volid, { %BLOCK, only => [ 'Daily-1', 'snap2026' ] });
    is_deeply(names_of($q), [ 'Daily-1', 'snap2026' ], 'only: nada fuera de la lista');
    is($q->{import}[1]{parent}, 'Daily-1',
        '  ...y la cadena se calcula sobre lo que realmente se va a escribir');
}

# 48. If PVE already holds the newest snapshot, conf.parent must not move: the
#     imported ones are older, and stealing the pointer would rewrite history.
{
    my $newer = { s1 => { snaptime => 1789610000 },
                  s9 => { snaptime => 1789999999 } };
    my $q = $plan->($newer, $by_volid, { %BLOCK });
    is($q->{new_parent}, undef, 'si el mas nuevo ya era de PVE, conf.parent no se toca');
}

# 49. Second pass: everything importable is now in the config, so the plan is
#     empty. This is what makes the command idempotent.
{
    my %all = %$existing;
    $all{$_} = { snaptime => $imported{$_}{snaptime} } for keys %imported;
    my $q = $plan->(\%all, $by_volid, { %BLOCK });
    is(scalar(@{ $q->{import} }), 0, 'segunda pasada: no queda nada por importar');
}

# ------------------------------- 50-55. reserved names, whatever the case ---
# `Pending` passes pve-configid, and PVE's own handling is case-insensitive:
# write_vm_config dies on lc($snapname) eq 'pending' and the config parser
# matches the pending section with /i. A case-sensitive list would let the
# importer write a config file PVE then refuses to save.
{
    my $spec = {};
    $spec->{$_} = [ [1789700000, 10], [1789700000, 11] ]
        for qw(Pending PENDING Current VZDUMP __REPLICATE_9990-0 Pendingx);
    my $q = $plan->({}, build($spec), {});
    like($q->{invalid}{$_} // '', qr/reserv/i, "reservado sin importar mayusculas: $_")
        for qw(Pending PENDING Current VZDUMP __REPLICATE_9990-0);
    # ...and the guard does not overfire on a name that merely starts like one.
    my %imp = map { $_->{name} => 1 } @{ $q->{import} };
    ok($imp{'Pendingx'}, '  ...y "Pendingx" no es un nombre reservado');
}

# ------------------------ 56-58. creation must hold on EVERY disk (R5) ---
{
    my $q = $plan->({}, build({
        'half-dated' => [ [1789700000, 10], [undef, 11] ],
        'both-dated' => [ [1789700000, 12], [1789700000, 13] ],
    }), {});
    like($q->{invalid}{'half-dated'} // '', qr/creation|timestamp/i,
        'fecha en un solo disco: no basta, es invalido');
    my %imp = map { $_->{name} => 1 } @{ $q->{import} };
    ok(!$imp{'half-dated'}, '  ...y desde luego no se importa');
    ok($imp{'both-dated'}, '  ...mientras que con fecha en los dos si');
}

# ------------------------------- 59-61. same name is not same capture ---
# Two snapshots hours apart that happen to share a name are two snapshots.
# Rolling back to that section would pair one disk's Monday with the other
# disk's Tuesday.
{
    my $q = $plan->({}, build({
        'drift-2h'   => [ [1789700000, 10], [1789707200, 11] ],
        'skew-1h'    => [ [1789700000, 12], [1789703600, 13] ],
    }), {});
    like($q->{invalid}{'drift-2h'} // '', qr/differs by 7200s/,
        '2 h de diferencia entre discos: invalido, y dice cuanto');
    my %imp = map { $_->{name} => 1 } @{ $q->{import} };
    ok(!$imp{'drift-2h'}, '  ...no se importa');
    ok($imp{'skew-1h'}, '  ...pero 1 h justa (el limite) sigue siendo una captura');
}

# ------------------------------------ 62-66. ties: createtxg or nothing ---
{
    # Same second, different transaction groups: ZFS knows which came first.
    my $q = $plan->({}, build({
        'tie-a' => [ [1789700000, 100], [1789700000, 101] ],
        'tie-b' => [ [1789700000, 200], [1789700000, 201] ],
    }), {});
    is_deeply(names_of($q), [ 'tie-a', 'tie-b' ],
        'empate al segundo: createtxg da el orden real');
    is($q->{import}[1]{parent}, 'tie-a', '  ...y la cadena lo respeta');
    is($q->{new_parent}, 'tie-b', '  ...y conf.parent va al ultimo por txg');
}
{
    # No txg to break the tie: the order is a guess, so nothing is written.
    my $q = $plan->({}, build({
        'tie-x' => [ [1789700000, undef], [1789700000, undef] ],
        'tie-y' => [ [1789700000, undef], [1789700000, undef] ],
    }), {});
    is(scalar(@{ $q->{import} }), 0, 'empate sin createtxg: no se importa nada');
    like($q->{invalid}{'tie-x'} // '', qr/order|same creation/i,
        '  ...y se dice que el orden es desconocido');
}
{
    # Tied with a snapshot PVE already has: PVE sections carry no txg, so the
    # candidate cannot be placed in the chain either.
    my $q = $plan->({ s1 => { snaptime => 1789700000 } }, build({
        'tie-with-s1' => [ [1789700000, 100], [1789700000, 101] ],
    }), {});
    is(scalar(@{ $q->{import} }), 0, 'empate con un snapshot de PVE: tampoco');
    is($q->{new_parent}, undef, '  ...y conf.parent no se mueve');
}

# --------------------------------- 67-70. inserting in the middle ---------
# A snapshot from the array dated between two PVE snapshots hangs off the one
# before it; the PVE snapshot after it keeps its own parent, so the imported
# one shows up as a branch in the GUI tree. That is documented behaviour, not
# an accident: rewriting an existing section is out of scope.
{
    my $q = $plan->({ s1 => { snaptime => 100 }, s2 => { snaptime => 500 } },
        build({
            xmid => [ [300, 10], [300, 11] ],
            xnew => [ [900, 20], [900, 21] ],
        }), {});
    is_deeply(names_of($q), [ 'xmid', 'xnew' ], 'insercion a mitad de cadena');
    is($q->{import}[0]{parent}, 's1', '  ...el de en medio cuelga de s1');
    is($q->{import}[1]{parent}, 's2', '  ...y el nuevo del ultimo de PVE');
    is($q->{new_parent}, 'xnew', '  ...conf.parent al mas nuevo de todos');
}

done_testing();
