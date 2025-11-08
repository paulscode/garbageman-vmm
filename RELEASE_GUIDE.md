# GitHub Release Guide

This guide explains how to create GitHub releases with pre-synced blockchain data and both Garbageman and Bitcoin Knots implementations using the **unified export format**.

## Why Create Releases?

- Let users skip the 24-48 hour blockchain sync
- Share pre-synced blockchain at specific block heights
- Provide both Garbageman and Bitcoin Knots implementations in one release
- Include both VM and container deployment options
- Enable quick deployment for new users
- Modular format: blockchain separate from images, all files under GitHub's 2GB limit

## Prerequisites

## Prerequisites

Before starting the release process, ensure you have:

- **TUI script**: The `garbageman-nm.sh` Terminal User Interface (TUI) script tested and working
- **Disk space**: ~75-100GB free (temporary, reclaim after assembly)
- **Time**: 4-6 hours (or 2-3 days if syncing blockchain from scratch)
- **Previous release**: Download from GitHub (for blockchain catchup import)
- **Git configured**: Access to push tags to repository
- **GitHub access**: Ability to create releases and upload files

## Unified Export System

The unified export system keeps all release assets together in a single folder:

**Release Components:**
1. **Blockchain data** - Split into 1.9GB parts (blockchain.tar.gz.part01, part02, etc.)
2. **Garbageman binaries** - `bitcoind-gm` and `bitcoin-cli-gm`
3. **Bitcoin Knots binaries** - `bitcoind-knots` and `bitcoin-cli-knots`
4. **Container image** - Alpine Linux container with dependencies (~200MB)
5. **VM image** - Alpine Linux VM with dependencies (~400MB)
6. **SHA256SUMS** - Checksums for all files
7. **MANIFEST.txt** - Export metadata and instructions

**Benefits:**
- Users choose their preferred implementation (Garbageman or Knots)
- Users choose their preferred deployment method (Container or VM)
- Blockchain shared across all combinations
- All files stay under GitHub's 2GB limit
- Simple folder structure - all files in one place

## Release Creation Process Overview

Creating a release involves building both Garbageman and Knots from source, one in a container, and one in a VM, then combining everything with a synced blockchain:

**Phase 1: Build Garbageman Container**
1. TUI → Container mode → Build Garbageman from scratch
2. Export → Get `container-image.tar.gz`, `bitcoind`, `bitcoin-cli`, checksums

**Phase 2: Build Bitcoin Knots VM**
1. Delete base container, restart TUI
2. TUI → VM mode → Build Bitcoin Knots from scratch
3. Export → Get `vm-image.tar.gz`, `bitcoind`, `bitcoin-cli`, checksums

**Phase 3: Sync Blockchain**
1. Delete base VM, restart TUI
2. TUI → Container mode → Import previous release from GitHub
3. Replace container-image.tar.gz with the one from Phase 1
4. Import from file
5. Wait for blockchain sync to catch up (10-20 minutes)
6. Export

**Phase 4: Assemble Release**
1. Combine all components:
    - Blockchain parts from Phase 3
    - Container image from Phase 1
    - VM image from Phase 2
    - Rename binaries: `bitcoind` → `bitcoind-gm` / `bitcoind-knots`
    - Rename binaries: `bitcoin-cli` → `bitcoin-cli-gm` / `bitcoin-cli-knots`
    - Update SHA256SUMS with all checksums

**Phase 5: Create Git Tag**
1. Get block height from MANIFEST.txt
2. Create annotated tag with block height
3. Push tag to GitHub

**Phase 6: Upload to GitHub**
1. Draft new release on GitHub
2. Select your tag
3. Write descriptive release notes
4. Upload all files from final-release-export/
5. Publish release

**Phase 7: Verify Release**
1. Test Container + Garbageman import
2. Test VM + Bitcoin Knots import
3. Verify instances work correctly

**Time estimate:** 4-6 hours (unless starting sync from scratch)

### Phase 1: Build Garbageman Container and Export

This phase creates the Garbageman implementation container image and binaries.

```bash
# 1. Start TUI script
./garbageman-nm.sh

# 2. First run: Choose Container mode
# (If already configured for VMs, you'll need to delete gm-base and reconfigure)
# Note: "gm-base" is the name of the master template container/VM from which you clone instances

# 3. Create Base Container
# Menu: Option 1 → Build from Scratch
# Implementation: Choose Garbageman
# Wait: ~2 hours for compilation

# 4. Export the container
# Menu: Option 3 → Manage Base → Export
# Select: Image-only export (no blockchain yet)
# Output: ~/Downloads/gm-export-YYYYMMDD-HHMMSS/
# (YYYYMMDD-HHMMSS is a timestamp like 20251107-143022)
```

**Files created:**
- `container-image.tar.gz` - Garbageman container (~200MB)
- `bitcoind` - Garbageman daemon binary
- `bitcoin-cli` - Garbageman CLI binary
- `SHA256SUMS` - Checksums for above files
- `MANIFEST.txt` - Export metadata

**Save these files** - you'll need them later. Rename the export folder:
```bash
**This folder will be used in Phase 4** - rename it for clarity:
```bash
mv ~/Downloads/gm-export-YYYYMMDD-HHMMSS ~/Downloads/garbageman-container-export
# Replace YYYYMMDD-HHMMSS with your actual timestamp
```
```

### Phase 2: Build Bitcoin Knots VM and Export

This phase creates the Bitcoin Knots implementation VM image and binaries.

```bash
# 1. Delete the Garbageman base container
./garbageman-nm.sh
# Menu: Option 3 → Manage Base → Delete

# 2. Exit and restart TUI to reconfigure
exit  # This exits the TUI script back to your shell
./garbageman-nm.sh

# 3. First run: Choose VM mode
# The script will reconfigure for VM deployment

# 4. Create Base VM
# Menu: Option 1 → Build from Scratch
# Implementation: Choose Bitcoin Knots
# Wait: ~2 hours for compilation

# 5. Export the VM
# Menu: Option 3 → Manage Base → Export
# Select: Image-only export (no blockchain yet)
# Output: ~/Downloads/gm-export-YYYYMMDD-HHMMSS/
# (Timestamp will be different from Phase 1)
```

**Files created:**
- `vm-image.tar.gz` - Bitcoin Knots VM (~400MB)
- `bitcoind` - Bitcoin Knots daemon binary
- `bitcoin-cli` - Bitcoin Knots CLI binary
- `SHA256SUMS` - Checksums for above files
- `MANIFEST.txt` - Export metadata

**Save these files** - rename the export folder:
```bash
mv ~/Downloads/gm-export-YYYYMMDD-HHMMSS ~/Downloads/knots-vm-export
# Replace YYYYMMDD-HHMMSS with your actual timestamp (different from Phase 1)
```

### Phase 3: Sync Blockchain with Latest Release

This phase syncs the blockchain from the previous release to current height (typically 10-20 minutes catchup).

**Note:** If you're creating the very first release or don't have a recent previous release, this will take 24-48 hours for a full sync from scratch.

```bash
# 1. Delete the Bitcoin Knots base VM
./garbageman-nm.sh
# Menu: Option 3 → Manage Base → Delete

# 2. Exit and restart TUI to reconfigure
exit  # This exits the TUI script back to your shell
./garbageman-nm.sh

# 3. First run: Choose Container mode again
# Back to container deployment

# 4. Download previous release from GitHub manually
# Go to: https://github.com/paulscode/garbageman-nm/releases
# Download the latest release files to ~/Downloads/previous-release/
#   - All blockchain.tar.gz.part* files
#   - container-image.tar.gz (we'll replace this)
#   - SHA256SUMS
#   - MANIFEST.txt

# 5. Replace container image with fresh Garbageman build
cd ~/Downloads/previous-release/
rm container-image.tar.gz
cp ~/Downloads/garbageman-container-export/container-image.tar.gz .

# Also update the checksum
# Remove old container-image.tar.gz line from SHA256SUMS
# Add new checksum:
grep container-image.tar.gz ~/Downloads/garbageman-container-export/SHA256SUMS >> SHA256SUMS

# 6. Import this modified release
./garbageman-nm.sh
# Menu: Option 1 → Import from File
# Navigate to: ~/Downloads/previous-release/
# Wait: 5-10 minutes for import and assembly

# 7. Start the container and monitor sync
# Menu: Option 2 → Monitor Base Sync
# Wait: 10-20 minutes for blockchain to sync to current height
# The script shows live progress - you can exit the TUI and check back later
# (Type 'exit' or Ctrl+D to exit, run ./garbageman-nm.sh again to check progress)

# 8. When sync is complete (100%), export with blockchain
./garbageman-nm.sh
# Menu: Option 3 → Manage Base → Export
# Select: Full export (with blockchain)
# Wait: 10-20 minutes for blockchain extraction and splitting
# Output: ~/Downloads/gm-export-YYYYMMDD-HHMMSS/
```

**Files created:**
- `blockchain.tar.gz.part01` through `part11` (or part12) - ~20GB total
- `container-image.tar.gz` - Garbageman container
- `bitcoind` - Garbageman daemon binary
- `bitcoin-cli` - Garbageman CLI binary
- `SHA256SUMS` - Checksums for all above files
- `MANIFEST.txt` - Export metadata with block height

**This is your main export folder** - rename it for clarity:
```bash
mv ~/Downloads/gm-export-YYYYMMDD-HHMMSS ~/Downloads/final-release-export
# Replace YYYYMMDD-HHMMSS with your actual timestamp (different from Phases 1 & 2)
```

### Phase 4: Assemble Complete Release Package

Now combine all the pieces into a single release folder with both implementations.

```bash
cd ~/Downloads/final-release-export

# 1. Remove the generic bitcoind/bitcoin-cli files
# (These are Garbageman from the sync container)
rm bitcoind bitcoin-cli

# 2. Copy in Garbageman binaries with proper names
cp ~/Downloads/garbageman-container-export/bitcoind ./bitcoind-gm
cp ~/Downloads/garbageman-container-export/bitcoin-cli ./bitcoin-cli-gm

# 3. Copy in Bitcoin Knots binaries with proper names
cp ~/Downloads/knots-vm-export/bitcoind ./bitcoind-knots
cp ~/Downloads/knots-vm-export/bitcoin-cli ./bitcoin-cli-knots

# 4. Copy in the VM image
cp ~/Downloads/knots-vm-export/vm-image.tar.gz .

# 5. Update SHA256SUMS file
# Remove old bitcoind and bitcoin-cli checksums
sed -i '/^[^ ]* *bitcoind$/d' SHA256SUMS
sed -i '/^[^ ]* *bitcoin-cli$/d' SHA256SUMS

# Add Garbageman binary checksums
sha256sum bitcoind-gm >> SHA256SUMS
sha256sum bitcoin-cli-gm >> SHA256SUMS

# Add Bitcoin Knots binary checksums
sha256sum bitcoind-knots >> SHA256SUMS
sha256sum bitcoin-cli-knots >> SHA256SUMS

# Add VM image checksum
sha256sum vm-image.tar.gz >> SHA256SUMS

# 6. Verify all checksums are correct
sha256sum -c SHA256SUMS
# All files should show "OK"
```

**Final release folder contents:**
```
~/Downloads/final-release-export/
├── blockchain.tar.gz.part01
├── blockchain.tar.gz.part02
├── ... (part03 through part11 or part12)
├── container-image.tar.gz
├── vm-image.tar.gz
├── bitcoind-gm
├── bitcoin-cli-gm
├── bitcoind-knots
├── bitcoin-cli-knots
├── SHA256SUMS
└── MANIFEST.txt
```

### Phase 5: Create Git Tag and GitHub Release

Now publish your release to GitHub.

```bash
# 1. Check the block height from MANIFEST.txt
cat ~/Downloads/final-release-export/MANIFEST.txt | grep "Block Height"
# Example output: Block Height: 921348

# 2. Create annotated git tag
BLOCK_HEIGHT=921348  # Use actual height from MANIFEST.txt
git tag -a v2025.11.07 -m "Release v2025.11.07 - Block height $BLOCK_HEIGHT"

# 3. Push tag to GitHub
git push origin v2025.11.07
```

### Phase 6: Upload to GitHub

1. **Go to releases page:**
   ```
   https://github.com/paulscode/garbageman-nm/releases
   ```

2. **Click "Draft a new release"**

3. **Select your tag:**
   - Choose the tag you just pushed (e.g., `v2025.11.07`)

4. **Fill in release details:**

   **Release title example:**
   ```
   v2025.11.07 - Garbageman + Knots, VM + Container, Block 921348
   ```

   **Description example:**
   ```markdown
   ## Dual-Implementation Pre-Synced Release
   
   This release includes both **Garbageman** and **Bitcoin Knots** implementations, with support for both **Container** and **VM** deployments.
   
   **Blockchain Status:**
   - Block height: 921,348
   - Export date: 2025-11-07
   - Blockchain size: ~20GB compressed (pruned to 550MB)
   
   **What's Included:**
   - ✅ Pre-synced blockchain (shared across all combinations)
   - ✅ Garbageman binaries (bitcoind-gm, bitcoin-cli-gm)
   - ✅ Bitcoin Knots binaries (bitcoind-knots, bitcoin-cli-knots)
   - ✅ Container image (~200MB) - Alpine Linux + dependencies
   - ✅ VM image (~400MB) - Alpine Linux + dependencies
   - ✅ SHA256SUMS for integrity verification
   
   **Deployment Combinations:**
   - Garbageman in Container (recommended for most users)
   - Garbageman in VM
   - Bitcoin Knots in Container
   - Bitcoin Knots in VM
   
   ## How to Use
   
   ### Automatic Import via TUI (Recommended)
   
   ```bash
   ./garbageman-nm.sh
   
   # First run: Choose Container or VM mode
   # Then: Option 1 → Import from GitHub → Select this release
   # Choose: Garbageman or Bitcoin Knots
   ```
   
   The script automatically:
   - Downloads blockchain parts + image + binaries
   - Verifies all checksums
   - Assembles and imports
   - You're ready to start in minutes!
   
   ### Manual Download and Import
   
   **Download all files:**
   - All `blockchain.tar.gz.part*` files (11-12 parts)
   - `container-image.tar.gz` OR `vm-image.tar.gz` (or both)
   - `bitcoind-gm` + `bitcoin-cli-gm` (for Garbageman)
   - `bitcoind-knots` + `bitcoin-cli-knots` (for Bitcoin Knots)
   - `SHA256SUMS`
   - `MANIFEST.txt`
   
   **Verify and import:**
   ```bash
   # Create folder for download
   mkdir ~/Downloads/gm-release-v2025.11.07
   cd ~/Downloads/gm-release-v2025.11.07
   
   # Move all downloaded files here
   mv ~/Downloads/blockchain.tar.gz.part* .
   mv ~/Downloads/container-image.tar.gz .  # or vm-image.tar.gz
   mv ~/Downloads/bitcoind-* .
   mv ~/Downloads/bitcoin-cli-* .
   mv ~/Downloads/SHA256SUMS .
   mv ~/Downloads/MANIFEST.txt .
   
   # Verify integrity
   sha256sum -c SHA256SUMS
   # All files should show "OK"
   
   # Import via TUI
   ./garbageman-nm.sh
   # Option 1 → Import from File
   # Navigate to ~/Downloads/gm-release-v2025.11.07/
   # Choose implementation when prompted
   ```
   
   ## Implementation Differences
   
   **Garbageman (bitcoind-gm):**
   - Advertises NODE_LIBRE_RELAY flag
   - Acts as honeypot against spam relay network
   - Silently drops spam while relaying legitimate transactions
   - Best for: Fighting spam, supporting network health
   
   **Bitcoin Knots (bitcoind-knots):**
   - Aggressive common-sense spam filtering
   - Does not advertise NODE_LIBRE_RELAY
   - Conservative relay policy
   - Best for: General node operation, predictable behavior
   
   ## Files in This Release
   
   | File | Size | Purpose |
   |------|------|---------|
   | blockchain.tar.gz.part01-11 (or 12) | ~1.9GB each | Pre-synced blockchain data |
   | container-image.tar.gz | ~200MB | Alpine Linux container |
   | vm-image.tar.gz | ~400MB | Alpine Linux VM |
   | bitcoind-gm | ~30MB | Garbageman daemon |
   | bitcoin-cli-gm | ~5MB | Garbageman CLI |
   | bitcoind-knots | ~30MB | Bitcoin Knots daemon |
   | bitcoin-cli-knots | ~5MB | Bitcoin Knots CLI |
   | SHA256SUMS | <1KB | Checksums for verification |
   | MANIFEST.txt | <1KB | Metadata and instructions |
   
   **Total download size:** ~21-22GB (all files) or ~20.5GB (blockchain + one implementation + one image)
   ```

5. **Upload all release files:**

   Drag and drop or click to upload all files from `~/Downloads/final-release-export/`:
   
   - `blockchain.tar.gz.part01` through `part11` (or `part12`)
   - `container-image.tar.gz`
   - `vm-image.tar.gz`
   - `bitcoind-gm`
   - `bitcoin-cli-gm`
   - `bitcoind-knots`
   - `bitcoin-cli-knots`
   - `SHA256SUMS`
   - `MANIFEST.txt`

   **Upload tips:**
   - Can drag entire folder to GitHub release assets area
   - All files are under 2GB (blockchain parts are 1.9GB each)
   - Use stable internet connection
   - Total upload: ~21-22GB

6. **Publish release:**
   - Review everything looks correct
   - Click "Publish release"
   - Release is now public and downloadable

### Phase 7: Verify the Release

After publishing, test imports to ensure everything works:

**Test Container + Garbageman:**
```bash
./garbageman-nm.sh
# Choose: Container mode (if asked)
# Option 1 → Import from GitHub → Select your new release
# Choose: Garbageman implementation
# Verify: Downloads, checksums pass, imports successfully
# Start and test basic functionality
```

**Test VM + Bitcoin Knots:**
```bash
# Delete base container first
./garbageman-nm.sh
# Option 3 → Delete Base

# Restart TUI
exit
./garbageman-nm.sh
# Choose: VM mode
# Option 1 → Import from GitHub → Select your release
# Choose: Bitcoin Knots implementation
# Verify: Downloads, checksums pass, imports successfully
```

**Verify functionality:**
- Instance starts successfully
- Tor hidden service generates .onion address
- Node discovers peers
- Block height matches release notes
- Can create clones from base

## Release Workflow Summary

For quick reference, here's the complete workflow:

```bash
# === PHASE 1: GARBAGEMAN CONTAINER ===
./garbageman-nm.sh  # Choose Container mode
# Build Garbageman from scratch → Export (image only)
# Save to: ~/Downloads/garbageman-container-export/

# === PHASE 2: BITCOIN KNOTS VM ===
# Delete base container, restart TUI
./garbageman-nm.sh  # Choose VM mode  
# Build Bitcoin Knots from scratch → Export (image only)
# Save to: ~/Downloads/knots-vm-export/

# === PHASE 3: SYNC BLOCKCHAIN ===
# Delete base VM, restart TUI
./garbageman-nm.sh  # Choose Container mode
# Download previous release files
# Replace container-image.tar.gz with Phase 1 build
# Import from file → Wait for catchup sync (10-20 minutes)
# Export with blockchain
# Save to: ~/Downloads/final-release-export/

# === PHASE 4: ASSEMBLE RELEASE ===
cd ~/Downloads/final-release-export/
rm bitcoind bitcoin-cli
cp ~/Downloads/garbageman-container-export/bitcoind ./bitcoind-gm
cp ~/Downloads/garbageman-container-export/bitcoin-cli ./bitcoin-cli-gm
cp ~/Downloads/knots-vm-export/bitcoind ./bitcoind-knots
cp ~/Downloads/knots-vm-export/bitcoin-cli ./bitcoin-cli-knots
cp ~/Downloads/knots-vm-export/vm-image.tar.gz .
# Update SHA256SUMS (remove old, add new checksums)
sha256sum -c SHA256SUMS  # Verify all OK

# === PHASE 5: TAG AND RELEASE ===
BLOCK_HEIGHT=921348  # From MANIFEST.txt
git tag -a v2025.11.07 -m "Release v2025.11.07 - Block $BLOCK_HEIGHT"
git push origin v2025.11.07
# Create GitHub release → Upload all files from final-release-export/

# === PHASE 6: TEST ===
./garbageman-nm.sh
# Test: Container + Garbageman import
# Test: VM + Bitcoin Knots import
```

**Time investment:**
- Phase 1: 2-3 hours (Garbageman build)
- Phase 2: 2-3 hours (Knots build)
- Phase 3: 10-20 minutes (catchup sync from previous release) *or 24-48 hours if syncing from scratch*
- Phase 4: 30 minutes (assembly)
- Phase 5: 1-2 hours (upload to GitHub)
- Phase 6: 1 hour (testing)
- **Total: ~6-10 hours** (when using previous release) *or ~2-3 days if syncing from scratch*

## Managing Multiple Releases

- **Keep recent releases:** Maintain 2-3 recent blockchain heights
- **Delete old releases:** Remove releases >3 months old to save space
- **Release frequency:** Monthly or every 2-3 months, or at significant milestones
- **Tag strategy:** Date-based (`v2025.11.07`) is clearest for users

## Important Notes

### Why This Complex Process?

The multi-phase process ensures:

1. **Both implementations available** - Users choose Garbageman or Knots
2. **Both deployment modes available** - Users choose Container or VM
3. **Fresh builds** - Latest code compiled from scratch
4. **Current blockchain** - Synced to recent block height
5. **Clean exports** - No sensitive data, fresh Tor keys

### Blockchain Sync Time

**When importing from previous release (recommended):**
- Phase 3 sync: 10-20 minutes to catch up from previous block height
- Total process: 6-10 hours (mostly compilation in Phases 1-2)
- Can complete in a single work day

**When starting from scratch:**
- Phase 3 sync: 24-48 hours for full blockchain sync
- Total process: ~2-3 days (mostly unattended sync)
- Monitor progress periodically with TUI Option 2
- Don't interrupt once sync starts - checkpoint recovery is slower

### Why Not Just Update Previous Release?

You might wonder: "Why not just start the old release and let it sync?"

**The complex process ensures:**
- Fresh compilation of both implementations with latest code
- Clean images without accumulated logs/state
- Proper testing of both Container and VM modes
- Verification that export/import cycle works
- Both Garbageman and Knots binaries included

### Disk Space Requirements

During the process, you'll need:
- ~25GB for Garbageman container + blockchain
- ~25GB for Bitcoin Knots VM (temporary, can delete after export)
- ~25GB for final container with synced blockchain
- ~25GB for export files
- **Total peak: ~75-100GB**

After Phase 4 assembly, you can delete intermediate folders to reclaim space.

## Troubleshooting

**Tag already exists:**
```bash
# Delete local tag
git tag -d v2025.11.07

# Delete remote tag
git push origin :refs/tags/v2025.11.07

# Create new tag
git tag -a v2025.11.07 -m "Release v2025.11.07 - Block 921348"
git push origin v2025.11.07
```

**Upload failed:**
- Check file sizes (all should be <2GB)
- Verify stable internet connection
- Try uploading in batches (blockchain parts, then images, then binaries)
- Use GitHub Desktop for large uploads if web interface times out

**Checksum verification fails:**
- Regenerate SHA256SUMS file in Phase 4
- Verify you're using the correct files from correct export folders
- Check for file corruption during copy operations

**Import test fails:**
- Verify all files uploaded to GitHub release
- Check SHA256SUMS contains all file checksums
- Test download from different network/machine
- Check MANIFEST.txt has correct metadata

**Blockchain sync stuck:**
- Check peer connections in TUI Option 2
- Verify Tor is working (test .onion address)
- Check logs: `docker logs gm-base` (for container) or `ssh root@<VM-IP> tail -f /var/lib/bitcoin/debug.log` (for VM, IP shown in TUI)
- May just be slow - Tor connections take time

**Running out of disk space:**
- Delete intermediate exports after Phase 4 assembly
- Delete old release downloads
- Use `docker system prune` to clean up container layers
- Delete base instances when switching between phases

## Best Practices

1. **Plan ahead:**
   - Block out 4-6 hours when importing from previous release
   - Or 2-3 days if starting blockchain sync from scratch
   - Most active time is during builds (Phases 1-2)
   - Start Phase 3 before a weekend

2. **Test thoroughly:**
   - Always test both implementations after release
   - Test both Container and VM imports
   - Verify on a clean system if possible
   - Check that clones can be created from imported base

3. **Document blockchain state:**
   - Include exact block height in git tag and release notes
   - Note export date/time in release description
   - Mention any special network conditions

4. **Keep organized:**
   - Use clearly named folders for each phase
   - Don't delete intermediate exports until final assembly verified
   - Keep notes on which files came from which phase

5. **Verify checksums religiously:**
   - Check SHA256SUMS after every export
   - Verify again after copying files between folders
   - Test final SHA256SUMS before uploading to GitHub
   - All checksums must pass before publishing

6. **Communicate clearly:**
   - Explain dual-implementation format in release notes
   - Document which implementation users should choose
   - Provide clear import instructions
   - List all included files with sizes

7. **Clean up after:**
   - Delete intermediate export folders after successful release
   - Delete base containers/VMs after exporting
   - Free up disk space for next release cycle
   - Keep only the final release export for reference

## Security Considerations

- **Sanitization is automatic:** Export process removes all sensitive data
- **Verify checksums:** Users should always verify download integrity via SHA256SUMS
- **Fresh keys on import:** Tor and SSH keys regenerate on first boot
- **No wallet data:** Garbageman/Knots don't store private keys in exports
- **Reproducible:** Users can always build from scratch to verify
- **Both implementations:** Increases trust through choice and comparison

## Frequently Asked Questions

**Q: Why not automate this entire process?**

A: The multi-phase process requires human verification at each step:
- Verify builds completed successfully
- Monitor blockchain sync progress
- Verify checksums at multiple points
- Test imports before publishing
- Human judgment on when to release

**Q: Can I skip the VM phase if I only use containers?**

A: No, users expect both options. Many prefer VMs for complete isolation. The VM build also provides the Bitcoin Knots binaries that users need regardless of deployment method.

**Q: Why build Garbageman and Knots separately?**

A: Different codebases, different compile-time options. Building each from scratch ensures clean, tested binaries for both implementations.

**Q: Can I just update binaries without re-syncing blockchain?**

A: For minor updates, yes - but users would need compatible blockchain from previous release. For major releases, always include current blockchain.

**Q: What if blockchain sync fails partway?**

A: The container/VM will resume from last checkpoint. Don't delete and restart - let it recover. Checkpoints happen every 10000 blocks or so.

**Q: How do I know when it's time for a new release?**

A: Release when:
- 1-3 months since last release
- Major code updates to Garbageman or Knots
- Current release is >10000 blocks behind
- Bug fixes that require new builds

**Q: Can users mix and match files from different releases?**

A: Blockchain parts are compatible across releases if block heights overlap. Images and binaries should match the release they came from. Don't mix implementations' binaries.

## Quick Reference Checklist

Use this checklist when creating a release:

### Preparation
- [ ] Block out 4-6 hours (or 2-3 days if syncing from scratch)
- [ ] Ensure 75-100GB free disk space
- [ ] TUI script tested and working
- [ ] Git access configured
- [ ] GitHub account ready

### Phase 1: Garbageman Container
- [ ] Start TUI, choose Container mode
- [ ] Build Garbageman from scratch (~2 hours)
- [ ] Export image-only
- [ ] Save to `~/Downloads/garbageman-container-export/`
- [ ] Verify export contains: container-image.tar.gz, bitcoind, bitcoin-cli, SHA256SUMS

### Phase 2: Bitcoin Knots VM
- [ ] Delete Garbageman container
- [ ] Restart TUI, choose VM mode
- [ ] Build Bitcoin Knots from scratch (~2 hours)
- [ ] Export image-only
- [ ] Save to `~/Downloads/knots-vm-export/`
- [ ] Verify export contains: vm-image.tar.gz, bitcoind, bitcoin-cli, SHA256SUMS

### Phase 3: Blockchain Sync
- [ ] Delete Knots VM
- [ ] Restart TUI, choose Container mode
- [ ] Download previous release files from GitHub
- [ ] Replace container-image.tar.gz with Phase 1 build
- [ ] Update container-image checksum in SHA256SUMS
- [ ] Import from file
- [ ] Wait for catchup sync (10-20 minutes) *or 24-48 hours if starting from scratch*
- [ ] Export with blockchain
- [ ] Save to `~/Downloads/final-release-export/`
- [ ] Verify export contains all blockchain parts, images, binaries

### Phase 4: Assembly
- [ ] cd into final-release-export/
- [ ] Remove generic bitcoind and bitcoin-cli
- [ ] Copy and rename Garbageman binaries (bitcoind-gm, bitcoin-cli-gm)
- [ ] Copy and rename Knots binaries (bitcoind-knots, bitcoin-cli-knots)
- [ ] Copy vm-image.tar.gz from Phase 2
- [ ] Update SHA256SUMS (remove old, add new checksums)
- [ ] Run `sha256sum -c SHA256SUMS` - verify all OK
- [ ] Check MANIFEST.txt has correct block height

### Phase 5: Git Tag
- [ ] Get block height from MANIFEST.txt
- [ ] Create annotated tag with block height
- [ ] Push tag to GitHub

### Phase 6: GitHub Release
- [ ] Go to releases page
- [ ] Draft new release
- [ ] Select your tag
- [ ] Write descriptive title and release notes
- [ ] Upload ALL files from final-release-export/
- [ ] Verify file count (12-14 blockchain parts + 2 images + 4 binaries + SHA256SUMS + MANIFEST.txt)
- [ ] Publish release

### Phase 7: Testing
- [ ] Test Container + Garbageman import from GitHub
- [ ] Test VM + Knots import from GitHub  
- [ ] Verify instances start and function correctly
- [ ] Announce release

## Resources

- [GitHub Releases Documentation](https://docs.github.com/en/repositories/releasing-projects-on-github)
- [Git Tagging](https://git-scm.com/book/en/v2/Git-Basics-Tagging)
- [SHA256 Checksums](https://en.wikipedia.org/wiki/SHA-2)

---

**Questions or issues?** Open an issue on GitHub or consult the main README.md.
