#!/usr/bin/perl
# import_foreign_snapshots() writes guest configuration. That is the one thing
# a storage plugin normally has no business doing, so every rule it follows is
# pinned here against stubbed PVE::QemuConfig / PVE::Storage primitives:
#
#   - it goes through lock_config + load_config + write_config, never by
#     editing text in /etc/pve;
#   - it only ADDS sections: an existing one is byte-for-byte the same after;
#   - a second run imports nothing and does not write at all - without that,
#     a cron calling this would rewrite the config of every VM forever;
#   - --dry-run does not even take the lock;
#   - NOTHING gathered before the lock is trusted inside it: the array is
#     asked again, and a snapshot that was destroyed, or gained a clone, or a
#     config that changed under us, cancels the write;
#   - two storages pointing at the same tn_dataset on different arrays are
#     kept apart, or a snapshot on one of them would look present on both;
#   - it refuses a template, a locked config, a snapshot mid-flight
#     (snapstate) and any non-cdrom disk living outside this plugin;
#   - a container is no longer refused, but it is not a VM either: it must
#     not go through PVE::QemuConfig at all (see 03-snapshot-import-lxc.t).
#
# Run with:  prove -v t/import-snapshots/02-snapshot-import-config.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use Storable qw(dclone);

my $PLUGIN = File::Spec->rel2abs("$FindBin::Bin/../../TrueNASPlugin.pm");
plan skip_all => "TrueNASPlugin.pm not found at $PLUGIN" unless -f $PLUGIN;

# On a node where this plugin is INSTALLED, loading PVE::Storage pulls every
# file in /usr/share/perl5/PVE/Storage/Custom into the same package - which
# would redefine the code under test with whatever version is installed. Load
# it first, so the file under test is the last word.
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
# A missing subroutine is a failure, not a skip: this file exists to go red on
# a plugin that cannot import.
unless ($PKG->can('import_foreign_snapshots')) {
    plan tests => 1;
    fail('import_foreign_snapshots existe');
    exit 1;
}

# ------------------------------------------------- stub PVE::QemuConfig ---
# The real module is not loadable outside a PVE node and pulls in qemu-server.
# These stubs keep the contract the plugin depends on: load_config hands out a
# COPY, so anything the plugin changes is only observable through
# write_config.
our %CONF;
our @WRITES;
our $LOCKS = 0;
our $BEFORE_LOCK;   # runs inside lock_config, before the plugin's code
{
    package PVE::QemuConfig;
    sub load_config {
        my ($class, $vmid) = @_;
        die "Configuration file for '$vmid' does not exist\n" if !$CONF{$vmid};
        return Storable::dclone($CONF{$vmid});
    }
    sub write_config {
        my ($class, $vmid, $conf) = @_;
        push @WRITES, Storable::dclone($conf);
        $CONF{$vmid} = Storable::dclone($conf);
    }
    sub lock_config {
        my ($class, $vmid, $code, @param) = @_;
        $LOCKS++;
        $BEFORE_LOCK->($vmid) if $BEFORE_LOCK;
        return $code->(@param);
    }
    # PVE's own "can this guest be snapshotted at all?". The plugin asks it
    # before writing, so a disk on a storage without the feature never gets
    # a section that `qm rollback` would die on.
    our $HAS_FEATURE = 1;
    sub has_feature {
        my ($class, $feature, $conf, $storecfg) = @_;
        return $HAS_FEATURE;
    }
    # Same key set and same order as PVE::QemuServer::Drive::valid_drive_names
    # for the keys this test uses.
    sub foreach_volume {
        my ($class, $conf, $func, @param) = @_;
        for my $key (qw(ide0 ide1 ide2 scsi0 scsi1 scsi2 virtio0 sata0
                        efidisk0 tpmstate0)) {
            my $str = $conf->{$key};
            next if !defined($str);
            my ($file, @opts) = split(/,/, $str);
            my $drive = { file => $file };
            for my $o (@opts) {
                my ($k, $v) = split(/=/, $o, 2);
                $drive->{$k} = $v;
            }
            $func->($key, $drive, @param);
        }
    }
    # Verbatim from PVE::AbstractConfig (PVE 9.2.4).
    sub __snapshot_copy_config {
        my ($class, $source, $dest) = @_;
        foreach my $k (keys %$source) {
            next if $k eq 'snapshots';
            next if $k eq 'snapstate';
            next if $k eq 'snaptime';
            next if $k eq 'vmstate';
            next if $k eq 'lock';
            next if $k eq 'digest';
            next if $k eq 'description';
            next if $k =~ m/^unused\d+$/;
            $dest->{$k} = $source->{$k};
        }
    }
}
$INC{'PVE/QemuConfig.pm'} = 1;

# The cluster file system is consulted only to say on WHICH node a guest
# lives when neither configuration file is here. Stubbed empty, so these
# tests never depend on what happens to exist in /etc/pve on the machine
# running them.
{
    package PVE::Cluster;
    sub get_vmlist { return { ids => {} } }
}
$INC{'PVE/Cluster.pm'} = 1;

# ---------------------------------------------------- stub the storage cfg ---
# tnnvme and tnother are two DIFFERENT arrays that happen to use the same
# dataset path - the case that made a snapshot present on one look present on
# both.
our $STORECFG = {
    ids => {
        tnnvme  => { type => 'truenasplugin', tn_dataset => 'pool/pve',
                     tn_api_host => 'array-a' },
        tnother => { type => 'truenasplugin', tn_dataset => 'pool/pve',
                     tn_api_host => 'array-b' },
        'local' => { type => 'dir' },
        'local-lvm' => { type => 'lvmthin' },
    },
};
{
    no strict 'refs';
    no warnings 'redefine';
    *{"PVE::Storage::config"} = sub { return $STORECFG };
}

# --------------------------------------------------------- stub the array ---
my $FIXTURE = "$FindBin::Bin/fixtures/tn-pool-snapshot-query.json";
open(my $fh, '<', $FIXTURE) or die "cannot read $FIXTURE: $!";
my $raw = do { local $/; <$fh> };
close($fh);
my $RECORDS = JSON::PP->new->decode($raw);

our @api;                 # every method called, in order
our $SNAPSHOT_ANSWER;     # sub ($scfg, $params, $nth_snapshot_query)
our $CLONE_ANSWER;        # sub ($scfg, $params)
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        push @api, $method;
        if ($method eq 'pool.snapshot.query') {
            my $nth = scalar(grep { $_ eq 'pool.snapshot.query' } @api);
            return $SNAPSHOT_ANSWER->($scfg, $params, $nth) if $SNAPSHOT_ANSWER;
            return $RECORDS;
        }
        if ($method eq 'pool.dataset.query') {
            return $CLONE_ANSWER->($scfg, $params) if $CLONE_ANSWER;
            # 'cloned-snap' is the origin of a live clone, so it must not be
            # imported - PVE could never delete it again. Every other
            # candidate comes back with no dependents.
            my $id = eval { $params->[0][0][2] } // '';
            return [ { id => 'pool/pve/a-clone' } ] if $id =~ /\@cloned-snap$/;
            return [];
        }
        die "unexpected API call $method\n";
    };
}

my $VMID = 9990;
sub base_conf {
    return {
        name     => 'importtest',
        memory   => 2048,
        cores    => 2,
        scsi0    => 'tnnvme:vol-vm-9990-disk-0-lun0,size=32G',
        scsi1    => 'tnnvme:vol-vm-9990-disk-1-lun1,size=8G',
        ide2     => 'local:iso/debian.iso,media=cdrom',
        parent   => 's1',
        snapshots => {
            s1 => {
                name   => 'importtest',
                memory => 2048,
                cores  => 2,
                scsi0  => 'tnnvme:vol-vm-9990-disk-0-lun0,size=32G',
                scsi1  => 'tnnvme:vol-vm-9990-disk-1-lun1,size=8G',
                ide2   => 'local:iso/debian.iso,media=cdrom',
                snaptime => 1789610000,
            },
        },
    };
}

sub reset_world {
    %CONF   = ($VMID => base_conf());
    @WRITES = ();
    @api    = ();
    $LOCKS  = 0;
    $BEFORE_LOCK     = undef;
    $PVE::QemuConfig::HAS_FEATURE = 1;
    $SNAPSHOT_ANSWER = undef;
    $CLONE_ANSWER    = undef;
}

# ------------------------------------------------------- 1-3. --dry-run ---
reset_world();
my $plan = $PKG->import_foreign_snapshots($VMID, { dry_run => 1 });
is(scalar(@{ $plan->{import} }), 5, 'dry-run: planifica los 5 importables');
is(scalar(@WRITES), 0, 'dry-run: NO escribe la configuracion');
is($LOCKS, 0, 'dry-run: ni siquiera toma el lock');

# --------------------------------------------------- 4-19. the real run ---
reset_world();
my $res = $PKG->import_foreign_snapshots($VMID, {});
is($res->{imported}, 5, 'importa los 5 snapshots completos y validos');
is($LOCKS, 1, 'todo el trabajo ocurre dentro de un unico lock_config');
is(scalar(@WRITES), 1, 'y en una sola escritura de la configuracion');

my $after = $CONF{$VMID};
my $snaps = $after->{snapshots};
is_deeply([ sort keys %$snaps ],
    [ sort qw(s1 auto-2026-09-18_00-00 Daily-1 tn-weekly-7 manual_snap snap2026) ],
    'las secciones nuevas son exactamente las importables');

my $sec = $snaps->{'Daily-1'};
is_deeply([ sort keys %$sec ],
    [ sort qw(name memory cores scsi0 scsi1 ide2 parent snaptime description) ],
    'la seccion lleva copia de la config actual mas snaptime/description/parent');
ok(!exists $sec->{vmstate}, 'sin vmstate: no se promete RAM que no existe');
ok(!exists $sec->{snapstate}, 'sin snapstate: la seccion nace terminada');
ok(!exists $sec->{snapshots}, 'sin snapshots anidados');
is($sec->{snaptime}, 1789707600, 'snaptime es el creation de la cabina');
like($sec->{description}, qr/TrueNAS/, 'la descripcion dice de donde sale');
like($sec->{description}, qr/no RAM/i, '  ...y que no hay RAM');
like($sec->{description}, qr{pool/pve/vm-9990-disk-0}, '  ...y nombra el dataset');
is($sec->{parent}, 'auto-2026-09-18_00-00', 'parent = el snapshot inmediatamente anterior');
is($snaps->{'auto-2026-09-18_00-00'}{parent}, 's1',
    'el primero importado cuelga del s1 que ya existia');
is($after->{parent}, 'snap2026', 'conf.parent pasa al importado mas nuevo');

# 20. Nothing outside snapshots/parent changes: the written config is the one
#     that was loaded, plus the new sections. A writer that rebuilt the config
#     from the snapshot sections would pass every assertion above.
{
    my %top_after  = map { $_ => $after->{$_} }
        grep { $_ ne 'snapshots' && $_ ne 'parent' } keys %$after;
    my $before = base_conf();
    my %top_before = map { $_ => $before->{$_} }
        grep { $_ ne 'snapshots' && $_ ne 'parent' } keys %$before;
    is_deeply(\%top_after, \%top_before,
        'el resto de la configuracion de la VM queda intacta');
}

# 21. The one thing this command must never do: touch a section PVE wrote.
is_deeply($snaps->{s1}, base_conf()->{snapshots}{s1},
    'la seccion preexistente queda byte a byte igual');

# --------------------------------------- 22-23. second pass (idempotencia) ---
@WRITES = ();
$LOCKS  = 0;
my $second = $PKG->import_foreign_snapshots($VMID, {});
is($second->{imported}, 0, 'segunda pasada: 0 importados');
is(scalar(@WRITES), 0, '  ...y NO se llama a write_config');

# ------------------------- 24-27. nothing from before the lock is trusted ---
# The array is asked again inside the lock. A snapshot destroyed between the
# listing and the write must not be written from the stale answer.
{
    reset_world();
    $SNAPSHOT_ANSWER = sub {
        my ($scfg, $params, $nth) = @_;
        return $nth == 1 ? $RECORDS : [];
    };
    my $r = $PKG->import_foreign_snapshots($VMID, {});
    is($r->{imported}, 0, 'el candidato desaparecio de la cabina: 0 importados');
    is(scalar(@WRITES), 0, '  ...y no se escribe nada');
    is(scalar(@{ $r->{dropped} }), 5, '  ...se informa de los 5 descartados');
    ok((grep { $_ eq 'pool.snapshot.query' } @api) >= 2,
        '  ...porque la cabina se vuelve a consultar DENTRO del lock');
}

# 28-29. A candidate that gained a clone between listing and lock is dropped
#        the same way.
{
    reset_world();
    my $late = 0;
    $BEFORE_LOCK  = sub { $late = 1 };   # the clone appears while we wait
    $CLONE_ANSWER = sub {
        my ($scfg, $params) = @_;
        my $id = $params->[0][0][2] // '';
        return [ { id => 'pool/pve/late-clone' } ]
            if $late && $id =~ /\@snap2026$/;
        return [];
    };
    my $r = $PKG->import_foreign_snapshots($VMID, {});
    my %imp = map { $_->{name} => 1 } @{ $r->{import} };
    ok(!$imp{'snap2026'}, 'clon aparecido antes del lock: ese no se importa');
    is_deeply($r->{dropped}, [ 'snap2026' ], '  ...y se informa de el');
}

# 30-31. The configuration can change under us too; the re-check happens with
#        the lock held.
{
    reset_world();
    $BEFORE_LOCK = sub { $CONF{$VMID}{lock} = 'backup' };
    my $ok = eval { $PKG->import_foreign_snapshots($VMID, {}); 1 };
    ok(!$ok, 'conf bloqueada mientras teniamos el lock: muere');
    is(scalar(@WRITES), 0, '  ...sin escribir nada');
}
{
    reset_world();
    $BEFORE_LOCK = sub { $CONF{$VMID}{scsi1} = 'tnnvme:vol-vm-9990-disk-7-lun7,size=8G' };
    my $ok = eval { $PKG->import_foreign_snapshots($VMID, {}); 1 };
    ok(!$ok, 'los discos cambiaron mientras teniamos el lock: muere');
    is(scalar(@WRITES), 0, '  ...sin escribir nada');
}

# 34-35. A clone lookup that fails establishes nothing, so it must not be read
#        as "no clones".
{
    reset_world();
    $CLONE_ANSWER = sub { die "middleware error\n" };
    my $ok = eval { $PKG->import_foreign_snapshots($VMID, {}); 1 };
    ok(!$ok, 'si la consulta de clones falla, el import muere');
    is(scalar(@WRITES), 0, '  ...sin escribir nada');
}

# ------------------- 36-38. two arrays, one dataset path: kept apart ---
# scsi0 and scsi1 live on different storages whose tn_dataset is the same and
# whose zvol name is the same, so both resolve to pool/pve/vm-9990-disk-0.
# Merging the two answers made 'only-on-b' look present on both disks.
{
    reset_world();
    $CONF{$VMID}{scsi1} = 'tnother:vol-vm-9990-disk-0-lun1,size=8G';
    delete $CONF{$VMID}{snapshots};
    delete $CONF{$VMID}{parent};
    $SNAPSHOT_ANSWER = sub {
        my ($scfg, $params, $nth) = @_;
        return [] if $scfg->{tn_api_host} eq 'array-a';
        return [ { dataset => 'pool/pve/vm-9990-disk-0', snapshot_name => 'only-on-b',
                   createtxg => '55',
                   properties => { creation => { rawvalue => '1789700000' } } } ];
    };
    my $r = $PKG->import_foreign_snapshots($VMID, { dry_run => 1 });
    # NOT 'imported': a dry run never imports, so counting that would pass
    # with the two arrays merged. What must be empty is the PLAN.
    is(scalar(@{ $r->{import} }), 0,
        'snapshot presente solo en la cabina B: no entra en el plan');
    is_deeply($r->{partial}{'only-on-b'}, [ 'tnnvme:vol-vm-9990-disk-0-lun0' ],
        '  ...se reporta como parcial, y falta en el volumen de la cabina A');
    is(scalar(@WRITES), 0, '  ...y no se escribe nada');
}

# ------------------------------------------------------- 39-44. refusals ---
sub refuses {
    my ($mangle) = @_;
    reset_world();
    $mangle->($CONF{$VMID});
    my $ok = eval { $PKG->import_foreign_snapshots($VMID, {}); 1 };
    my $err = $ok ? '' : ($@ // 'died');
    return ($err, scalar(@WRITES));
}

{
    my ($err, $writes) = refuses(sub { $_[0]->{template} = 1 });
    ok($err && !$writes, 'template: se rehusa y no escribe nada');
}
{
    my ($err, $writes) = refuses(sub { $_[0]->{lock} = 'backup' });
    ok($err && !$writes, 'config con lock: se rehusa y no escribe nada');
}
{
    my ($err, $writes) = refuses(sub { $_[0]->{snapshots}{s1}{snapstate} = 'prepare' });
    ok($err && !$writes, 'snapshot con snapstate: se rehusa y no escribe nada');
}
{
    my ($err, $writes) = refuses(sub { $_[0]->{scsi1} = 'local-lvm:vm-9990-disk-0,size=8G' });
    ok($err && !$writes, 'disco fuera del plugin: se rehusa y no escribe nada');
}
{
    # Everything this plugin can see is fine, and PVE still says no - a raw
    # device, a storage without the feature. Its answer wins.
    reset_world();
    $PVE::QemuConfig::HAS_FEATURE = 0;
    my $ok = eval { $PKG->import_foreign_snapshots($VMID, {}); 1 };
    my $err = $ok ? '' : ($@ // '');
    like($err, qr/cannot be snapshotted/,
        'has_feature(snapshot) falso: se rehusa');
    is(scalar(@WRITES), 0, '  ...sin escribir nada');
}
{
    # A VMID with an /etc/pve/lxc/<vmid>.conf is a container, and a
    # container is not a VM: the QemuConfig stubs in this file must not be
    # reached at all. What a container then DOES is the subject of
    # 03-snapshot-import-lxc.t; here it only has to stop being a VM.
    reset_world();
    my $dir = tempdir(CLEANUP => 1);
    open(my $lxc, '>', "$dir/$VMID.conf") or die $!;
    close($lxc);
    no strict 'refs';
    no warnings 'redefine';
    local ${"${PKG}::TN_LXC_CONF_DIR"} = $dir;
    my $qemu_loads = 0;
    local *PVE::QemuConfig::load_config = sub { $qemu_loads++; die "not a VM\n" };
    eval { $PKG->import_foreign_snapshots($VMID, {}) };
    is($qemu_loads, 0, 'vmid de contenedor: no pasa por PVE::QemuConfig');
    is(scalar(@WRITES), 0, '  ...sin escribir nada');
}

# ------------------------------------------------------------ 45-50. CLI ---
sub run_cli {
    my (@args) = @_;
    my ($out, $err) = ('', '');
    my $rc;
    {
        open(my $stdin, '<', \"\n") or die $!;   # a pipe, never a TTY
        local *STDIN = $stdin;
        open(my $oldout, '>&', \*STDOUT) or die $!;
        open(my $olderr, '>&', \*STDERR) or die $!;
        close(STDOUT); open(STDOUT, '>', \$out) or die $!;
        close(STDERR); open(STDERR, '>', \$err) or die $!;
        $rc = eval { $PKG->can('snapshot_import_cli')->(@args) };
        my $died = $@;
        close(STDOUT); open(STDOUT, '>&', $oldout) or die $!;
        close(STDERR); open(STDERR, '>&', $olderr) or die $!;
        die $died if $died;
    }
    return ($rc, $out, $err);
}

{
    reset_world();
    my ($rc, $out) = run_cli($VMID, '--dry-run');
    is($rc, 0, 'CLI --dry-run: exit 0');
    like($out, qr/^import\s+Daily-1/m, '  ...lista los importables');
    is(scalar(@WRITES), 0, '  ...y no escribe');
}
{
    # No --yes and no terminal to ask on: a refusal, and a refusal is not 0.
    reset_world();
    my ($rc, $out, $err) = run_cli($VMID);
    is($rc, 2, 'CLI sin --yes y sin TTY: exit 2 (EXIT_USER_CANCEL)');
    like($err, qr/no TTY/i, '  ...diciendo por que');
    is(scalar(@WRITES), 0, '  ...sin escribir nada');
}
{
    reset_world();
    my ($rc, $out) = run_cli($VMID, '--yes');
    is($rc, 0, 'CLI --yes: exit 0');
    like($out, qr/Imported 5 snapshot/, '  ...e importa lo que habia listado');
}

done_testing();
