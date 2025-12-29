# API Reference

Technical reference for TrueNAS API integration used by the Proxmox VE Storage Plugin.

## Overview

The plugin integrates with TrueNAS SCALE via two API transports:
- **WebSocket (JSON-RPC)** - Default, recommended for performance
- **REST (HTTP)** - Fallback, more compatible

## API Transport Selection

### WebSocket Transport

**Configuration**:
```ini
api_transport ws
api_scheme wss      # or ws for unencrypted
api_port 443        # or 80 for unencrypted
```

**Connection URL**:
- TrueNAS 24.10 and earlier: `wss://TRUENAS_HOST:443/websocket`
- TrueNAS 25.04+: `wss://TRUENAS_HOST:443/api/current` (legacy `/websocket` still supported)

**Benefits**:
- Persistent connection (no repeated TLS handshake)
- Lower latency (~20-30ms faster per operation)
- Connection pooling and reuse
- Real-time updates (not currently used)
- **Required for TrueNAS 26.04+**

**Limitations**:
- May be unstable on some networks
- Requires TrueNAS SCALE 22.12+

### REST Transport

**⚠️ DEPRECATION NOTICE**: The TrueNAS REST API was deprecated in TrueNAS SCALE 25.04 and will be removed in version 26.04 (expected April 2026). Use WebSocket transport for TrueNAS 25.04 and later.

**Configuration** (Legacy - TrueNAS 24.10 and earlier only):
```ini
api_transport rest
api_scheme https    # or http for unencrypted
api_port 443        # or 80 for unencrypted
```

**Base URL**: `https://TRUENAS_HOST:443/api/v2.0/`

**Benefits**:
- More stable on unreliable networks
- Compatible with TrueNAS SCALE versions 22.x through 25.04
- Standard HTTP semantics

**Limitations**:
- Higher latency (new connection per request)
- Repeated TLS handshakes
- **Not available in TrueNAS 26.04+**

## Authentication

### API Key Generation

Generate API keys in TrueNAS:
1. Navigate to **Credentials** → **Local Users**
2. Select user (root or dedicated user)
3. Click **Edit**
4. Scroll to **API Key** section
5. Click **Add** to generate new key
6. Copy key immediately (format: `1-xxxxx...`)

### Authorization Header

All API requests include authorization header:
```
Authorization: Bearer 1-your-api-key-here
```

### Required Permissions

API user must have permissions for:
- **Pool/Dataset Management**: Create, modify, delete datasets and zvols
- **iSCSI Sharing**: Create, modify, delete targets, extents, targetextents
- **System Information**: Query system info, services status

## Core API Endpoints

### Dataset Operations

#### List Datasets
```
WebSocket: pool.dataset.query
REST: GET /api/v2.0/pool/dataset
```

**Parameters**:
```json
[
  [["id", "^", "tank/proxmox"]],  // Filter by dataset path prefix
  {"extra": {"properties": ["used", "available", "referenced"]}}
]
```

**Response**:
```json
[
  {
    "id": "tank/proxmox",
    "type": "FILESYSTEM",
    "name": "tank/proxmox",
    "pool": "tank",
    "used": {"parsed": 1073741824},
    "available": {"parsed": 107374182400},
    "referenced": {"parsed": 524288}
  }
]
```

#### Batch Fetch Child Datasets (Optimized)

The plugin uses batch fetching for efficient list operations, retrieving all child datasets with a single query:

```
WebSocket: pool.dataset.query
REST: GET /api/v2.0/pool/dataset?filters=[["id","^","tank/proxmox/"]]
```

**Parameters**:
```json
[
  [["id", "^", "tank/proxmox/"]],
  {"extra": {"properties": ["used", "available", "referenced", "name", "volsize", "volblocksize"]}}
]
```

**Response**: Array of all child datasets matching prefix:
```json
[
  {
    "id": "tank/proxmox/vm-100-disk-0",
    "type": "VOLUME",
    "name": "vm-100-disk-0",
    "pool": "tank",
    "volsize": {"parsed": 34359738368},
    "volblocksize": {"parsed": 131072},
    "used": {"parsed": 1073741824},
    "available": {"parsed": 107374182400},
    "referenced": {"parsed": 1073741824}
  },
  {
    "id": "tank/proxmox/vm-100-disk-1",
    "type": "VOLUME",
    "name": "vm-100-disk-1",
    ...
  }
]
```

**Optimization Details**:
- **Filter**: Uses starts-with (`^`) operator to match all children of parent dataset
- **Single Request**: Replaces O(n) individual queries with O(1) batch query
- **Hash Lookup**: Results are built into hash table for O(1) metadata lookups
- **Implementation**: See `_list_images_iscsi()` and `_list_images_nvme()` functions (TrueNASPlugin.pm)
- **Performance**: 7.5x faster for 100+ volume deployments

**Fallback**:
If batch fetch fails (network error, API issue), plugin falls back to individual `pool.dataset.query` calls for each volume to maintain robustness.

#### Get Dataset Info
```
WebSocket: pool.dataset.query
REST: GET /api/v2.0/pool/dataset/id/tank%2Fproxmox
```

**Response**: Same as list, single object

#### Create Zvol
```
WebSocket: pool.dataset.create
REST: POST /api/v2.0/pool/dataset
```

**Parameters**:
```json
{
  "name": "tank/proxmox/vm-100-disk-0",
  "type": "VOLUME",
  "volsize": 34359738368,
  "volblocksize": "128K",
  "sparse": true
}
```

**Response**:
```json
{
  "id": "tank/proxmox/vm-100-disk-0",
  "type": "VOLUME",
  "volsize": {"parsed": 34359738368},
  "volblocksize": {"parsed": 131072},
  "sparse": true
}
```

#### Resize Zvol
```
WebSocket: pool.dataset.update
REST: PUT /api/v2.0/pool/dataset/id/tank%2Fproxmox%2Fvm-100-disk-0
```

**Parameters**:
```json
{
  "volsize": 68719476736
}
```

#### Delete Zvol
```
WebSocket: pool.dataset.delete
REST: DELETE /api/v2.0/pool/dataset/id/tank%2Fproxmox%2Fvm-100-disk-0
```

**Parameters**: `{"recursive": true}`

### Snapshot Operations

#### Create Snapshot
```
WebSocket: zfs.snapshot.create
REST: POST /api/v2.0/zfs/snapshot
```

**Parameters**:
```json
{
  "dataset": "tank/proxmox/vm-100-disk-0",
  "name": "snap1",
  "recursive": false
}
```

**Response**:
```json
{
  "name": "tank/proxmox/vm-100-disk-0@snap1",
  "dataset": "tank/proxmox/vm-100-disk-0",
  "snapshot_name": "snap1"
}
```

#### List Snapshots
```
WebSocket: zfs.snapshot.query
REST: GET /api/v2.0/zfs/snapshot
```

**Parameters**:
```json
[
  [["dataset", "=", "tank/proxmox/vm-100-disk-0"]]
]
```

#### Delete Snapshot
```
WebSocket: zfs.snapshot.delete
REST: DELETE /api/v2.0/zfs/snapshot/id/tank%2Fproxmox%2Fvm-100-disk-0@snap1
```

#### Rollback Snapshot
```
WebSocket: zfs.snapshot.rollback
REST: POST /api/v2.0/zfs/snapshot/id/tank%2Fproxmox%2Fvm-100-disk-0@snap1/rollback
```

### iSCSI Operations

#### List Targets
```
WebSocket: iscsi.target.query
REST: GET /api/v2.0/iscsi/target
```

**Response**:
```json
[
  {
    "id": 1,
    "name": "iqn.2005-10.org.freenas.ctl:proxmox",
    "alias": "Proxmox Storage",
    "mode": "ISCSI"
  }
]
```

#### List Extents
```
WebSocket: iscsi.extent.query
REST: GET /api/v2.0/iscsi/extent
```

**Response**:
```json
[
  {
    "id": 10,
    "name": "vm-100-disk-0",
    "type": "DISK",
    "disk": "zvol/tank/proxmox/vm-100-disk-0",
    "serial": "10000000",
    "blocksize": 512,
    "enabled": true
  }
]
```

#### Create Extent
```
WebSocket: iscsi.extent.create
REST: POST /api/v2.0/iscsi/extent
```

**Parameters**:
```json
{
  "name": "vm-100-disk-0",
  "type": "DISK",
  "disk": "zvol/tank/proxmox/vm-100-disk-0",
  "serial": "auto",
  "blocksize": 512,
  "enabled": true
}
```

**Response**: Created extent object with assigned `id`

#### Delete Extent
```
WebSocket: iscsi.extent.delete
REST: DELETE /api/v2.0/iscsi/extent/id/10
```

**Parameters**: `{"force": true}` (optional)

#### List Target Extents
```
WebSocket: iscsi.targetextent.query
REST: GET /api/v2.0/iscsi/targetextent
```

**Response**:
```json
[
  {
    "id": 5,
    "target": 1,
    "extent": 10,
    "lunid": 1
  }
]
```

#### Create Target Extent
```
WebSocket: iscsi.targetextent.create
REST: POST /api/v2.0/iscsi/targetextent
```

**Parameters**:
```json
{
  "target": 1,
  "extent": 10,
  "lunid": null  // Auto-assign
}
```

**Response**: Created targetextent with assigned `lunid`

#### Delete Target Extent
```
WebSocket: iscsi.targetextent.delete
REST: DELETE /api/v2.0/iscsi/targetextent/id/5
```

### NVMe-oF Operations

**Note**: NVMe-oF operations are only available via WebSocket transport. REST API does not support `nvmet.*` endpoints.

#### List NVMe Subsystems
```
WebSocket: nvmet.subsys.query
REST: Not supported
```

**Response**:
```json
[
  {
    "id": 1,
    "name": "proxmox-nvme",
    "subnqn": "nqn.2005-10.org.freenas.ctl:proxmox-nvme",
    "allow_any_host": true
  }
]
```

#### List NVMe Namespaces
```
WebSocket: nvmet.namespace.query
REST: Not supported
```

**Parameters** (filter by device UUID):
```json
[
  [["device_uuid", "=", "eab32e9b-2668-4a74-b82b-0a6e7f9b3d77"]]
]
```

**Response**:
```json
[
  {
    "id": 1,
    "nsid": 2,
    "device_uuid": "eab32e9b-2668-4a74-b82b-0a6e7f9b3d77",
    "device_nguid": "b68c0fbe-93ea-46a9-9e2f-e9c5a5f50e4b",
    "device_path": "zvol/flash/nvme-test/vm-100-disk-0",
    "subsys_id": 1,
    "device_type": "ZVOL",
    "enabled": true
  }
]
```

**Key Fields for Device Matching**:
- `device_uuid`: TrueNAS middleware UUID (used in volume naming: `vol-<zname>-ns<device_uuid>`)
- `device_nguid`: NVMe Namespace GUID - matches `/sys/block/nvmeXnY/nguid` (primary matching method)
- `nsid`: NVMe Namespace ID - matches `/sys/block/nvmeXnY/nsid` (fallback matching method)

**Device Matching Strategy**:

The plugin uses a three-tier matching strategy in `_nvme_find_device_by_subsystem()`:

1. **Tier 1: NGUID Matching (Primary)**
   - Queries `nvmet.namespace.query` by `device_uuid` to get namespace info
   - Extracts `device_nguid` from API response
   - Compares against `/sys/block/nvmeXnY/nguid` for each device on subsystem
   - Most reliable - NGUID is globally unique and consistent across multipath controllers

2. **Tier 2: NSID Matching (Fallback)**
   - If API call fails or `device_nguid` field not available (older TrueNAS versions)
   - Extracts `nsid` from API response
   - Reads NSID from `/sys/block/nvmeXnY/nsid` sysfs file (NOT from device name)
   - Important: Device names like `nvme3n5` do NOT reliably indicate NSID

3. **Tier 3: Single Device (Safe Fallback)**
   - If only one namespace exists on subsystem, returns it safely
   - Avoids ambiguity when metadata matching unavailable

**Note**: The unreliable "newest device" timestamp fallback was eliminated in v1.1.12 to prevent race conditions.

#### Create NVMe Namespace
```
WebSocket: nvmet.namespace.create
REST: Not supported
```

**Parameters**:
```json
{
  "device_type": "ZVOL",
  "device_path": "zvol/tank/proxmox/vm-100-disk-0",
  "subsys_id": 1,
  "enabled": true
}
```

**Response**: Created namespace object with `device_uuid`, `device_nguid`, and `nsid`

#### Delete NVMe Namespace
```
WebSocket: nvmet.namespace.delete
REST: Not supported
```

**Parameters**: `{"id": <namespace_id>}`

### Service Operations

#### Query Service Status
```
WebSocket: service.query
REST: GET /api/v2.0/service
```

**Parameters**:
```json
[
  [["service", "=", "iscsitarget"]]
]
```

**Response**:
```json
[
  {
    "id": 5,
    "service": "iscsitarget",
    "state": "RUNNING",
    "enable": true
  }
]
```

### System Operations

#### Get System Info
```
WebSocket: system.info
REST: GET /api/v2.0/system/info
```

**Response**:
```json
{
  "version": "TrueNAS-SCALE-25.04.0",
  "hostname": "truenas",
  "uptime_seconds": 86400
}
```

## Bulk Operations

### Bulk API Call

When `enable_bulk_operations=1`, multiple operations are batched:

```
WebSocket: core.bulk
REST: POST /api/v2.0/core/bulk
```

**Parameters**:
```json
[
  {
    "method": "pool.dataset.create",
    "params": [{"name": "tank/proxmox/vm-100-disk-0", "type": "VOLUME", ...}]
  },
  {
    "method": "iscsi.extent.create",
    "params": [{"name": "vm-100-disk-0", ...}]
  },
  {
    "method": "iscsi.targetextent.create",
    "params": [{"target": 1, "extent": 10}]
  }
]
```

**Response**:
```json
[
  {"result": {...}, "error": null},
  {"result": {...}, "error": null},
  {"result": {...}, "error": null}
]
```

**Benefits**:
- Reduces API call count (3 calls → 1 call)
- Reduces rate limit consumption
- Lower total latency

## Error Handling

### Common Error Codes

| Status | Meaning | Cause |
|--------|---------|-------|
| 401 | Unauthorized | Invalid API key |
| 403 | Forbidden | Insufficient permissions |
| 404 | Not Found | Resource doesn't exist |
| 409 | Conflict | Resource already exists |
| 422 | Validation Error | Invalid parameters |
| 500 | Internal Server Error | TrueNAS error |
| 502 | Bad Gateway | TrueNAS offline |
| 503 | Service Unavailable | TrueNAS overloaded |

### Error Response Format

**WebSocket**:
```json
{
  "error": {
    "errname": "InstanceNotFound",
    "message": "Dataset tank/proxmox/vm-999-disk-0 does not exist"
  }
}
```

**REST**:
```json
{
  "message": "Dataset tank/proxmox/vm-999-disk-0 does not exist",
  "errno": 2
}
```

### Retryable Errors

The plugin automatically retries these errors:
- Network timeouts
- Connection refused
- SSL/TLS errors
- HTTP 502/503/504 (gateway errors)
- Rate limiting errors

### Non-Retryable Errors

These errors fail immediately:
- 401 Unauthorized (authentication)
- 403 Forbidden (permissions)
- 404 Not Found (validation)
- 422 Validation Error

## Rate Limiting

### TrueNAS Rate Limits

**Limit**: 20 API calls per 60 seconds per IP address

**Penalty**: 10-minute cooldown when exceeded

**Plugin Mitigation**:
1. Connection caching (WebSocket reuse)
2. Bulk operations batching
3. Automatic retry with exponential backoff

### Rate Limit Headers

REST responses include rate limit headers:
```
X-RateLimit-Limit: 20
X-RateLimit-Remaining: 15
X-RateLimit-Reset: 1640000000
```

## Connection Management

### WebSocket Connection Caching

**Cache Lifetime**: 60 seconds

**Behavior**:
- First API call creates WebSocket connection
- Subsequent calls reuse connection (within 60s)
- Connection auto-closed after 60s idle
- Auto-reconnect on connection loss

**Benefits**:
- Reduced TLS handshake overhead
- Lower API call count (no repeated auth)
- Better performance (~20-30ms savings per call)

### Connection Pooling

Multiple simultaneous operations share connections:
- One connection per `(host, port, scheme)` tuple
- Thread-safe connection management
- Automatic cleanup of stale connections

### Fork Safety

Persistent WebSocket connections are protected against fork-related issues (common with pvestatd workers):

- **PID Tracking**: Connections track the process that created them
- **Fork Detection**: Child processes detect inherited connections via PID mismatch
- **NullDestructor Pattern**: Inherited sockets are reblessed into a class with empty `DESTROY` method
- **Result**: No double-free crashes when child processes exit - parent connections remain valid

## Query Optimization

### Filtered Queries

Use filters to reduce response size:

**Example** - Get specific dataset only:
```json
[
  [["id", "=", "tank/proxmox/vm-100-disk-0"]]
]
```

**Example** - Get datasets under parent:
```json
[
  [["id", "^", "tank/proxmox/"]]  // ^ means "starts with"
]
```

### Property Selection

Request only needed properties:

```json
{
  "extra": {
    "properties": ["used", "available", "referenced"]
  }
}
```

Reduces:
- Network transfer size
- JSON parsing overhead
- Memory usage

## Security Considerations

### TLS Certificate Verification

**Production** (recommended):
```ini
api_scheme wss      # or https
api_insecure 0      # Verify certificates
```

**Testing** (self-signed certs):
```ini
api_insecure 1      # Skip verification
```

**Warning**: Never use `api_insecure=1` in production

### API Key Storage

API keys stored in `/etc/pve/storage.cfg`:
- File permissions: `0640` (root:www-data)
- Only root can edit
- Cluster-wide configuration

**Best Practice**: Use dedicated API user with minimal permissions

### Network Security

**Recommendations**:
- Use dedicated VLAN for storage
- Firewall rules limiting API access
- TLS encryption in production
- Monitor TrueNAS audit logs

## Plugin API Call Patterns

### Volume Creation

1. Pre-flight validation:
   - `pool.dataset.query` - Check parent dataset exists
   - `pool.dataset.query` - Get available space
   - `service.query` - Check iSCSI service running
   - `iscsi.target.query` - Verify target exists

2. Volume creation:
   - `pool.dataset.create` - Create zvol
   - `iscsi.extent.create` - Create iSCSI extent
   - `iscsi.targetextent.create` - Associate extent with target

3. Verification:
   - Wait for device to appear in `/dev/disk/by-path/`
   - Verify iSCSI session active

### Volume Deletion

1. `iscsi.targetextent.query` - Find targetextent
2. `iscsi.targetextent.delete` - Delete targetextent
3. `iscsi.extent.query` - Find extent
4. `iscsi.extent.delete` - Delete extent
5. `pool.dataset.delete` - Delete zvol (recursive)

### Snapshot Creation

1. `zfs.snapshot.create` - Create snapshot
2. `zfs.snapshot.query` - Verify created

### Status Check

1. `pool.dataset.query` - Get dataset info
2. Parse `used` and `available` from response
3. Classify any errors (connectivity, config, unknown)

## API Version Compatibility

### TrueNAS SCALE Versions

| Version | WebSocket | REST API | Bulk Ops | Recommended Transport | Notes |
|---------|-----------|----------|----------|-----------------------|-------|
| 22.02 | Limited | Yes | No | REST | Basic functionality only |
| 22.12 | Yes | Yes | Limited | WebSocket | WebSocket stable |
| 23.10 | Yes | Yes | Yes | WebSocket | Bulk operations available |
| 24.04 | Yes | Yes | Yes | WebSocket | Improved performance |
| 24.10 | Yes | Yes | Yes | WebSocket | Last version with full REST support |
| 25.04 | Yes | Deprecated | Yes | **WebSocket only** | REST API deprecated, use WebSocket |
| 26.04+ (Future) | Yes | Removed | Yes | **WebSocket only** | REST API removed, WebSocket required (Expected: April 2026) |

### API Endpoints

All endpoints use `/api/v2.0/` base path.

**Future Compatibility**: TrueNAS maintains API v2.0 compatibility across versions.

## Debugging API Calls

### Enable Debug Logging

**Proxmox**:
```bash
# Watch API-related logs
journalctl -u pvedaemon -f | grep -i truenas
```

**TrueNAS**:
```bash
# Watch middleware API logs
tail -f /var/log/middlewared.log

# Filter for specific calls
tail -f /var/log/middlewared.log | grep pool.dataset
```

### Manual API Testing

**WebSocket** (using `wscat`):
```bash
# Install wscat
npm install -g wscat

# Connect
wscat -c wss://TRUENAS_IP/websocket

# Send request
{"id": "test", "msg": "method", "method": "system.info"}
```

**REST** (using `curl`):
```bash
# Get system info
curl -k -H "Authorization: Bearer YOUR_API_KEY" \
  https://TRUENAS_IP/api/v2.0/system/info

# Create dataset
curl -k -X POST \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "tank/test", "type": "FILESYSTEM"}' \
  https://TRUENAS_IP/api/v2.0/pool/dataset
```

## See Also
- [Configuration Reference](Configuration.md) - API configuration parameters
- [Advanced Features](Advanced-Features.md) - Performance tuning
- [Troubleshooting](Troubleshooting.md) - API connection issues
