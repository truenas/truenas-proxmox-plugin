#!/usr/bin/perl -T
# Run with:  perl -T -I t/nvme/lib t/nvme/15-nsid-multinode.t   (PVE daemons run under -T)
#
# Multi-node cases for the wrap-around nsid cursor (#149): a node's cursor
# lags behind nsids allocated by other nodes, and a concurrent insert of the
# same nsid fails on TN's unique index instead of its validator.
use strict; use warnings; use Test::More; use FindBin; use File::Temp qw(tempdir);
my ($PLUGIN) = ("$FindBin::Bin/../../TrueNASPlugin.pm" =~ /^(.*)$/);
require $PLUGIN;
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $dir = tempdir(CLEANUP => 1);
my %db;              # nsid => device_path
my @creates;
my @fail_next;       # error messages for the next create calls, in order
{
    no strict 'refs'; no warnings 'redefine';
    ${"${PKG}::TN_NSID_CURSOR_DIR"} = $dir;
    *{"${PKG}::_log"} = sub {};
    *{"${PKG}::_nvme_get_subsystem_device_paths"} = sub { () };
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
            if (@fail_next) {
                my $msg = shift @fail_next;
                $msg =~ s/\{N\}/$p->{nsid}/g;
                die "$msg\n";
            }
            die "nsid $p->{nsid} already in use\n" if exists $db{$p->{nsid}};
            $db{$p->{nsid}} = $p->{device_path};
            return { nsid => $p->{nsid}, device_uuid => "u$p->{nsid}" };
        }
        die "unexpected $m";
    };
}
my $create = $PKG->can('_nvme_create_namespace_idempotent');
my $mk = sub { $create->({}, { subsys_id => 7, device_type => 'ZVOL', device_path => $_[0], enabled => 1 }) };
my $set_cursor = sub {
    open(my $fh, '>', "$dir/nsid-cursor-7") or die "cursor: $!";
    print $fh "$_[0]\n";
    close $fh;
};
my $reset = sub { %db = (); @creates = (); @fail_next = (); unlink "$dir/nsid-cursor-7"; };

subtest 'lagging cursor does not reuse an nsid freed below max_used' => sub {
    $reset->();
    $db{$_} = "other$_" for (1 .. 300);   # another node allocated up to 300
    delete $db{55};                       # ... and nsid 55 was just freed
    $set_cursor->(50);                    # this node last picked 50
    my $ns = $mk->('/dev/zvol/lag');
    is($ns->{nsid}, 301, 'picks max_used + 1, not the freed 55');
    is($db{55}, undef, 'nsid 55 stays free');
};

subtest 'cursor ahead of max_used is kept' => sub {
    $reset->();
    $db{$_} = "y$_" for (1 .. 300);
    $set_cursor->(400);
    is($mk->('/dev/zvol/ahead')->{nsid}, 401, 'continues after the cursor');
};

subtest 'at the ceiling the clamp does nothing: scan continues from the cursor' => sub {
    $reset->();
    $db{$_} = "z$_" for (1 .. 1023);
    delete $db{$_} for (55, 60);
    $set_cursor->(50);
    is($mk->('/dev/zvol/wrap')->{nsid}, 55, 'max_used at TN_NSID_MAX: scan from the cursor');
};

subtest 'unique-index collision retries with another nsid' => sub {
    $reset->();
    $db{$_} = "y$_" for (1 .. 20);
    $set_cursor->(20);
    @fail_next = ('[EFAULT] UNIQUE constraint failed: services_nvmet_namespace.nvmet_namespace_subsys_id, '
        . 'services_nvmet_namespace.nvmet_namespace_nsid');
    my $ns = eval { $mk->('/dev/zvol/uniq') };
    is($@, '', 'create does not die');
    is_deeply(\@creates, [21, 22], 'first try 21, retry 22');
    is($ns && $ns->{nsid}, 22, 'namespace created on the retry');
};

subtest 'validator wording with NSID after "already exists" retries' => sub {
    $reset->();
    $db{$_} = "y$_" for (1 .. 20);
    $set_cursor->(20);
    @fail_next = ('[EINVAL] This record already exists (Subsystem ID: 7/NSID: {N})');
    my $ns = eval { $mk->('/dev/zvol/valid') };
    is($@, '', 'create does not die');
    is_deeply(\@creates, [21, 22], 'first try 21, retry 22');
};

subtest 'unrelated create errors are not retried' => sub {
    $reset->();
    $db{$_} = "y$_" for (1 .. 20);
    $set_cursor->(20);
    @fail_next = ('[EINVAL] nvmet_namespace_create.device_path: zvol does not exist');
    eval { $mk->('/dev/zvol/other') };
    like($@, qr/zvol does not exist/, 'original error surfaces');
    is_deeply(\@creates, [21], 'single attempt');
};

done_testing;
