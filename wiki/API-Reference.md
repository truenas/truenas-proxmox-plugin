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

**Connection URL**: `wss://TRUENAS_HOST:443/websocket`

**Benefits**:
- Persistent connection (no repeated TLS handshake)
- Lower latency (~20-30ms faster per operation)
- Connection pooling and reuse
- Real-time updates (not currently used)

**Limitations**:
- May be unstable on some networks
- Requires TrueNAS SCALE 22.12+

### REST Transport

**Configuration**:
```ini
api_transport rest
api_scheme https    # or http for unencrypted
api_port 443        # or 80 for unencrypted
```

**Base URL**: `https://TRUENAS_HOST:443/api/v2.0/`

**Benefits**:
- More stable on unreliable networks
- Compatible with all TrueNAS SCALE versions
- Standard HTTP semantics

**Limitations**:
- Higher latency (new connection per request)
- Repeated TLS handshakes

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

| Version | WebSocket | Bulk Ops | Notes |
|---------|-----------|----------|-------|
| 22.02 | Limited | No | Basic functionality only |
| 22.12 | Yes | Limited | WebSocket stable |
| 23.10 | Yes | Yes | Bulk operations available |
| 24.04 | Yes | Yes | Improved performance |
| 25.04+ | Yes | Yes | Recommended (optimal) |

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
