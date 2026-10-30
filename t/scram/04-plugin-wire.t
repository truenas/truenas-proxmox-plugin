use strict;
use warnings;
use Test::More;
use JSON::PP ();
use IO::Socket::UNIX;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use FindBin;
use lib "$FindBin::Bin/../..";

# PVE is not installed on dev hosts. Stub just enough of the PVE modules for
# TrueNASPlugin.pm to compile; the code under test (properties, check_config,
# _broker_rpc) does not depend on any real PVE behaviour.
BEGIN {
    package PVE::Tools;
    use Exporter 'import';
    our @EXPORT_OK = qw(run_command trim);
    sub run_command { die "stub" }
    sub trim { my $s = shift; $s =~ s/^\s+|\s+$//g; $s }
    package PVE::JSONSchema;
    use Exporter 'import';
    our @EXPORT_OK = qw(get_standard_option);
    sub get_standard_option { return {} }
    package PVE::Storage::Plugin;
    sub check_config { my ($class, $id, $config) = @_; return { %$config } }
    $INC{'PVE/Tools.pm'} = $INC{'PVE/JSONSchema.pm'} = $INC{'PVE/Storage/Plugin.pm'} = 1;
}

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $plugin = 'PVE::Storage::Custom::TrueNASPlugin';

subtest 'schema accepts new fields' => sub {
    my $props = $plugin->properties;
    ok exists $props->{tn_api_username}, 'tn_api_username present';
    ok exists $props->{tn_auth_mechanism}, 'tn_auth_mechanism present';
    is_deeply $props->{tn_auth_mechanism}{enum}, ['auto','scram','scram-plus','plain'];
    is $props->{tn_auth_mechanism}{default}, 'auto';
    like $props->{tn_api_username}{description}, qr/legacy auth\.login_with_api_key/;
};

subtest 'scram-plus enum + check_config' => sub {
    # Create-time: scram-plus without username is refused
    eval {
        $plugin->check_config('s1', {
            type=>'truenasplugin', tn_api_host=>'h', tn_api_key=>'k',
            tn_auth_mechanism=>'scram-plus',
        }, 1, 0);
    };
    like $@, qr/tn_auth_mechanism=scram-plus requires tn_api_username/;

    # Create-time: scram-plus WITH username is accepted (iSCSI create also
    # needs dataset + target IQN + discovery portal).
    my %full = (
        type=>'truenasplugin', tn_api_host=>'h', tn_api_key=>'k',
        tn_api_username=>'root', tn_auth_mechanism=>'scram-plus',
        tn_dataset=>'tank/pve', tn_target_iqn=>'iqn.2005-10.org.example:t',
        tn_discovery_portal=>'192.0.2.1',
    );
    my $ok = eval { $plugin->check_config('s1', { %full }, 1, 0); 1 };
    ok $ok, "scram-plus + username passes check_config"
        or diag $@;

    # tn_api_insecure=1 + scram-plus is allowed (spec Goal 7)
    my $ok2 = eval {
        $plugin->check_config('s1', { %full, tn_api_insecure=>1 }, 1, 0);
        1;
    };
    ok $ok2, "scram-plus + tn_api_insecure=1 passes check_config";

    # Edit delta: mechanism alone must not trip the create-only requirement.
    eval { $plugin->check_config('s1', { tn_auth_mechanism=>'scram-plus' }, 0, 0) };
    unlike $@ // '', qr/requires tn_api_username/, 'scram-plus edit delta not refused';
};

subtest 'options() allows new fields and leaves them unfixed' => sub {
    my $o = $plugin->options;
    ok exists $o->{tn_api_username}, 'tn_api_username in options';
    ok exists $o->{tn_auth_mechanism}, 'tn_auth_mechanism in options';
    ok !$o->{tn_api_username}{fixed}, 'username not fixed';
    ok !$o->{tn_auth_mechanism}{fixed}, 'mechanism not fixed';
};

subtest 'check_config refuses invalid combos' => sub {
    eval {
        $plugin->check_config('s1', {
            type=>'truenasplugin', tn_api_host=>'h', tn_api_key=>'k',
            tn_auth_mechanism=>'scram',
        }, 1, 0);
    };
    like $@, qr/tn_auth_mechanism=scram requires tn_api_username/;

    eval {
        $plugin->check_config('s1', {
            type=>'truenasplugin', tn_api_host=>'h', tn_api_key=>'k',
            tn_api_username=>'alice:bad',
        }, 1, 0);
    };
    like $@, qr/tn_api_username must not contain ':'/;

    # Edit delta: mechanism alone must not trip the create-only requirement.
    eval {
        $plugin->check_config('s1', { tn_auth_mechanism=>'scram' }, 0, 0);
    };
    unlike $@ // '', qr/requires tn_api_username/, 'edit delta not refused';

    # Colon is refused on edit too.
    eval { $plugin->check_config('s1', { tn_api_username=>'a:b' }, 0, 0) };
    like $@, qr/must not contain ':'/;
};

subtest '_broker_rpc envelope carries new fields' => sub {
    socketpair(my $client, my $server, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";
    $client->autoflush(1); $server->autoflush(1);
    # Pre-load the broker's reply so _broker_rpc completes.
    syswrite($server, JSON::PP::encode_json({ result => 'pong' }) . "\n");

    my $res = PVE::Storage::Custom::TrueNASPlugin::_broker_rpc(
        { sock => $client,
          scfg => { tn_api_host=>'h', tn_api_key=>'17-abc',
                    tn_api_username=>'alice', tn_auth_mechanism=>'scram' } },
        { method => 'core.ping', params => [] },
    );
    is $res, 'pong';

    sysread($server, my $buf, 65536);
    my $json = JSON::PP::decode_json((split /\n/, $buf)[0]);
    is $json->{scfg}{api_username},   'alice';
    is $json->{scfg}{auth_mechanism}, 'scram';
    is $json->{scfg}{api_key},        '17-abc', 'existing keys unchanged';
    ok !exists $json->{scfg}{tn_api_username}, 'no tn_ prefix on wire';
};

done_testing;
