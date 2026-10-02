# t/nvme

Unit tests for the API-loss resilience series (wall-clock retry budget,
recent-failure marker, ensure-failure classification, throttled notes).

These tests load `TrueNASPlugin.pm` directly and stub out its API/CLI call
points (`_api_call`, `_api_call_mutate`, `_nvme_connect`, `_nvme_check_cli`,
`_nvme_ensure_subsystem`, `_log`) before calling the plugin's own subs, so
they need no TrueNAS array and no Proxmox host to run.

They do need `PVE::Tools`, `PVE::JSONSchema`, and `PVE::Storage::Plugin` to
be resolvable at compile time (`TrueNASPlugin.pm` is a
`PVE::Storage::Plugin` subclass). Those ship only as part of a Proxmox VE
host install (`libpve-storage-perl`), which most development machines and
CI runners do not have. `t/nvme/lib/PVE/` provides minimal stand-ins - just
enough for the module to compile and for these tests to call its plugin
subs directly; see the comment at the top of each stub for exactly what it
does and does not cover.

Run the whole directory:

    prove -v -I t/nvme/lib t/nvme/*.t

On a real Proxmox host, `libpve-storage-perl` already provides the real
`PVE::Tools`, `PVE::JSONSchema`, and `PVE::Storage::Plugin` on the default
`@INC`; drop `-I t/nvme/lib` there to exercise the tests against the real
modules instead of these stand-ins.
