use strict;
use warnings;
use Test::More;
require "./tools/truenas-plugin-broker";

my $k1 = main::scfg_key({ api_host=>"h", api_key=>"17-abc" });
my $k2 = main::scfg_key({ api_host=>"h", api_key=>"17-abc", api_username=>"alice" });
my $k3 = main::scfg_key({ api_host=>"h", api_key=>"17-abc", api_username=>"alice", auth_mechanism=>"scram" });
my $k4 = main::scfg_key({ api_host=>"h", api_key=>"17-abc", api_username=>"alice", auth_mechanism=>"auto" });

isnt $k1, $k2, "unset vs set username -> distinct";
isnt $k2, $k3, "auto vs scram -> distinct";
is   $k2, $k4, "missing auth_mechanism defaults to auto";

my $k_plus = main::scfg_key({ api_host=>"h", api_key=>"17-abc", api_username=>"alice", auth_mechanism=>"scram-plus" });
isnt $k3, $k_plus, "scram vs scram-plus -> distinct pool keys";

done_testing;
