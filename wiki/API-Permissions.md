# Minimum API Permissions

A granular, least-privilege TrueNAS role set for the Proxmox plugin's API user, as an alternative to granting the built-in `SHARING_ADMIN`/`FULL_ADMIN` roles described in [Installation.md](Installation.md#5-generate-api-key).

## Why

The plugin only ever calls a fixed, small set of TrueNAS middleware methods (see [Method-to-role mapping](#method-to-role-mapping) below). A dedicated API user restricted to exactly those roles can create/modify/delete datasets, snapshots, and iSCSI/NVMe-TCP shares - but nothing else on the TrueNAS system (no user management, no network/system config, no other pools' shares beyond what RBAC scoping allows - see [Caveats](#caveats)).


## Quick summary

| Role | Grants |
|---|---|
| `POOL_READ` | Pool status queries (`pool.query`) |
| `DATASET_WRITE` | Create/update/rename/query datasets and zvols |
| `DATASET_DELETE` | Delete datasets and zvols |
| `SNAPSHOT_WRITE` | Create/query/clone/rollback snapshots |
| `SNAPSHOT_DELETE` | Delete snapshots |
| `SERVICE_READ` | Query service status (`service.query`) |

Add for **iSCSI**:

| Role | Grants |
|---|---|
| `SHARING_ISCSI_GLOBAL_READ` | Read iSCSI global config |
| `SHARING_ISCSI_TARGET_READ` | Query iSCSI targets |
| `SHARING_ISCSI_EXTENT_WRITE` | Create/update/delete/query extents |
| `SHARING_ISCSI_TARGETEXTENT_WRITE` | Create/delete/query target-extent mappings |

Add for **NVMe-TCP**:

| Role | Grants |
|---|---|
| `SHARING_NVME_TARGET_WRITE` | Create/update/delete/query ports, port-subsystem links, subsystems, and namespaces - one role covers every NVMe-TCP object type |

A site running only one transport can drop the other transport's roles. `auth.login_with_api_key`, `core.ping`, `core.bulk`, and `core.get_jobs` require no role at all - any authenticated key can call them.

## Method-to-role mapping

Roles are OR'd - a caller needs *any one* of the listed roles, not all of them. Where a `*_WRITE` role appears in a query method's own allowed-role list, that role already grants the read too, so a dedicated read role isn't needed alongside it.

### Common (both transports)

| Method | Allowed roles (minimum in **bold**) |
|---|---|
| `pool.query` | **`POOL_READ`**, `POOL_WRITE`, `READONLY_ADMIN`, `SHARING_ADMIN` |
| `pool.dataset.create` | **`DATASET_WRITE`**, `SHARING_ADMIN` |
| `pool.dataset.query` | `DATASET_READ`, **`DATASET_WRITE`**, `READONLY_ADMIN`, `SHARING_ADMIN` |
| `pool.dataset.get_instance` | `DATASET_READ`, **`DATASET_WRITE`**, `READONLY_ADMIN`, `SHARING_ADMIN` |
| `pool.dataset.update` | **`DATASET_WRITE`**, `SHARING_ADMIN` |
| `pool.dataset.rename` | **`DATASET_WRITE`**, `SHARING_ADMIN` |
| `pool.dataset.delete` | **`DATASET_DELETE`** |
| `pool.snapshot.create` | `REPLICATION_ADMIN`, **`SNAPSHOT_WRITE`** |
| `pool.snapshot.query` | `READONLY_ADMIN`, `REPLICATION_ADMIN`, `SHARING_ADMIN`, `SNAPSHOT_READ`, **`SNAPSHOT_WRITE`** |
| `pool.snapshot.clone` | `DATASET_WRITE`\*, `REPLICATION_ADMIN`, `SHARING_ADMIN`, **`SNAPSHOT_WRITE`** |
| `pool.snapshot.rollback` | `POOL_WRITE`, `REPLICATION_ADMIN`, **`SNAPSHOT_WRITE`** |
| `pool.snapshot.delete` | **`SNAPSHOT_DELETE`** |
| `service.query` | `READONLY_ADMIN`, `SHARING_ADMIN`, **`SERVICE_READ`** |
| `auth.login_with_api_key`, `core.ping`, `core.bulk`, `core.get_jobs` | none required |

\* `pool.snapshot.clone` also lists `DATASET_WRITE` as an alternative; `SNAPSHOT_WRITE` alone is sufficient and is what this role set uses.

### iSCSI

| Method | Allowed roles (minimum in **bold**) |
|---|---|
| `iscsi.global.config` | `READONLY_ADMIN`, `SHARING_ADMIN`, **`SHARING_ISCSI_GLOBAL_READ`**, `SHARING_ISCSI_GLOBAL_WRITE`, `SHARING_ISCSI_READ`, `SHARING_ISCSI_WRITE`, `SHARING_READ`, `SHARING_WRITE` |
| `iscsi.target.query` | `READONLY_ADMIN`, `SHARING_ADMIN`, `SHARING_ISCSI_READ`, **`SHARING_ISCSI_TARGET_READ`**, `SHARING_ISCSI_TARGET_WRITE`, `SHARING_ISCSI_WRITE`, `SHARING_READ`, `SHARING_WRITE` |
| `iscsi.extent.create` / `.update` / `.delete` | `SHARING_ADMIN`, **`SHARING_ISCSI_EXTENT_WRITE`**, `SHARING_ISCSI_WRITE`, `SHARING_WRITE` |
| `iscsi.extent.query` | `READONLY_ADMIN`, `SHARING_ADMIN`, `SHARING_ISCSI_EXTENT_READ`, **`SHARING_ISCSI_EXTENT_WRITE`**, `SHARING_ISCSI_READ`, `SHARING_ISCSI_WRITE`, `SHARING_READ`, `SHARING_WRITE` |
| `iscsi.targetextent.create` / `.delete` | `SHARING_ADMIN`, **`SHARING_ISCSI_TARGETEXTENT_WRITE`**, `SHARING_ISCSI_WRITE`, `SHARING_WRITE` |
| `iscsi.targetextent.query` | `READONLY_ADMIN`, `SHARING_ADMIN`, `SHARING_ISCSI_READ`, `SHARING_ISCSI_TARGETEXTENT_READ`, **`SHARING_ISCSI_TARGETEXTENT_WRITE`**, `SHARING_ISCSI_WRITE`, `SHARING_READ`, `SHARING_WRITE` |

The plugin never creates or modifies iSCSI targets or the global config - the target and portal are set up once by the TrueNAS admin (see [Installation.md](Installation.md#3-create-iscsi-target)) and only queried at runtime, hence the read-only roles for those two methods.

### NVMe-TCP

| Method | Allowed roles (minimum in **bold**) |
|---|---|
| `nvmet.port.create` / `.query` | `READONLY_ADMIN`\*, `SHARING_ADMIN`, `SHARING_NVME_TARGET_READ`\*, **`SHARING_NVME_TARGET_WRITE`**, `SHARING_READ`\*, `SHARING_WRITE` |
| `nvmet.port_subsys.create` / `.query` | same as above |
| `nvmet.subsys.create` / `.query` / `.update` | same as above |
| `nvmet.namespace.create` / `.query` / `.update` / `.delete` | same as above |

\* `*_READ` roles only apply to the `.query` methods; the create/update/delete methods only accept the `*_WRITE`-tier roles. `SHARING_NVME_TARGET_WRITE` is the single role needed for every NVMe-TCP object type the plugin touches, including delete - TrueNAS doesn't split NVMe-TCP delete into a separate role the way it does for datasets and snapshots.

## Creating the least-privilege API user

There's no `api_key.create` parameter for attaching custom roles directly to a key - API keys inherit whatever roles their owning user has, and users get roles by belonging to a group with an attached **Privilege**. Run these from a TrueNAS shell (`System Settings` → `Shell`, or SSH) with `midclt call <method> <json-arg> [<json-arg> ...]` — each argument after the method name is JSON-decoded and passed as one positional parameter directly (not wrapped in an outer array), verified against a live TrueNAS 25.10.2.1 shell:

```bash
# 1. Create a dedicated group
midclt call group.create '{"name": "proxmox_plugin"}'
# -> note the returned "id"; then look up its gid:
midclt call group.query '[["name", "=", "proxmox_plugin"]]'

# 2. Create a Privilege (role bundle) attached to that group.
#    IMPORTANT: local_groups takes the group's Unix gid, not its record id
#    (the API schema description says otherwise but the server resolves by gid).
midclt call privilege.create '{
  "name": "proxmox-plugin-minimal",
  "local_groups": [<GID_FROM_STEP_1>],
  "roles": [
    "POOL_READ", "DATASET_WRITE", "DATASET_DELETE",
    "SNAPSHOT_WRITE", "SNAPSHOT_DELETE", "SERVICE_READ",
    "SHARING_ISCSI_GLOBAL_READ", "SHARING_ISCSI_TARGET_READ",
    "SHARING_ISCSI_EXTENT_WRITE", "SHARING_ISCSI_TARGETEXTENT_WRITE",
    "SHARING_NVME_TARGET_WRITE"
  ],
  "web_shell": false
}'

# 3. Create a user in that group (no shell/SMB/password login needed - API-key only)
midclt call user.create '{
  "username": "proxmox_plugin",
  "full_name": "Proxmox VE Storage Plugin",
  "group_create": false,
  "group": <GROUP_RECORD_ID_FROM_STEP_1>,
  "password_disabled": true,
  "smb": false,
  "home": "/var/empty",
  "shell": "/usr/sbin/nologin"
}'

# 4. Generate the API key for that user
midclt call api_key.create '{"name": "proxmox-plugin-key", "username": "proxmox_plugin"}'
```

Copy the `key` value from step 4's response into `tn_api_key` in `storage.cfg` (see [Configuration.md](Configuration.md#required-parameters)). Drop the `SHARING_ISCSI_*` or `SHARING_NVME_TARGET_WRITE` roles in step 2 if the site only uses one transport.

## Caveats

- **Roles are global, not dataset-scoped.** `DATASET_WRITE`/`DATASET_DELETE` let the key touch *any* dataset on the TrueNAS system, not just the one configured in `tn_dataset`. TrueNAS's RBAC model authorizes at the method level, not per-resource - there's no built-in way to confine a role to a single dataset subtree.
- **`api_key.create` only takes a `username`.** There's no way to assign roles to a key directly; the key inherits its owning user's roles, which come from group membership + an attached Privilege, as shown above.
- **This is verified against TrueNAS SCALE 25.10.2.1.** Role names and method-to-role mappings come from that version's `core.get_methods` output. Re-verify with the same command if running a materially newer TrueNAS release.

## See also

- [Installation.md](Installation.md#5-generate-api-key) - where the API key is generated and configured
- [API-Reference.md](API-Reference.md) - full method/parameter/response reference for every TrueNAS call the plugin makes
- [Configuration.md](Configuration.md) - `storage.cfg` parameter reference

*Note:*
This role set was derived by:
1. Grepping every `_api_call`/`_api_call_mutate`/`core.bulk` call site in `TrueNASPlugin.pm` for the literal method name passed
2. Cross-referencing each method against `core.get_methods`, which returns the exact `roles` array TrueNAS itself enforces per method (ground truth from the middleware, not documentation)
3. Live-testing the resulting role set end-to-end on TrueNAS SCALE 25.10.2.1: disk alloc/resize/delete, snapshot create/rollback/delete, linked clone (`create_base`/`clone_image`), the vzdump-style ephemeral snapshot clone path (`activate_volume`/`deactivate_volume` with a snapshot name), and LXC `rootdir` volumes - on both iSCSI and NVMe-TCP transports