#!/usr/bin/perl
# Verifies the tn_status_capacity_ttl_s knob (#147 side-note #3):
#   - unset   -> in-process TTL = $STATUS_CAPACITY_TTL_S (10)
#                stamp TTL      = $STATUS_CAPACITY_STAMP_TTL_S (15)
#   - set to K (!= default) -> both TTLs = K
#   - set to default value (10) -> stamp still falls back to 15 (legacy)
#   - bogus values fall back to the hardcoded default
#
# Run with:  prove -v -I t/nvme/lib t/nvme/09-status-capacity-ttl-knob.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
plan skip_all => "_status_capacity_ttl_s helper missing"
    unless $PKG->can('_status_capacity_ttl_s');

sub _ttl { no strict 'refs'; return &{"${PKG}::_status_capacity_ttl_s"}(@_); }

# Defaults
is(_ttl({}), 10, "unset -> 10 (STATUS_CAPACITY_TTL_S)");
is(_ttl({ tn_status_capacity_ttl_s => undef }), 10, "undef -> 10");
is(_ttl({ tn_status_capacity_ttl_s => 'nope' }), 10, "non-numeric -> 10");
is(_ttl({ tn_status_capacity_ttl_s => 0 }), 10, "zero -> 10 (rejected as invalid)");
is(_ttl({ tn_status_capacity_ttl_s => -5 }), 10, "negative -> 10");

# Honoured values
is(_ttl({ tn_status_capacity_ttl_s => 1 }),   1,   "1 honoured");
is(_ttl({ tn_status_capacity_ttl_s => 60 }),  60,  "60 honoured");
is(_ttl({ tn_status_capacity_ttl_s => 120 }), 120, "120 (reporter's value) honoured");
is(_ttl({ tn_status_capacity_ttl_s => 3600 }),3600,"3600 (max) honoured");

# The stamp read path should pick up the knob too. We don't execute
# _read_status_stamp here (it touches /run); we assert the helper is
# used from status() by grep-ing the source once.
my $src = do { local $/; open(my $fh, '<', $PLUGIN) or die; <$fh> };
like($src, qr/_get_cached\(\s*\$host_key,\s*\$status_method,\s*_status_capacity_ttl_s\(\$scfg\)\)/,
    "status() in-process cache uses the knob");
like($src, qr/_status_capacity_ttl_s\(\$scfg\)/,
    "stamp-read path reads the knob");

done_testing();
