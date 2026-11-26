use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../..";

# Sensitive properties live in /etc/pve/priv/storage/<id>.truenas instead of
# storage.cfg, because the storage config API returns sections unfiltered.
# PVE is not installed on dev hosts: stub the modules the code under test
# touches, with an in-memory storage.cfg.
our ($CFG, $WRITES);
BEGIN {
    package PVE::Tools;
    use Exporter 'import';
    our @EXPORT_OK = qw(run_command trim);
    sub run_command { die "stub" }
    sub trim { my $s = shift; $s =~ s/^\s+|\s+$//g; $s }
    sub file_get_contents {
        my ($f) = @_;
        open(my $fh, '<', $f) or die "open $f: $!\n";
        local $/; return scalar <$fh>;
    }
    sub file_set_contents {
        my ($f, $data, $perm) = @_;
        open(my $fh, '>', $f) or die "open $f: $!\n";
        print $fh $data; close $fh;
        chmod($perm, $f) if defined $perm;
    }
    package PVE::JSONSchema;
    use Exporter 'import';
    our @EXPORT_OK = qw(get_standard_option);
    sub get_standard_option { return {} }
    package PVE::Storage::Plugin;
    sub check_config { my ($class, $id, $config) = @_; return { %$config } }
    package PVE::Storage;
    sub config { return $main::CFG }
    sub lock_storage_config { my ($code) = @_; $code->() }
    sub write_config { $main::WRITES++; $main::CFG->{digest} = 'd' . $main::WRITES }
    $INC{'PVE/Tools.pm'} = $INC{'PVE/JSONSchema.pm'} = $INC{'PVE/Storage/Plugin.pm'} = 1;
    $INC{'PVE/Storage.pm'} = 1;
}

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $plugin = 'PVE::Storage::Custom::TrueNASPlugin';
my $dir = tempdir(CLEANUP => 1);
{ no warnings 'once'; $PVE::Storage::Custom::TrueNASPlugin::SECRET_DIR = "$dir/storage"; }

sub section { return { type => 'truenasplugin', tn_api_host => 'nas', tn_dataset => 'tank/pve', @_ } }
sub secrets_of {
    my $f = "$dir/storage/$_[0].truenas";
    return -e $f ? JSON::PP::decode_json(PVE::Tools::file_get_contents($f)) : undef;
}
sub secret { PVE::Storage::Custom::TrueNASPlugin::_tn_secret(@_) }

subtest 'schema metadata for the 9.3 storage dialog' => sub {
    my $data = $plugin->plugindata;
    is $data->{meta}{'display-name'}, 'TrueNAS';
    is_deeply [sort keys $data->{'sensitive-properties'}->%*],
        [sort @PVE::Storage::Custom::TrueNASPlugin::_SENSITIVE_KEYS],
        'sensitive-properties matches the keys the hooks handle';
    my $opts = $plugin->options;
    ok $opts->{$_}{optional}, "$_ optional" for keys $data->{'sensitive-properties'}->%*;
    ok !$opts->{tn_api_key}{fixed}, 'tn_api_key can be rotated';
    my $props = $plugin->properties;
    for my $k (sort keys %$props) {
        next if !exists $props->{$k}{default} || $props->{$k}{type} ne 'boolean';
        like $props->{$k}{default}, qr/\A[01]\z/, "$k boolean default is 0/1";
    }
    for my $g (qw(advanced hidden sensitive)) {
        ok exists $props->{$_}, "$g property $_ exists" for keys $data->{"$g-properties"}->%*;
    }
};

subtest 'add writes the sidecar, not storage.cfg' => sub {
    my $scfg = section();
    $CFG = { ids => { tn1 => $scfg }, digest => 'a' };
    eval { $plugin->on_add_hook('tn1', $scfg) };
    like $@, qr/tn_api_key is required/, 'add without key refused';

    $plugin->on_add_hook('tn1', $scfg, tn_api_key => '1-abc', tn_chap_password => 'c h=p');
    is_deeply secrets_of('tn1'), { tn_api_key => '1-abc', tn_chap_password => 'c h=p' };
    ok !exists $scfg->{tn_api_key}, 'key not in section';
    is sprintf('%o', (stat("$dir/storage/tn1.truenas"))[2] & 07777), '600', 'file mode 0600';
    is secret($scfg, 'tn_api_key'), '1-abc', 'reader resolves storeid from the section';
    is secret({ %$scfg }, 'tn_chap_password'), 'c h=p', 'and from a copy of it';
    is secret({ %$scfg, storeid => 'tn1' }, 'tn_api_key'), '1-abc', 'explicit storeid';
};

subtest 'legacy inline secrets keep working, sidecar wins' => sub {
    my $legacy = section(tn_dataset => 'tank/old', tn_api_key => 'inline-key');
    $CFG = { ids => { old => $legacy }, digest => 'b' };
    is secret($legacy, 'tn_api_key'), 'inline-key', 'inline fallback';

    # Rotating the key moves it out of the section.
    $plugin->on_update_hook_full('old', $legacy, {}, undef, { tn_api_key => 'new-key' });
    is secrets_of('old')->{tn_api_key}, 'new-key';
    ok !exists $legacy->{tn_api_key}, 'stale inline copy dropped';
    $CFG->{digest} = 'b2';
    is secret($legacy, 'tn_api_key'), 'new-key';
};

subtest 'update semantics' => sub {
    my $scfg = section(tn_dataset => 'tank/u');
    $CFG = { ids => { u => $scfg }, digest => 'c' };
    $plugin->on_add_hook('u', $scfg, tn_api_key => 'k1', tn_nvme_dhchap_secret => 'DHHC-1:01:x:');

    $plugin->on_update_hook_full('u', $scfg, {}, undef, {});
    is_deeply secrets_of('u'), { tn_api_key => 'k1', tn_nvme_dhchap_secret => 'DHHC-1:01:x:' },
        'nothing sensitive submitted: unchanged';

    $plugin->on_update_hook_full('u', $scfg, {}, ['tn_nvme_dhchap_secret'],
        { tn_nvme_dhchap_secret => undef });
    is_deeply secrets_of('u'), { tn_api_key => 'k1' }, 'deleted secret removed';

    eval { $plugin->on_update_hook_full('u', $scfg, {}, ['tn_api_key'], { tn_api_key => undef }) };
    like $@, qr/cannot be removed/, 'API key cannot be deleted';
    is secrets_of('u')->{tn_api_key}, 'k1';

    $plugin->on_update_hook('u', {}, tn_api_key => 'k2');
    is secrets_of('u')->{tn_api_key}, 'k2', 'pre-13 hook path';

    $plugin->on_delete_hook('u', $scfg);
    ok !-e "$dir/storage/u.truenas", 'delete removes sidecar';
};

subtest 'ambiguous sections fall back to inline' => sub {
    my %same = (tn_dataset => 'tank/dup');
    $CFG = { ids => { a => section(%same), b => section(%same) }, digest => 'e' };
    $plugin->on_add_hook('a', section(%same), tn_api_key => 'ka');
    is secret(section(%same, tn_api_key => 'inl'), 'tn_api_key'), 'inl';
    is secret(section(%same, storeid => 'a'), 'tn_api_key'), 'ka';
};

subtest 'migrate-secrets' => sub {
    $WRITES = 0;
    my $m = section(tn_dataset => 'tank/m', tn_api_key => 'mk', tn_chap_password => 'mp');
    my $other = { type => 'dir', path => '/x' };
    $CFG = { ids => { m => $m, d => $other }, digest => 'f' };
    open(my $out, '>', \my $buf); my $old = select $out;
    my $rc = $plugin->can('migrate_secrets_cli')->();
    select $old;
    is $rc, 0;
    is_deeply secrets_of('m'), { tn_api_key => 'mk', tn_chap_password => 'mp' };
    ok !exists $m->{tn_api_key} && !exists $m->{tn_chap_password}, 'removed from storage.cfg';
    is $WRITES, 1, 'storage.cfg written once';
    like $buf, qr/m: tn_api_key, tn_chap_password/;
    is secret($m, 'tn_api_key'), 'mk';

    $WRITES = 0;
    $plugin->can('migrate_secrets_cli')->();
    is $WRITES, 0, 'second run is a no-op';
};

done_testing;
