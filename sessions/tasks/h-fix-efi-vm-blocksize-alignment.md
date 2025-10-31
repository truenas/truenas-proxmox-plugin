---
name: h-fix-efi-vm-blocksize-alignment
branch: fix/h-fix-efi-vm-blocksize-alignment
status: pending
created: 2025-10-31
---

# Fix EFI VM Creation - Volume Block Size Alignment

## Problem/Goal
When users create EFI-based VMs in Proxmox, the VM creation fails with a TrueNAS validation error: "Volume size should be a multiple of volume block size".

This occurs because Proxmox requests a 528KB (540672 bytes) EFI disk, but when the TrueNAS storage is configured with a `zvol_blocksize` of 128KB, TrueNAS rejects the allocation since 528KB is not evenly divisible by 128KB.

The plugin needs to automatically round up requested disk sizes to the nearest multiple of the configured `volblocksize` before creating volumes on TrueNAS.

## Success Criteria
- [ ] EFI VM creation succeeds - Users can create UEFI/OVMF VMs without encountering "Volume size should be a multiple of volume block size" errors
- [ ] Size alignment is automatic - The plugin transparently rounds up disk sizes to the nearest `volblocksize` multiple without user intervention
- [ ] Works with all block sizes - Solution handles common block sizes (16K, 32K, 64K, 128K) correctly
- [ ] Logging indicates alignment - When size adjustment occurs, plugin logs the original and aligned sizes for troubleshooting
- [ ] No regression on standard disks - Regular VM disk allocation (1GB, 10GB, etc.) continues to work normally

## Context Manifest

### How Volume Creation Currently Works

When Proxmox creates a VM disk (including EFI disks), it calls the `alloc_image` function in TrueNASPlugin.pm (line 1990). This function receives the requested size in **KiB (kibibytes)** from Proxmox, not bytes. For an EFI disk, Proxmox requests exactly **528 KiB** (which equals 540,672 bytes).

The current flow in `alloc_image`:

1. **Size Conversion (line 2001)**: The function immediately converts the KiB value to bytes with a simple multiplication: `my $bytes = int($size_kib) * 1024;`. For a 528 KiB EFI disk, this produces 540,672 bytes.

2. **Pre-flight Checks (lines 2007-2019)**: The converted byte value is passed to `_preflight_check_alloc()` which validates API connectivity, iSCSI service status, available space (with 20% overhead), target existence, and parent dataset existence. This validation happens BEFORE any expensive operations.

3. **Disk Name Selection (lines 2021-2047)**: The function either uses a provided disk name or auto-generates one by iterating through `vm-<vmid>-disk-0` through `vm-<vmid>-disk-999` until finding an available name.

4. **ZVol Creation Payload (lines 2051-2061)**: The critical section where the problem occurs:
   ```perl
   my $blocksize = $scfg->{zvol_blocksize};  # e.g., "128K" from storage.cfg

   my $create_payload = {
       name    => $full_ds,
       type    => 'VOLUME',
       volsize => $bytes,  # 540672 for EFI disk - NOT aligned!
       sparse  => ($scfg->{tn_sparse} // 1) ? JSON::PP::true : JSON::PP::false,
   };
   $create_payload->{volblocksize} = $blocksize if $blocksize;
   ```

5. **TrueNAS API Call (lines 2063-2068)**: The payload is sent to TrueNAS via `pool.dataset.create` (WebSocket) or `/pool/dataset` (REST POST). **This is where the error occurs** - TrueNAS middleware validates that volsize must be a multiple of volblocksize.

The problem: The plugin sends `volsize: 540672` and `volblocksize: "128K"` (131,072 bytes). TrueNAS validation checks if 540,672 is divisible by 131,072. It's not (540,672 ÷ 131,072 = 4.125), so TrueNAS rejects the request with:
```
[EINVAL] pool_dataset_create.volsize: Volume size should be a multiple of volume block size
```

### How volblocksize is Configured and Used

**Configuration Storage**: The `zvol_blocksize` parameter is defined in the plugin schema (line 249-252) as an optional string property. Users configure it in `/etc/pve/storage.cfg`:
```ini
truenasplugin: my-storage
    zvol_blocksize 128K
```

**Storage in $scfg**: When Proxmox loads the storage configuration, the `zvol_blocksize` value is stored directly in the `$scfg` hashref as a string (e.g., "128K", "64K", "16K"). It's accessed via `$scfg->{zvol_blocksize}`.

**String Format**: The blocksize is stored in human-readable format matching ZFS conventions:
- Valid values: "4K", "8K", "16K", "32K", "64K", "128K", "256K", "512K", "1M"
- Most common for VMs: "128K" (recommended in documentation)
- The plugin passes this string directly to TrueNAS API without conversion

**TrueNAS API Handling**: TrueNAS accepts volblocksize as a string (e.g., "128K") in the create payload, but internally converts it to bytes for validation. The API response returns volblocksize as:
```json
{
  "volblocksize": {
    "parsed": 131072,     // bytes as integer
    "rawvalue": "131072", // bytes as string
    "value": "128K"       // human-readable format
  }
}
```

**Retrieving Existing Values**: When querying existing zvols via `_tn_dataset_get()`, the plugin uses a normalizer function to extract the numeric byte value from the nested structure:
```perl
my $bs_bytes = $norm->($ds->{volblocksize});  // Extracts 131072 from the hash structure
```

This normalizer pattern (seen in `volume_resize` at line 1298 and elsewhere) handles:
- Scalar values (returns as-is)
- Hash structures with `{parsed}` key (returns numeric bytes)
- Hash structures with `{raw}` key (fallback)
- Undefined/missing values (returns 0)

**Key Insight**: While the plugin passes blocksize as a string to TrueNAS during creation, it must convert blocksize to bytes for **alignment calculations** before sending volsize.

### TrueNAS API Alignment Requirements

The error trace from `openspec/errors.md` shows the exact validation failure from TrueNAS middleware (file `/usr/lib/python3/dist-packages/middlewared/plugins/pool_/dataset.py`, line 590):

```python
verrors.check()  # Raises ValidationErrors if volsize not aligned to volblocksize
```

**TrueNAS Validation Rules**:
1. The `volsize` parameter MUST be an exact multiple of `volblocksize`
2. Validation happens server-side in TrueNAS middleware BEFORE creating the zvol
3. Error returned: `[EINVAL] pool_dataset_create.volsize: Volume size should be a multiple of volume block size` (error code 22)

**Real-World Example from Error**:
- Requested: `volsize: 540672, volblocksize: '128K'`
- 128K in bytes: 131,072
- Division: 540,672 ÷ 131,072 = 4.125 (NOT an integer)
- Result: Validation failure

**Correct Alignment**:
- 540,672 bytes needs to round UP to next 128K boundary
- Next multiple: 131,072 × 5 = 655,360 bytes
- This would be accepted by TrueNAS

**Why Rounding Up is Required**: ZFS zvols are block-based storage. The volblocksize defines the fundamental block unit. A volume size that isn't a perfect multiple would leave a partial block at the end, which ZFS cannot handle. TrueNAS enforces this at the API layer to prevent ZFS errors.

### Existing Alignment Logic: volume_resize as Reference

The plugin ALREADY implements this exact alignment logic in `volume_resize()` (lines 1307-1311):

```perl
# Align up to volblocksize to avoid middleware alignment complaints
if ($bs_bytes && $bs_bytes > 0) {
    my $rem = $req_bytes % $bs_bytes;
    $req_bytes += ($bs_bytes - $rem) if $rem;
}
```

**How it Works**:
1. Get current zvol's volblocksize in bytes from TrueNAS via `_tn_dataset_get()`: `my $bs_bytes = $norm->($ds->{volblocksize});`
2. Calculate remainder: `my $rem = $req_bytes % $bs_bytes;`
3. If remainder exists, add the difference to round up: `$req_bytes += ($bs_bytes - $rem) if $rem;`

**Example Calculation** (for 128K blocksize):
- Requested: 540,672 bytes
- Blocksize: 131,072 bytes
- Remainder: 540,672 % 131,072 = 16,384
- Adjustment: 131,072 - 16,384 = 114,688
- Aligned size: 540,672 + 114,688 = 655,360 bytes ✓
- Verification: 655,360 ÷ 131,072 = 5 (perfect multiple)

This same logic needs to be applied in `alloc_image()`, but there's a critical difference: In `volume_resize()`, the blocksize comes from the **existing zvol's properties** queried from TrueNAS. In `alloc_image()`, we're creating a NEW zvol, so the blocksize must come from **$scfg configuration** instead.

### The Critical Difference: String vs. Bytes

In `volume_resize()`, the blocksize is retrieved as bytes from TrueNAS:
```perl
my $ds = _tn_dataset_get($scfg, $full);  # Query existing zvol
my $bs_bytes = $norm->($ds->{volblocksize});  # Returns 131072 for "128K"
```

In `alloc_image()`, we only have the configuration string:
```perl
my $blocksize = $scfg->{zvol_blocksize};  # Returns "128K" as string
```

**Solution Required**: We need a helper function to parse the blocksize string ("128K") and convert it to bytes (131,072) so we can perform the same modulo-based alignment calculation.

### Parsing Blocksize Strings to Bytes

The blocksize format follows ZFS conventions: `<number><unit>` where unit is optional and can be K, M, or G.

**Parsing Logic**:
```perl
sub _parse_blocksize {
    my ($bs_str) = @_;
    return 0 if !defined $bs_str || $bs_str eq '';

    # Match: number followed by optional K/M/G suffix
    if ($bs_str =~ /^(\d+)([KMG])?$/) {
        my ($num, $unit) = ($1, $2 // '');
        my $bytes = int($num);
        $bytes *= 1024 if $unit eq 'K';
        $bytes *= 1024 * 1024 if $unit eq 'M';
        $bytes *= 1024 * 1024 * 1024 if $unit eq 'G';
        return $bytes;
    }
    return 0;  # Invalid format
}
```

**Example Conversions**:
- "128K" → 131,072 bytes
- "64K" → 65,536 bytes
- "16K" → 16,384 bytes
- "1M" → 1,048,576 bytes

### Proxmox EFI Disk Size Calculation

Proxmox has hardcoded EFI disk sizes in its VM creation logic. When creating a UEFI/OVMF VM, Proxmox automatically allocates an EFI variables disk.

**Standard EFI Sizes** (from Proxmox source code):
- **Default EFI disk**: 528 KiB (540,672 bytes)
- This size is NOT user-configurable in the standard VM creation flow
- The size is defined in Proxmox's hardware configuration modules

**Why 528 KiB?**
- UEFI firmware variable storage requires specific size for compatibility
- OVMF (Open Virtual Machine Firmware) expects this specific allocation
- Size accommodates UEFI variable storage, boot entries, and security databases

**Impact on Plugin**: Since users cannot change the EFI disk size, the plugin MUST handle 528 KiB alignment transparently. With common blocksizes:
- 16K: 540,672 is NOT aligned (would need 544,768 = 16K × 33)
- 64K: 540,672 is NOT aligned (would need 655,360 = 64K × 10)
- 128K: 540,672 is NOT aligned (would need 655,360 = 128K × 5)

The alignment is required for ALL common block sizes when creating EFI VMs.

### Impact on volume_resize Function

The `volume_resize` function (lines 1280-1351) ALREADY implements proper alignment (lines 1307-1311). No changes needed there.

**Why volume_resize is Safe**:
1. It queries the existing zvol to get current volblocksize: `my $bs_bytes = $norm->($ds->{volblocksize});`
2. Applies the same rounding-up logic: `$req_bytes += ($bs_bytes - $rem) if $rem;`
3. This logic was added specifically to handle resize alignment (confirmed by comment at line 1307)

**Consistency Check**: After fixing `alloc_image`, both functions will use identical alignment logic. The only difference is the source of blocksize:
- `alloc_image`: From `$scfg->{zvol_blocksize}` (parsed from string)
- `volume_resize`: From existing zvol properties (already in bytes)

### Testing Considerations

**Test Cases by Block Size**:
1. **16K blocks**: 540,672 → 544,768 bytes (16K × 33)
2. **64K blocks**: 540,672 → 655,360 bytes (64K × 10)
3. **128K blocks**: 540,672 → 655,360 bytes (128K × 5)
4. **Standard disks (1GB)**: 1,073,741,824 is already aligned to all common blocksizes

**Verification Steps**:
1. Configure storage with different blocksizes (16K, 64K, 128K)
2. Create EFI-based VM (OVMF/UEFI firmware)
3. Verify VM creation succeeds without alignment errors
4. Check TrueNAS GUI shows properly aligned zvol size
5. Verify logs show original vs. aligned size when adjustment occurs

**Testing via SSH** (from CLAUDE.md requirements):
```bash
# On Proxmox test node 10.15.14.195
qm create 200 --name test-efi --memory 2048 --bios ovmf --efidisk0 my-storage:1
# Should succeed instead of failing with alignment error
```

**Log Message Format** (for troubleshooting):
The implementation should log when size alignment occurs:
```
alloc_image: size alignment: requested 540672 bytes → aligned 655360 bytes (volblocksize: 128K)
```

This helps users understand why allocated size differs from requested size.

### Implementation Location and Approach

**File**: `/home/warlock/Documents/Coding/pve/truenasplugin/TrueNASPlugin.pm`

**Functions to Modify**:
1. **Add new helper** (after line 87, near `_format_bytes`):
   - Function: `_parse_blocksize($blocksize_str)`
   - Purpose: Convert "128K" → 131072 bytes
   - Returns: Integer bytes, or 0 if invalid/undefined

2. **Modify `alloc_image`** (around line 2001-2004):
   - Current: Direct conversion `my $bytes = int($size_kib) * 1024;`
   - New: Add alignment logic after conversion, before pre-flight check
   - Parse blocksize string to bytes
   - Apply modulo-based rounding (same as volume_resize)
   - Log adjustment if size changes

**Pseudocode for alloc_image Changes**:
```perl
# After line 2001: my $bytes = int($size_kib) * 1024;
# Add:

# Parse configured blocksize to bytes for alignment
my $bs_bytes = _parse_blocksize($scfg->{zvol_blocksize});

# Align to volblocksize if configured (mirrors volume_resize logic)
if ($bs_bytes && $bs_bytes > 0) {
    my $original_bytes = $bytes;
    my $rem = $bytes % $bs_bytes;
    if ($rem) {
        $bytes += ($bs_bytes - $rem);
        _log($scfg, 1, 'info', sprintf(
            "alloc_image: size alignment: requested %d bytes → aligned %d bytes (volblocksize: %s)",
            $original_bytes, $bytes, $scfg->{zvol_blocksize}
        ));
    }
}
```

**Placement Strategy**:
- Parse and align AFTER basic validation (line 1998-1999) but BEFORE pre-flight check (line 2007)
- This ensures aligned size is used for space calculations in pre-flight
- Maintains existing code structure and logging patterns

**No Changes Needed**:
- Pre-flight check: Already uses $bytes variable, will automatically validate aligned size
- Dataset creation: Already uses $bytes for volsize in payload
- Error handling: Existing error messages remain appropriate
- volume_resize: Already has correct alignment logic

### Edge Cases and Considerations

1. **No blocksize configured** (`zvol_blocksize` not set in storage.cfg):
   - Behavior: Skip alignment (TrueNAS uses default blocksize)
   - Logic: `if ($bs_bytes && $bs_bytes > 0)` handles this

2. **Already-aligned sizes** (e.g., 1GB disk with 128K blocks):
   - 1,073,741,824 % 131,072 = 0 (no remainder)
   - Adjustment: None (bytes unchanged)
   - No performance penalty for standard sizes

3. **Invalid blocksize format** in config:
   - Parser returns 0
   - Alignment skipped (same as unconfigured)
   - Volume creation proceeds (TrueNAS validation will catch actual invalid values)

4. **Very small disks** (smaller than blocksize):
   - Example: 64K disk with 128K blocksize
   - Rounds up to 128K (minimum allocatable)
   - This is correct ZFS behavior

5. **Logging overhead**:
   - Only logs when adjustment occurs (when $rem > 0)
   - Standard 1GB+ disks won't trigger log message (already aligned)
   - Debug level 1 (light) appropriate for size adjustments

### Related Code Patterns

**Normalizer Pattern** (used throughout for TrueNAS API responses):
```perl
my $norm = sub {
    my ($v) = @_;
    return 0 if !defined $v;
    return $v if !ref($v);
    return $v->{parsed} // $v->{raw} // 0 if ref($v) eq 'HASH';
    return 0;
};
```
Seen at: lines 1290-1296, 1598-1603, 2249-2255, 2562-2567

**Logging Pattern**:
```perl
_log($scfg, $level, $priority, $message);
# $level: 0=always, 1=light debug, 2=verbose debug
# $priority: 'err', 'warning', 'info', 'debug'
```

**Error Handling Pattern**: Die with detailed troubleshooting context (see extensive error messages throughout file)

### File Paths Reference

- **Main implementation**: `/home/warlock/Documents/Coding/pve/truenasplugin/TrueNASPlugin.pm`
- **Configuration file**: `/etc/pve/storage.cfg` (on Proxmox node)
- **Error documentation**: `/home/warlock/Documents/Coding/pve/truenasplugin/openspec/errors.md`
- **Testing docs**: `/home/warlock/Documents/Coding/pve/truenasplugin/wiki/Testing.md`
- **Configuration docs**: `/home/warlock/Documents/Coding/pve/truenasplugin/wiki/Configuration.md`

### Success Criteria Mapping

1. **EFI VM creation succeeds**: Alignment logic rounds 540,672 → 655,360 (128K blocks), satisfying TrueNAS validation
2. **Automatic size alignment**: Happens transparently in alloc_image before API call
3. **Works with all block sizes**: Parser handles 16K, 32K, 64K, 128K, 256K, 512K, 1M
4. **Logging indicates alignment**: Info-level log when size adjusted (debug level 1)
5. **No regression on standard disks**: 1GB+ sizes already aligned, skip adjustment (no remainder)

## User Notes
<!-- Any specific notes or requirements from the developer -->

## Work Log
<!-- Updated as work progresses -->
- [YYYY-MM-DD] Started task, initial research
