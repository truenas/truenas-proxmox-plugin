package PVE::Storage::Custom::TrueNASPlugin;

use v5.36;
use JSON::PP qw(encode_json);
use File::Basename;
use PVE::Tools qw(run_command trim);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

# ======== Definition ========

# Storage Plugin API version; compatible with current libpve-storage-perl.
# See Proxmox "Writing a Storage Plugin" doc for versioning details.
sub api { return 11; }  # adjust if your host requires newer APIVER

# The storage "type" string users put into storage.cfg
sub type { return 'truenasplugin'; }

# Metadata: we only expose block images (RAW) for VMs, and mark as "select_existing"
sub plugindata {
    return {
        content         => [ { images => 1, none => 1 }, { images => 1 } ],
        format          => [ { raw => 1 }, 'raw' ],
        'sensitive-properties' => { 'chap_password' => 1, 'ssh_privkey' => 1, 'api_key' => 1 },
        select_existing => 1,
    };
}

# Extra properties this plugin understands (types & validations)
sub properties {
    return {
        truenas_host  => {
            description => "TrueNAS hostname or IP",
            type        => 'string',
            format      => 'pve-storage-server',
        },
        truenas_user  => {
            description => "SSH user for midclt (usually 'root' on SCALE unless you prefer a service user)",
            type        => 'string',
        },
        ssh_privkey   => {
            description => "Path to private key for SSH auth to TrueNAS",
            type        => 'string',
            optional    => 1,
        },
        api_key       => {
            description => "TrueNAS API key (optional). If set, plugin can use HTTPS+WebSocket client instead of SSH midclt.",
            type        => 'string',
            optional    => 1,
        },
        dataset       => {
            description => "ZFS dataset on TrueNAS where zvols are created, e.g. tank/proxmox",
            type        => 'string',
        },
        target_iqn    => {
            description => "Shared iSCSI Target IQN on TrueNAS",
            type        => 'string',
        },
        discovery_portal => {
            description => "Primary portal for SendTargets discovery (IP/DNS, v4 or v6).",
            type        => 'string',
        },
        portals       => {
            description => "Comma-separated additional portals (IP/DNS, IPv6 allowed in bracket form). If empty, auto-discovery is used.",
            type        => 'string',
            optional    => 1,
        },
        use_multipath => {
            description => "Enable multipath for block devices.",
            type        => 'boolean',
            optional    => 1,
            default     => 1,
        },
        use_by_path   => {
            description => "Prefer /dev/disk/by-path (IPv6-safe) over /dev/mapper multipath alias.",
            type        => 'boolean',
            optional    => 1,
            default     => 0,
        },
        ipv6_by_path  => {
            description => "Normalize IPv6 addresses for by-path lookup.",
            type        => 'boolean',
            optional    => 1,
            default     => 1,
        },
        chap_user     => { type => 'string', optional => 1 },
        chap_password => { type => 'string', optional => 1 },
        zvol_blocksize => {
            description => "ZVOL volblocksize, e.g. 16K, 64K. If unset, TrueNAS default is used.",
            type        => 'string',
            optional    => 1,
        },
    };
}

# Which of those properties are valid in storage.cfg (and whether fixed/optional)
sub options {
    return {
        # common storage flags
        disable => { optional => 1 },
        nodes   => { optional => 1 },
        content => { optional => 1 },
        shared  => { optional => 1 },  # must be set in storage.cfg for custom plugins

        # plugin-specific (fixed to prevent changes that would orphan LUNs)
        truenas_host     => { fixed => 1 },
        truenas_user     => { fixed => 1 },
        ssh_privkey      => { optional => 1, fixed => 1 },
        api_key          => { optional => 1, fixed => 1 },

        dataset          => { fixed => 1 },
        target_iqn       => { fixed => 1 },
        discovery_portal => { fixed => 1 },
        portals          => { optional => 1 },

        use_multipath    => { optional => 1 },
        use_by_path      => { optional => 1 },
        ipv6_by_path     => { optional => 1 },

        chap_user        => { optional => 1 },
        chap_password    => { optional => 1 },

        zvol_blocksize   => { optional => 1, fixed => 1 },
        bwlimit          => { optional => 1 },
    };
}

# ======== Helpers ========

# Run midclt via SSH on TrueNAS (simple/robust for SCALE). Requires ssh key or agent.
# Example: _midclt($scfg, 'zfs.dataset.create', {name=>'tank/pve/vm-100-disk-0', type=>'VOLUME', volsize=>10737418240})
sub _midclt($scfg, $method, $payload) {
    my $host = $scfg->{truenas_host};
    my $user = $scfg->{truenas_user} || 'root';

    my @ssh = ('/usr/bin/ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new');
    push @ssh, ('-i', $scfg->{ssh_privkey}) if $scfg->{ssh_privkey};
    push @ssh, "$user\@$host", 'midclt', 'call', $method, encode_json($payload);

    my $out = '';
    run_command(\@ssh, errmsg => "midclt call failed", outfunc => sub { $out .= "$_[0]\n" });
    return $out;
}

# Call TrueNAS to find/allocate next free LUN ID on a target (simple strategy).
sub _next_free_lun($scfg) {
    # query all Target-Extent associations, then pick a free LUN id
    my $target_iqn = $scfg->{target_iqn};
    my $json = _midclt($scfg, 'iscsi.targetextent.query', []);
    # naive parse: pick LUNs for our target and find the first free in [0..4095]
    my @used;
    for my $line (split(/\n/, $json)) {
        # Expect JSON lines; keep it simple by extracting "lunid" and "target" fields
        if ($line =~ /\"target\":\s*\"?\Q$target_iqn\E\"?.*\"lunid\":\s*(\d+)/) {
            push @used, int($1);
        } elsif ($line =~ /\"lunid\":\s*(\d+)/ && $json =~ /\Q$target_iqn\E/) {
            # best effort when API output is compact
            push @used, int($1);
        }
    }
    my %used = map { $_ => 1 } @used;
    for my $lun (0..4095) {
        return $lun if !$used{$lun};
    }
    die "No free LUN IDs available on target $target_iqn\n";
}

# Normalize portal strings (IPv4/IPv6 + optional :port).
sub _normalize_portal($p) {
    $p =~ s/^\s+|\s+$//g;
    return $p if !$p;
    # strip brackets for sysfs/by-path, but keep port
    if ($p =~ /^\[(.+)\]:(\d+)$/) { return "$1:$2"; }
    return $p;
}

# Discover portals and login (persistent), optionally configure CHAP.
sub _iscsi_login_all($scfg) {
    my $primary = $scfg->{discovery_portal};
    my @extra = ();
    if ($scfg->{portals}) {
        @extra = map { _normalize_portal($_) } split(/\s*,\s*/, $scfg->{portals});
    }

    my @discover_cmd = ('iscsiadm', '-m', 'discovery', '-t', 'sendtargets', '-p', $primary);
    run_command(\@discover_cmd, errmsg => "iSCSI discovery failed", outfunc => sub {});

    # The sendtargets record should be created; now enumerate known nodes for our target
    my $iqn = $scfg->{target_iqn};
    my @nodes_cmd = ('iscsiadm', '-m', 'node', '-T', $iqn);
    my @nodes;
    run_command(\@nodes_cmd, errmsg => "iscsiadm list nodes failed", outfunc => sub {
        push @nodes, $_[0] if $_[0] =~ /\S/;
    });

    # Ensure node DB has startup=automatic, CHAP (optional), and then login
    for my $node_line (@nodes) {
        # expected: "<ip>:<port>,<tpgt> <iqn>"
        if ($node_line =~ /^(\S+)\s+$iqn$/) {
            my $portal = $1;
            my @upd = ('iscsiadm', '-m', 'node', '-T', $iqn, '-p', $portal, '-o', 'update', '-n', 'node.startup', '-v', 'automatic');
            run_command(\@upd, errmsg => "iscsiadm update node.startup failed", outfunc => sub {});
            if ($scfg->{chap_user} && $scfg->{chap_password}) {
                my @auth = (
                    ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.authmethod','-v','CHAP'],
                    ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.username','-v',$scfg->{chap_user}],
                    ['iscsiadm','-m','node','-T',$iqn,'-p',$portal,'-o','update','-n','node.session.auth.password','-v',$scfg->{chap_password}],
                );
                for my $cmd (@auth) { run_command($cmd, errmsg => "iscsiadm CHAP update failed", outfunc => sub {}); }
            }
            my @login = ('iscsiadm','-m','node','-T',$iqn,'-p',$portal,'--login');
            run_command(\@login, errmsg => "iscsiadm login failed", outfunc => sub {});
        }
    }

    # Also try extra portals (IPv4/IPv6); discovery then login
    for my $p (@extra) {
        run_command(['iscsiadm','-m','discovery','-t','sendtargets','-p',$p], errmsg => "iSCSI discovery failed", outfunc => sub {});
        run_command(['iscsiadm','-m','node','-T',$iqn,'-p',$p,'--login'], errmsg => "iSCSI login failed", outfunc => sub {});
    }
}

# Find the device node for a given LUN.
# - If multipath enabled, prefer /dev/mapper/dm-uuid-mpath-*
# - Else, /dev/disk/by-path/ip-<addr>:<port>-iscsi-<iqn>-lun-<lun>
sub _device_for_lun($scfg, $lun) {
    my $iqn = $scfg->{target_iqn};
    my $prefer_by_path = $scfg->{use_by_path};

    # settle devices
    run_command(['udevadm','settle'], outfunc => sub {});

    if ($scfg->{use_multipath} && !$prefer_by_path) {
        # Grep WWIDs for luns, then map to dm-uuid
        my $mp = '';
        run_command(['multipath','-ll'], outfunc => sub {
            my $line = $_[0];
            if ($line =~ /^\s*size=/) { return; }
            # very rough: pick the first map referencing our IQN
            if ($line =~ /(dm-\d+)/ && $line =~ /$iqn/) { $mp = "/dev/$1"; }
        });
        return $mp if $mp;
    }

    # by-path; scan all symlinks for our iqn+lun
    my $pattern = "-iscsi-$iqn-lun-$lun";
    my @paths;
    opendir(my $dh, "/dev/disk/by-path") or die "cannot open /dev/disk/by-path\n";
    while (my $e = readdir($dh)) {
        next unless $e =~ /^ip-.*\Q$pattern\E$/; # handles IPv6 ip-... variants too
        push @paths, "/dev/disk/by-path/$e";
    }
    closedir($dh);

    die "Could not locate by-path device for LUN $lun (IQN $iqn)\n" if !@paths;
    # If multipath enabled but we still prefer by-path, return the first by-path
    return $paths[0];
}

# Build a "safe" zvol name for new allocations
sub _zvol_name($vmid, $name) {
    $name //= 'disk-0';
    $name =~ s/[^a-zA-Z0-9\-_\.]+/_/g;
    return "vm-$vmid-$name";
}

# ======== Storage implementation ========

# Parse our volume names: "vol-<zname>-lun<id>"
sub parse_volname {
    my ($class, $volname) = @_;
    if ($volname =~ m!^vol-([a-zA-Z0-9._\-]+)-lun(\d+)$!) {
        my ($zname, $lun) = ($1, int($2));
        # vtype, name, vmid, basename, basevmid, isBase, format
        return ('images', $zname, undef, undef, undef, undef, 'raw', $lun);
    }
    die "unable to parse truenas volume name '$volname'\n";
}

# The device path returned here is used by QEMU to attach the disk
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    die "snapshots not supported on raw iSCSI LUNs via this plugin" if defined $snapname;

    my ($vtype, $zname, undef, undef, undef, undef, undef, $lun) = $class->parse_volname($volname);

    _iscsi_login_all($scfg);
    my $dev = _device_for_lun($scfg, $lun);

    return ($dev, undef, $vtype);
}

# Create a zvol + extent and map it to the shared target with the next free LUN
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    die "only raw is supported" if defined($fmt) && $fmt ne 'raw';

    my $zname = _zvol_name($vmid, $name);
    my $full  = $scfg->{dataset} . '/' . $zname;

    # Create zvol on TrueNAS
    my $payload = { name => $full, type => 'VOLUME', volsize => int($size) };
    $payload->{volblocksize} = $scfg->{zvol_blocksize} if $scfg->{zvol_blocksize};
    _midclt($scfg, 'zfs.dataset.create', $payload);

    # Create extent and associate with target
    my $lun = _next_free_lun($scfg);

    # extent create (device-backed zvol path on TrueNAS)
    my $extent = {
        name   => $zname,
        type   => 'DISK',
        disk   => "zvol/$full",
        insecure_tpc => JSON::PP::true,
    };
    _midclt($scfg, 'iscsi.extent.create', $extent);

    # attach extent to target with computed LUN
    my $associate = {
        target => $scfg->{target_iqn},
        extent => $zname,
        lunid  => $lun,
    };
    _midclt($scfg, 'iscsi.targetextent.create', $associate);

    # Return canonical volname for PVE
    return "vol-$zname-lun$lun";
}

# Remove extent mapping + extent + zvol
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    my (undef, $zname, undef, undef, undef, undef, undef, $lun) = $class->parse_volname($volname);
    my $full  = $scfg->{dataset} . '/' . $zname;

    # delete targetextent association by target+extent (idempotent cleanup)
    _midclt($scfg, 'iscsi.targetextent.delete', { target => $scfg->{target_iqn}, extent => $zname, lunid => $lun });

    # delete extent
    _midclt($scfg, 'iscsi.extent.delete', { name => $zname });

    # delete zvol
    _midclt($scfg, 'zfs.dataset.delete', { name => $full, recursive => JSON::PP::true });
    return 1;
}

# We don't manage quotas/space; report active=1 so PVE won’t gray it out
sub status { my ($class, $storeid, $scfg, $cache) = @_; return (0,0,0,1); }

# Activate storage (noop; discovery happens in path()/activate_volume())
sub activate_storage { return 1; }
sub deactivate_storage { return 1; }

# Make sure sessions exist before VM starts
sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    die "snapshots not supported" if $snapname;
    _iscsi_login_all($scfg);
    if ($scfg->{use_multipath}) {
        run_command(['multipath','-r'], outfunc => sub {});
    }
    run_command(['udevadm','settle'], outfunc => sub {});
    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    # keep sessions persistent (node.startup=automatic), do nothing here
    return 1;
}

# No snapshots/clones on raw LUNs (TrueNAS snapshots could be added later)
sub volume_snapshot           { die "snapshot not supported"; }
sub volume_snapshot_delete    { die "snapshot not supported"; }
sub volume_snapshot_rollback  { die "snapshot not supported"; }
sub clone_image               { die "clone not supported"; }
sub create_base               { die "base images not supported"; }
sub volume_resize             { die "resize not supported"; }

# feature matrix
sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;
    return undef; # minimal set; can be expanded
}

1;
