package PVE::Storage::Plugin;

# Minimal stand-in for PVE::Storage::Plugin (see PVE::Tools stub in this same
# directory for why). TrueNASPlugin.pm declares `use base qw(PVE::Storage::
# Plugin)`, so this only needs to be a loadable package with the handful of
# methods the plugin calls via SUPER:: or inherits and the tests touch.
# cluster_lock_storage() runs the wrapped operation immediately, with no
# actual cluster file-system lock - correct for these tests, which never run
# two "nodes" concurrently.

use strict;
use warnings;

sub api { return 11; }

sub cluster_lock_storage {
    my ($class, $storeid, $shared, $timeout, $func, @param) = @_;
    return $func->(@param);
}

sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

1;
