# TrueNAS API Call Inventory

Enumeration of every TrueNAS middlewared method the plugin or its
tooling invokes. Regenerate whenever code changes touch the API
surface. Compare against TrueNAS release notes and
`core.get_methods` output to catch API changes that will break the
driver.

Generated from alpha branch, plugin version 2.1.21~alpha2+.
See "Regeneration" at the bottom for the exact scan procedure.

---

## Plugin-core methods (production runtime, 39)

These are called by `TrueNASPlugin.pm` and the
`truenas-plugin-broker` daemon. Any breaking change here breaks
production deployments.

### Authentication (1)

- `auth.login_with_api_key`

### Core / infrastructure (4)

- `core.bulk`
- `core.call`
- `core.get_jobs`
- `core.ping`

### Pool + dataset + snapshot (13)

- `pool.query`
- `pool.dataset.create`
- `pool.dataset.query`
- `pool.dataset.get_instance`
- `pool.dataset.update`
- `pool.dataset.rename`
- `pool.dataset.delete`
- `pool.snapshot.create`
- `pool.snapshot.query`
- `pool.snapshot.clone`
- `pool.snapshot.rollback`
- `pool.snapshot.delete`
- `system.version`

### iSCSI (9)

- `iscsi.global.config`
- `iscsi.target.query`
- `iscsi.extent.create`
- `iscsi.extent.query`
- `iscsi.extent.update`
- `iscsi.extent.delete`
- `iscsi.targetextent.create`
- `iscsi.targetextent.query`
- `iscsi.targetextent.delete`

### NVMe-oF (11)

- `nvmet.port.create`
- `nvmet.port.query`
- `nvmet.port_subsys.create`
- `nvmet.port_subsys.query`
- `nvmet.subsys.create`
- `nvmet.subsys.query`
- `nvmet.subsys.update`
- `nvmet.namespace.create`
- `nvmet.namespace.query`
- `nvmet.namespace.update`
- `nvmet.namespace.delete`

### Service (1)

- `service.query`

---

## Non-core methods (installer, tests, dev scripts, 14)

These appear in `install.sh`, `tools/dev-truenas-plugin-full-function-test.sh`,
and the rate-limit test suite. Not on the production hot path, but a
breaking change will surface as installer or test-suite failure.

### iSCSI setup

- `iscsi.portal.create`
- `iscsi.portal.query`
- `iscsi.portal.delete`
- `iscsi.target.create`
- `iscsi.target.delete`

### NVMe-oF setup + diagnostics

- `nvmet.global.config`
- `nvmet.global.sessions`
- `nvmet.subsys.delete`

### Service management

- `service.start`
- `service.stop`
- `service.restart`

### System / diagnostic

- `system.info`

### ZFS resource (test suite only)

- `zfs.resource.snapshot.clone`
- `zfs.resource.snapshot.clone_impl`

---

## Regeneration

Re-run whenever code changes the API surface. From the repo root:

```bash
# plugin-core (production runtime)
grep -hoE "['\"][a-z][a-z0-9_]*\.[a-z][a-z0-9._]+['\"]" \
    TrueNASPlugin.pm tools/truenas-plugin-broker \
  | tr -d "'\"" \
  | grep -E '^(pool|iscsi|nvmet|service|core|auth|system|zfs)\.' \
  | sort -u

# whole repo (adds installer + tests)
grep -rhoE "['\"][a-z][a-z0-9_]*\.[a-z][a-z0-9._]+['\"]" . \
  | tr -d "'\"" \
  | grep -E '^(pool|iscsi|nvmet|service|core|auth|system|zfs|api_key|user|group|privilege|snapshottask)\.' \
  | sort -u
```

The regex over-matches quoted dotted strings that happen to look like
API methods; hand-audit any new entries the next scan surfaces before
adding them to this list.

## Monitoring API drift

For each release of TrueNAS SCALE:

1. On a system running the target release, capture the full method
   surface:

   ```bash
   midclt call core.get_methods > /tmp/tn-methods-<version>.json
   ```

2. For every method in this inventory, check that it still exists in
   the JSON and that its argument schema has not changed in a
   backward-incompatible way. `midclt call core.get_methods
   '{"filter":{"names":["pool.dataset.create"]}}'` returns the
   argument schema for a single method.

3. Also diff the returned `roles` array against
   [§3.8 Least-privilege TrueNAS API user](TrueNAS-Proxmox-Plugin-Best-Practices.md#38-least-privilege-truenas-api-user)
   in the best-practices doc — a role rename or removal breaks the
   least-privilege setup even if the method itself is unchanged.
