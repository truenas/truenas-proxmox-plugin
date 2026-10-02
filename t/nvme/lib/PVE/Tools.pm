package PVE::Tools;

# Minimal stand-in for the real PVE::Tools module, which ships only as part
# of a Proxmox VE host install (libpve-storage-perl) and is not available on
# a plain Perl toolchain. TrueNASPlugin.pm only needs these two symbols to
# resolve at compile time (`use PVE::Tools qw(run_command trim)`); nothing in
# t/nvme exercises run_command, since every test replaces the plugin's own
# API/CLI call points with mocks before it runs.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(run_command trim);

sub run_command {
    die "PVE::Tools::run_command is a compile-time stub; no test should call it\n";
}

sub trim {
    my ($s) = @_;
    return undef if !defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

1;
