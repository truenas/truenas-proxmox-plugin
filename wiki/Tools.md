# Tools and Utilities

Documentation for included tools and utilities to help manage the TrueNAS Proxmox VE Storage Plugin.

## Overview

The plugin includes several tools to simplify installation, testing, and cluster management:

- **[Test Suite](#test-suite)** - Automated testing and validation
- **[Version Check Script](#version-check-script)** - Check plugin version across cluster
- **[Cluster Update Script](#cluster-update-script)** - Deploy plugin to all cluster nodes
- **[Tools Directory](#tools-directory-structure)** - Location and organization

## Tools Directory Structure

```
tools/
├── truenas-plugin-test-suite.sh    # Automated test suite
├── update-cluster.sh                # Cluster deployment script
└── check-version.sh                 # Version checker for cluster
```

All tools are located in the `tools/` directory of the plugin repository.

---

## Test Suite

### Overview

The TrueNAS Plugin Test Suite (`truenas-plugin-test-suite.sh`) is a comprehensive automated testing tool that validates all major plugin functionality through the Proxmox API.

**Full documentation**: [Testing Guide](Testing.md)

### Quick Reference

**Location**: `tools/truenas-plugin-test-suite.sh`

**Basic Usage**:
```bash
# Navigate to tools directory
cd tools/

# Run test suite
./truenas-plugin-test-suite.sh your-storage-name

# Run with auto-confirmation
./truenas-plugin-test-suite.sh your-storage-name -y
```

**What It Tests**:
- Storage status and accessibility
- Volume creation and allocation
- Volume listing
- Snapshot operations
- Clone operations
- Volume resize
- VM start/stop operations
- Volume deletion and cleanup

**Requirements**:
- Root access
- Plugin installed and configured
- Active storage configuration
- ~10GB free space on TrueNAS

**Output**:
- Real-time console output with color-coded results
- Detailed log file in `/tmp/truenas-plugin-test-suite-*.log`
- Performance metrics for all operations
- Comprehensive summary report

### Common Commands

```bash
# Test default storage 'tnscale'
cd tools/
./truenas-plugin-test-suite.sh

# Test specific storage
./truenas-plugin-test-suite.sh production-storage

# Automated testing (no prompts)
./truenas-plugin-test-suite.sh production-storage -y

# View most recent test log
ls -lt /tmp/truenas-plugin-test-suite-*.log | head -1
tail -f /tmp/truenas-plugin-test-suite-$(date +%Y%m%d)-*.log
```

### Exit Codes

- `0` - All tests passed
- `1` - One or more tests failed

### See Also

Complete test suite documentation: [Testing Guide](Testing.md)

---

## Cluster Update Script

### Overview

The cluster update script (`update-cluster.sh`) automates deployment of the TrueNAS plugin to all nodes in a Proxmox VE cluster. It copies the plugin file, installs it to the correct location, and restarts required services on each node.

**Location**: `tools/update-cluster.sh`

### Features

- **Automated Deployment** - Install plugin on multiple nodes simultaneously
- **Service Management** - Automatically restarts required Proxmox services
- **Error Handling** - Reports failures per-node
- **Verification** - Confirms successful installation on each node
- **Color-coded Output** - Clear success/failure indicators

### Usage

#### Basic Syntax

```bash
./update-cluster.sh <node1> <node2> <node3> ...
```

**Parameters**:
- `node1 node2 node3 ...` - Hostnames or IP addresses of cluster nodes

**Requirements**:
- SSH access to all cluster nodes (passwordless recommended)
- Plugin file `TrueNASPlugin.pm` in parent directory
- Root access on all nodes

#### Examples

**Deploy to Three-Node Cluster**:
```bash
cd tools/
./update-cluster.sh pve1 pve2 pve3
```

**Deploy to Nodes by IP**:
```bash
cd tools/
./update-cluster.sh 192.168.1.10 192.168.1.11 192.168.1.12
```

**Deploy Using Variable**:
```bash
cd tools/
NODES="pve1 pve2 pve3"
./update-cluster.sh $NODES
```

**Deploy to All Nodes (Dynamic)**:
```bash
cd tools/
# Get all cluster nodes
NODES=$(pvesh get /cluster/status --output-format json | jq -r '.[] | select(.type=="node") | .name')
./update-cluster.sh $NODES
```

### What the Script Does

For each node specified, the script performs these steps:

1. **Display Header** - Shows which node is being updated
2. **Copy Plugin File** - SCPs `TrueNASPlugin.pm` to node
3. **Install Plugin** - Moves file to `/usr/share/perl5/PVE/Storage/Custom/`
4. **Set Permissions** - Ensures correct file permissions (644)
5. **Restart Services** - Restarts `pvedaemon`, `pveproxy`, and `pvestatd`
6. **Report Status** - Shows success or failure for the node

### Script Output

**Successful Deployment**:
```
=== Updating Node: pve1 ===
Copying plugin to pve1...
Installing plugin on pve1...
Restarting services on pve1...
✓ Successfully updated pve1

=== Updating Node: pve2 ===
Copying plugin to pve2...
Installing plugin on pve2...
Restarting services on pve2...
✓ Successfully updated pve2

=== Updating Node: pve3 ===
Copying plugin to pve3...
Installing plugin on pve3...
Restarting services on pve3...
✓ Successfully updated pve3

All nodes updated successfully!
```

**Failure Example**:
```
=== Updating Node: pve2 ===
Copying plugin to pve2...
Error: Failed to update pve2
```

### Prerequisites

#### 1. SSH Access

Set up passwordless SSH to all cluster nodes:

```bash
# Generate SSH key (if not already done)
ssh-keygen -t ed25519 -C "proxmox-admin"

# Copy key to each cluster node
ssh-copy-id root@pve1
ssh-copy-id root@pve2
ssh-copy-id root@pve3

# Test passwordless access
ssh root@pve1 "hostname"
ssh root@pve2 "hostname"
ssh root@pve3 "hostname"
```

#### 2. Plugin File Location

The script expects `TrueNASPlugin.pm` in the parent directory:

```
truenasplugin/
├── TrueNASPlugin.pm          # Plugin file here
└── tools/
    └── update-cluster.sh      # Script here
```

**Verify**:
```bash
cd tools/
ls -la ../TrueNASPlugin.pm
```

### Advanced Usage

#### Deploy and Verify

```bash
#!/bin/bash
# deploy-and-verify.sh

cd tools/

# Deploy to all nodes
./update-cluster.sh pve1 pve2 pve3

# Verify installation on each node
for node in pve1 pve2 pve3; do
    echo "=== Verifying $node ==="
    ssh root@$node "ls -la /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
    ssh root@$node "pvesm status | grep truenas"
done
```

#### Deploy Specific Version

```bash
#!/bin/bash
# deploy-version.sh

VERSION="$1"
NODES="pve1 pve2 pve3"

# Backup current version
for node in $NODES; do
    ssh root@$node "cp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm \
                        /root/TrueNASPlugin.pm.backup-$(date +%Y%m%d)"
done

# Deploy new version
cd tools/
./update-cluster.sh $NODES

# Verify version (if version string in plugin)
for node in $NODES; do
    ssh root@$node "grep -i version /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm | head -1"
done
```

#### Rollback on Failure

```bash
#!/bin/bash
# deploy-with-rollback.sh

NODES="pve1 pve2 pve3"

# Backup on all nodes first
echo "Creating backups..."
for node in $NODES; do
    ssh root@$node "cp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm \
                        /root/TrueNASPlugin.pm.backup"
done

# Deploy
cd tools/
if ./update-cluster.sh $NODES; then
    echo "Deployment successful"
else
    echo "Deployment failed, rolling back..."
    for node in $NODES; do
        ssh root@$node "cp /root/TrueNASPlugin.pm.backup \
                           /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
        ssh root@$node "systemctl restart pvedaemon pveproxy pvestatd"
    done
fi
```

### Troubleshooting

#### SSH Connection Fails

**Problem**: Cannot connect to node
```
Error: Failed to update pve2
```

**Solutions**:
```bash
# Test SSH connection
ssh root@pve2 "echo OK"

# Check SSH key
ssh-copy-id root@pve2

# Verify hostname resolution
ping -c 1 pve2

# Try IP address instead
./update-cluster.sh 192.168.1.11
```

#### Plugin File Not Found

**Problem**: `TrueNASPlugin.pm` not found

**Solutions**:
```bash
# Check current directory
pwd
# Should be: /path/to/truenasplugin/tools

# Check parent directory for plugin
ls -la ../TrueNASPlugin.pm

# If in wrong location, cd to correct location
cd /path/to/truenasplugin/tools
```

#### Permission Denied

**Problem**: Cannot write to `/usr/share/perl5/PVE/Storage/Custom/`

**Solutions**:
```bash
# Ensure using root SSH access
ssh root@pve1 "whoami"
# Should output: root

# Check directory permissions on node
ssh root@pve1 "ls -ld /usr/share/perl5/PVE/Storage/Custom/"

# Create directory if missing
ssh root@pve1 "mkdir -p /usr/share/perl5/PVE/Storage/Custom/"
```

#### Service Restart Fails

**Problem**: Services fail to restart

**Solutions**:
```bash
# Check service status on node
ssh root@pve1 "systemctl status pvedaemon"

# Check for configuration errors
ssh root@pve1 "journalctl -u pvedaemon -n 50"

# Manual restart
ssh root@pve1 "systemctl restart pvedaemon pveproxy pvestatd"
```

### Script Source Code

**Location**: `tools/update-cluster.sh`

**View Source**:
```bash
cat tools/update-cluster.sh
```

**Key Features**:
- Simple bash script, easy to customize
- Uses standard tools: `scp`, `ssh`
- Color-coded output for clarity
- Error handling with exit codes

### Integration with CI/CD

#### GitLab CI Example

```yaml
# .gitlab-ci.yml
deploy-to-cluster:
  stage: deploy
  script:
    - cd tools/
    - ./update-cluster.sh pve1 pve2 pve3
    - ./truenas-plugin-test-suite.sh production-storage -y
  only:
    - main
```

#### Jenkins Pipeline Example

```groovy
// Jenkinsfile
pipeline {
    agent any
    stages {
        stage('Deploy to Cluster') {
            steps {
                sh 'cd tools && ./update-cluster.sh pve1 pve2 pve3'
            }
        }
        stage('Test Plugin') {
            steps {
                sh 'cd tools && ./truenas-plugin-test-suite.sh production-storage -y'
            }
        }
    }
}
```

### Manual Alternative

If you prefer not to use the script, deploy manually:

```bash
# For each node
for node in pve1 pve2 pve3; do
    scp TrueNASPlugin.pm root@$node:/usr/share/perl5/PVE/Storage/Custom/
    ssh root@$node "chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
    ssh root@$node "systemctl restart pvedaemon pveproxy pvestatd"
done
```

### Best Practices

#### Before Deployment

1. **Test on One Node First**:
   ```bash
   # Deploy to single node for testing
   ./update-cluster.sh pve1

   # Verify it works
   ssh root@pve1 "pvesm status | grep truenas"

   # Then deploy to all nodes
   ./update-cluster.sh pve2 pve3
   ```

2. **Backup Current Version**:
   ```bash
   for node in pve1 pve2 pve3; do
       ssh root@$node "cp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm \
                           /root/TrueNASPlugin.pm.$(date +%Y%m%d)"
   done
   ```

3. **Check Cluster Health**:
   ```bash
   pvecm status
   ```

#### During Deployment

1. **Monitor Output**: Watch for errors during deployment
2. **One Node at a Time**: For critical systems, deploy sequentially
3. **Verify Each Node**: Check storage status after deployment

#### After Deployment

1. **Verify Installation**:
   ```bash
   for node in pve1 pve2 pve3; do
       ssh root@$node "pvesm status | grep truenas"
   done
   ```

2. **Check Service Status**:
   ```bash
   for node in pve1 pve2 pve3; do
       ssh root@$node "systemctl status pvedaemon pveproxy"
   done
   ```

3. **Test Storage Operations**:
   ```bash
   # Run test suite
   cd tools/
   ./truenas-plugin-test-suite.sh production-storage -y
   ```

4. **Monitor Logs**:
   ```bash
   for node in pve1 pve2 pve3; do
       ssh root@$node "journalctl -u pvedaemon -f" &
   done
   # Ctrl+C to stop monitoring
   ```

### Maintenance Workflows

#### Regular Update Workflow

```bash
# 1. Pull latest plugin version
git pull origin main

# 2. Create backup
for node in pve1 pve2 pve3; do
    ssh root@$node "cp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm \
                        /root/TrueNASPlugin.pm.backup"
done

# 3. Deploy to cluster
cd tools/
./update-cluster.sh pve1 pve2 pve3

# 4. Run tests
./truenas-plugin-test-suite.sh production-storage -y

# 5. Verify on all nodes
for node in pve1 pve2 pve3; do
    ssh root@$node "pvesm status | grep truenas"
done
```

#### Emergency Rollback

```bash
# Rollback to backup on all nodes
for node in pve1 pve2 pve3; do
    echo "Rolling back $node"
    ssh root@$node "cp /root/TrueNASPlugin.pm.backup \
                        /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
    ssh root@$node "systemctl restart pvedaemon pveproxy pvestatd"
done
```

## Summary

### Quick Reference Table

| Tool | Purpose | Location | Documentation |
|------|---------|----------|---------------|
| Test Suite | Automated testing and validation | `tools/truenas-plugin-test-suite.sh` | [Testing Guide](Testing.md) |
| Cluster Update | Deploy plugin to cluster nodes | `tools/update-cluster.sh` | This page |
| Version Check | Check plugin version across cluster | `tools/check-version.sh` | This page |

### Common Tasks

**Check Plugin Version**:
```bash
cd tools/
./check-version.sh pve1 pve2 pve3
```


**Test Plugin Installation**:
```bash
cd tools/
./truenas-plugin-test-suite.sh your-storage-name -y
```

**Deploy to Cluster**:
```bash
cd tools/
./update-cluster.sh pve1 pve2 pve3
```

**Deploy and Test**:
```bash
cd tools/
./update-cluster.sh pve1 pve2 pve3 && \
./truenas-plugin-test-suite.sh production-storage -y
```

## See Also

- [Installation Guide](Installation.md) - Initial plugin installation
- [Testing Guide](Testing.md) - Complete test suite documentation
- [Configuration Reference](Configuration.md) - Storage configuration
- [Troubleshooting Guide](Troubleshooting.md) - Common issues
