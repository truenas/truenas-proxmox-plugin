# TrueNAS Proxmox VE Storage Plugin - Documentation Wiki

Comprehensive documentation for the TrueNAS Proxmox VE Storage Plugin.

## Documentation Index

### Getting Started
- **[Installation Guide](Installation.md)** - Complete installation instructions for Proxmox VE and TrueNAS SCALE, including single-node and cluster deployments

### Configuration
- **[Configuration Reference](Configuration.md)** - Complete reference for all configuration parameters with examples for different use cases

### Testing and Validation
- **[Testing Guide](Testing.md)** - Comprehensive guide for using the automated test suite to validate plugin functionality
- **[Tools and Utilities](Tools.md)** - Test suite and cluster deployment script documentation

### Operations
- **[Troubleshooting Guide](Troubleshooting.md)** - Common issues, error messages, and solutions with detailed diagnostic steps

### Advanced Topics
- **[Advanced Features](Advanced-Features.md)** - Performance tuning, cluster configuration, security hardening, and enterprise features
- **[API Reference](API-Reference.md)** - Technical details on TrueNAS API integration, endpoints, and error handling

### Development
- **[Ideas and Feature Requests](Ideas.md)** - Proposed features, enhancements, and development roadmap
- **[Changelog](Changelog.md)** - Version history and release notes

### Important Information
- **[Known Limitations](Known-Limitations.md)** - Critical limitations, restrictions, and workarounds you should know

## Quick Links

### Common Tasks

**Installation**:
- [Single Node Setup](Installation.md#single-node-installation)
- [Cluster Deployment](Installation.md#cluster-installation)
- [TrueNAS Configuration](Installation.md#truenas-scale-setup)

**Testing**:
- [Running Test Suite](Testing.md#basic-usage)
- [Understanding Test Results](Testing.md#interpreting-results)
- [Performance Benchmarking](Testing.md#performance-benchmarking)

**Tools**:
- [Test Suite](Tools.md#test-suite)
- [Health Check Tool](Tools.md#health-check-tool)
- [Diagnostics Bundle](Tools.md#diagnostics-bundle)
- [Orphan Cleanup Tool](Tools.md#orphan-cleanup-tool)
- [Cluster Update Script](Tools.md#cluster-update-script)
- [Version Check Script](Tools.md#version-check-script)
- [Deployment Automation](Tools.md#integration-with-cicd)

**Configuration**:
- [Required Parameters](Configuration.md#required-parameters)
- [Basic Configuration Example](Configuration.md#basic-single-node-configuration)
- [Production Cluster Example](Configuration.md#production-cluster-configuration)

**Troubleshooting**:
- [Storage Shows Inactive](Troubleshooting.md#storage-shows-as-inactive)
- [iSCSI Connection Issues](Troubleshooting.md#iscsi-discovery-and-connection-issues)
- [VM Deletion Orphans](Troubleshooting.md#orphaned-volumes-after-vm-deletion)

**Performance**:
- [ZFS Block Size Optimization](Advanced-Features.md#zfs-block-size-optimization)
- [Network Optimization](Advanced-Features.md#network-optimization)
- [Multipath I/O](Advanced-Features.md#multipath-io-mpio)

**Security**:
- [CHAP Authentication](Advanced-Features.md#chap-authentication)
- [API Security](Advanced-Features.md#api-security)
- [Network Security](Advanced-Features.md#network-security)

## Documentation Structure

```
wiki/
├── README.md                   # This file - documentation index
├── Installation.md             # Installation and setup guide
├── Configuration.md            # Configuration reference
├── Testing.md                  # Test suite usage and validation
├── Tools.md                    # Tools and utilities (test suite, health check, diagnostics bundle, orphan cleanup, cluster deployment)
├── Troubleshooting.md          # Common issues and solutions
├── Advanced-Features.md        # Performance, clustering, security
├── API-Reference.md            # TrueNAS API technical details
├── Ideas.md                    # Feature ideas and development roadmap
├── Changelog.md                # Version history and release notes
└── Known-Limitations.md        # Important limitations
```

## Documentation Conventions

### Code Blocks

**Bash Commands**:
```bash
# Commands to run on Proxmox nodes
pvesm status
```

**Configuration Files**:
```ini
# /etc/pve/storage.cfg
truenasplugin: storage-name
    api_host 192.168.1.100
```

**Example Output**:
```
Expected output from commands
```

### Admonitions

**✅ Recommended**: Best practices and recommended approaches

**❌ Not Recommended**: Approaches to avoid

**⚠️ Warning**: Important warnings and cautions

**💡 Tip**: Helpful tips and tricks

### File Paths

Absolute paths are shown for all files:
- Proxmox: `/etc/pve/storage.cfg`, `/usr/share/perl5/PVE/Storage/Custom/`
- TrueNAS: `/var/log/middlewared.log`, `/mnt/tank/proxmox`

### Placeholders

Replace these placeholders with your actual values:
- `YOUR_TRUENAS_IP` - Your TrueNAS IP address
- `YOUR_API_KEY` - Your TrueNAS API key
- `VMID` - Proxmox VM ID number
- `your-storage-name` - Your storage identifier

## Contributing to Documentation

Found an error or want to improve documentation?
1. Check existing content for accuracy
2. Ensure examples are tested and working
3. Follow existing formatting conventions
4. Keep explanations clear and concise

## Support

For issues not covered in documentation:
1. Review all relevant documentation sections
2. Check [Known Limitations](Known-Limitations.md)
3. Search existing GitHub issues
4. Create new GitHub issue with detailed information

## Version Information

**Version**: 2.0.1
**Last Updated**: February 3, 2026
**Compatibility**: Proxmox VE 8.x+, TrueNAS SCALE 25.10+
