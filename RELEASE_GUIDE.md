# GitHub Release Guide

This guide explains how to create GitHub releases with pre-synced base VM and container exports for garbageman-nm using the **unified export format**.

## Why Create Releases?

- Let users skip the 24-28 hour blockchain sync
- Share pre-synced VMs/containers at specific block heights
- Provide verified, sanitized base deployments for the community
- Enable quick deployment for new users
- **NEW:** Smaller downloads with modular exports (blockchain separate from VM/container)

## Prerequisites

- A fully synced base VM (`gm-base`) and/or container (`gm-base`)
- ~25GB free space in `~/Downloads` for export
- Git access to push tags
- GitHub account with write access to the repository

## Unified Export System

The unified export system keeps blockchain data and image files together in a single folder:

**Benefits:**
- Simple folder structure - all files in one place
- Implementation-agnostic naming (ready for Bitcoin Knots, etc.)
- Easy to copy entire folder to USB stick
- All files stay under GitHub's 2GB limit
- Combined SHA256SUMS file for all assets

**Export Components:**
1. **Blockchain data** - Split into 1.9GB parts (blockchain.tar.gz.part01, part02, etc.)
2. **VM or Container image** - Sanitized image without blockchain (~500MB-1GB)
3. **SHA256SUMS** - Combined checksums for all files
4. **MANIFEST.txt** - Export metadata and instructions

## Step-by-Step Process

### 1. Prepare GitHub Release Files

Use the main script's export functionality:

```bash
./garbageman-nm.sh
```

**For VM releases:**
- Choose **"Export Base VM"**
- Select **"Full export (with blockchain)"**

**For Container releases:**
- Choose **"Export Base Container"**
- Select **"Full export (with blockchain)"**

**What it does:**
1. Extracts blockchain data from running VM/container
2. Splits blockchain into <2GB parts (GitHub-compatible)
3. Exports sanitized VM/container image without blockchain
4. Generates combined SHA256SUMS file with all checksums
5. Creates MANIFEST.txt with metadata
6. Places everything in unified folder structure

**Output location:**
```
~/Downloads/gm-export-YYYYMMDD-HHMMSS/
  ├── blockchain.tar.gz.part01
  ├── blockchain.tar.gz.part02
  ├── blockchain.tar.gz.part03
  ├── ... (typically 11-12 parts, ~20GB total)
  ├── vm-image.tar.gz (~1GB)
  │   OR
  ├── container-image.tar.gz (~500MB)
  ├── SHA256SUMS (checksums for all files above)
  └── MANIFEST.txt
```

**What gets removed during export:**
- Blockchain data from image (exported separately in parts)
- Tor hidden service keys (fresh .onion on import)
- SSH keys (fresh keys generated)
- Bitcoin peer databases (discovers peers independently)
- All logs (clean slate)

### 2. Create a Git Tag

Tags mark specific points in the repository history. Use semantic versioning:

```bash
# Get current blockchain height from the VM/container
# (shown in "Manage Base VM/Container" menu when running)

# Create annotated tag with blockchain info
git tag -a v1.0.0 -m "Release v1.0.0 - Block height 921348 (2025-10-29)"

# Push tag to GitHub
git push origin v1.0.0
```

**Tag naming convention:**
- `v1.0.0` - Major release (significant features)
- `v1.1.0` - Minor release (updates, improvements)
- `v1.1.1` - Patch release (bug fixes)
- Date-based: `v2025.10.29` - Export from specific date

### 3. Create GitHub Release

1. **Go to releases page:**
   ```
   https://github.com/paulscode/garbageman-nm/releases
   ```

2. **Click "Draft a new release"**

3. **Select your tag:**
   - Choose the tag you just pushed (e.g., `v1.0.0`)
   - Or create a new tag from the web interface

4. **Fill in release details:**

   **Release title example:**
   ```
   v1.0.0 - Modular VM + Container with Blockchain at Height 921348
   ```

   **Description example:**
   ```markdown
   ## Pre-Synced Modular Release (NEW FORMAT)
   
   This release includes modular exports for both VM and container deployments.
   
   **Blockchain Status:**
   - Block height: 921,348
   - Export date: 2025-10-29
   - Blockchain size: ~20GB compressed (pruned to 750MB)
   
   **What's Included:**
   - ✅ Blockchain data (shared between VM and container)
   - ✅ VM image (~1GB) - Alpine Linux 3.18 + Bitcoin Knots
   - ✅ Container image (~500MB) - Alpine Linux + Bitcoin Knots
   - ✅ All files SHA256 checksummed
   - ✅ Automatic reassembly and import via garbageman-nm.sh
   
   **Modular Benefits:**
   - Smaller downloads (get only what you need)
   - Blockchain shared between VM and container
   - Easy to update VM/container without re-downloading blockchain
   - All files under GitHub's 2GB limit
   
   ## How to Use
   
   ### Automatic Import (Recommended)
   
   **For VM:**
   1. Run `./garbageman-nm.sh`
   2. Choose "Create Base VM" → "Import from GitHub"
   3. Select this release
   4. Script downloads blockchain + VM image, verifies checksums, and assembles automatically
   
   **For Container:**
   1. Run `./garbageman-nm.sh`
   2. Choose "Create Base Container" → "Import from GitHub"
   3. Select this release
   4. Script downloads blockchain + container image, verifies, and assembles automatically
   
   ### Manual Import
   
   **Download files:**
   - Download all `blockchain.tar.gz.part*` files
   - Download either `vm-image.tar.gz` OR `container-image.tar.gz`
   - Download `SHA256SUMS` checksum file
   
   **Verify and reassemble:**
   ```bash
   # Create unified export folder
   mkdir gm-export-downloaded
   cd gm-export-downloaded
   
   # Move all downloaded files here
   mv /path/to/downloads/blockchain.tar.gz.part* .
   mv /path/to/downloads/vm-image.tar.gz .  # or container-image.tar.gz
   mv /path/to/downloads/SHA256SUMS .
   
   # Verify all files
   sha256sum -c SHA256SUMS
   
   # Move entire folder to Downloads for import
   mv ../gm-export-downloaded ~/Downloads/
   
   # Import via garbageman-nm.sh → "Import from file"
   ```
   
   See `MANIFEST.txt` for detailed instructions.
   
   **Checksums:**
   All files are SHA256 checksummed in the unified SHA256SUMS file. The import process verifies integrity automatically.
   ```

5. **Upload assets:**

   Drag and drop or click to upload all files from the export directory:
   
   **Required files:**
   - All `blockchain.tar.gz.part*` files (11-12 parts)
   - `SHA256SUMS` (unified checksums for all files)
   - `MANIFEST.txt`
   
   **For VM release:**
   - `vm-image.tar.gz`
   
   **For Container release:**
   - `container-image.tar.gz`
   
   **For Both (recommended):**
   - Upload all blockchain parts (shared between VM and container)
   - Upload both VM and container images
   - Upload SHA256SUMS and MANIFEST.txt

   **Upload tips:**
   - GitHub supports bulk upload (drag entire export folder)
   - All files are under 2GB (blockchain parts are 1.9GB each)
   - Total upload: ~21-22GB for both VM and container
   - Use a stable internet connection

6. **Set as pre-release (optional):**
   - Check "This is a pre-release" if it's for testing
   - Leave unchecked for stable releases

7. **Publish release:**
   - Click "Publish release"
   - Release is now public and downloadable

### 4. Verify the Release

After publishing, test the import:

**Test VM import:**
```bash
./garbageman-nm.sh
# Choose: Create Base VM → Import from GitHub
# Select your new release
# Verify it downloads, verifies checksums, and imports correctly
```

**Test Container import:**
```bash
./garbageman-nm.sh
# Choose: Create Base Container → Import from GitHub
# Select your new release
# Verify container import works correctly
```

## Managing Multiple Releases

- **Keep recent releases:** Maintain 2-3 recent blockchain heights
- **Delete old releases:** Remove outdated exports to save space
- **Tag strategy:** Use date-based (`v2025.10.29`) or semantic versioning
- **Release frequency:** Monthly or at significant block milestones

## Creating Image-Only Updates

You can release updated VM/container images without including blockchain data. Users would use blockchain from a previous release:

**From main script:**
1. Run `./garbageman-nm.sh`
2. Choose Export Base VM or Export Base Container
3. Select **"Image-only export"** instead of full export
4. Upload the image file, SHA256SUMS, and MANIFEST.txt to GitHub release
5. Document which previous release contains compatible blockchain

**Note:** Users will need to download the image files from your new release and blockchain parts from the referenced older release.

## Troubleshooting

**Tag already exists:**
```bash
# Delete local tag
git tag -d v1.0.0

# Delete remote tag
git push origin :refs/tags/v1.0.0

# Create new tag
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

**Upload failed:**
- Check file sizes (must be <2GB)
- Verify internet connection
- Try uploading in smaller batches
- Use GitHub Desktop for large uploads

**Users report download issues:**
- Verify all parts uploaded successfully
- Check SHA256SUMS file is included and valid
- Ensure MANIFEST.txt is included
- Test download yourself from clean environment

## Best Practices

1. **Always test exports before releasing:**
   - Import on a fresh system (both VM and container)
   - Verify blockchain syncs from export point
   - Check Tor connectivity works
   - Test both automatic and manual import methods

2. **Document blockchain state:**
   - Include exact block height in release notes
   - Note export date/time
   - Mention any special configurations

3. **Keep exports current:**
   - Release every 1-3 months
   - After significant network events
   - When major script updates occur

4. **Verify checksums:**
   - Always include SHA256SUMS file with all checksums
   - Test checksum verification yourself
   - Document verification steps in release notes

5. **Provide clear instructions:**
   - Explain unified export format to users
   - Document both VM and container import
   - Include reassembly steps in MANIFEST.txt
   - Share entire export folder for USB transfer use cases

6. **Keep exports organized:**
   - One export folder per release
   - All blockchain parts + image + checksums together in SHA256SUMS
   - Easy to copy entire folder to USB or backup

## Security Considerations

- **Sanitization is automatic:** Export process removes all sensitive data
- **Verify checksums:** Users should always verify download integrity via SHA256SUMS
- **Fresh keys on import:** Tor and SSH keys regenerate on first boot
- **No wallet data:** Garbageman doesn't store private keys in the VM
- **Reproducible:** Users can always build from scratch to verify

## Example Release Workflow

### Full VM Release (Blockchain + Image)

```bash
# 1. Run main script and export
./garbageman-nm.sh
# Choose: Export Base VM
# Select: Full export (with blockchain)

# Output created in ~/Downloads/gm-export-YYYYMMDD-HHMMSS/
# Contains: blockchain.tar.gz.part01-XX + vm-image.tar.gz + SHA256SUMS + MANIFEST.txt

# 2. Create and push tag
BLOCK_HEIGHT=921348
git tag -a v2025.10.29 -m "Release 2025.10.29 - Block $BLOCK_HEIGHT"
git push origin v2025.10.29

# 3. Create release on GitHub
# - Go to https://github.com/paulscode/garbageman-nm/releases
# - Click "Draft a new release"
# - Select tag v2025.10.29
# - Add description with block height and format details
# - Upload ALL files from ~/Downloads/gm-export-YYYYMMDD-HHMMSS/
# - Publish

# 4. Test import
./garbageman-nm.sh
# Create Base VM → Import from GitHub → Select v2025.10.29

# 5. Announce
# - Update README if needed
# - Post to relevant communities
```

### Full Container Release

```bash
# 1. Export container with blockchain
./garbageman-nm.sh
# Choose: Export Base Container
# Select: Full export (with blockchain)

# 2. Follow same steps as VM release (tag, upload, test)
```

### Image-Only Update Release

```bash
# 1. Export just the image
./garbageman-nm.sh
# Choose: Export Base VM (or Container)
# Select: Image-only export

# 2. Create patch release tag
git tag -a v2025.10.29.1 -m "VM update - uses v2025.10.29 blockchain"
git push origin v2025.10.29.1

# 3. Create release on GitHub
# - Draft new release for v2025.10.29.1
# - Note: "Image update only - use blockchain from v2025.10.29"
# - Upload image file, SHA256SUMS, and MANIFEST.txt from export
# - Users download this + blockchain parts from v2025.10.29
```

## Questions?

- **How often to release?** Monthly or when >1000 blocks behind
- **What to name tags?** Date-based (`v2025.10.29`) recommended for clarity
- **Delete old releases?** Keep last 2-3, delete older ones
- **Pre-release vs release?** Use pre-release for testing, regular for stable
- **VM or container or both?** Recommended: Include both VM and container images in one release (shared blockchain)
- **Can I update image without new blockchain?** Yes! Use image-only export
- **What if GitHub changes?** Unified format makes it easy to host elsewhere or share via USB

## Migration from Old Format

If you have existing monolithic releases (`gm-base-export-*.tar.gz`):

1. **Old releases are deprecated** - Current script only supports unified format
2. **New releases use unified format** - Smaller, more flexible, modular architecture
3. **Document format change** - In release notes, explain unified format benefits
4. **Users must upgrade** - Old format imports are no longer supported; users should use latest unified format releases

## Resources

- [GitHub Releases Documentation](https://docs.github.com/en/repositories/releasing-projects-on-github)
- [Semantic Versioning](https://semver.org/)
- [Git Tagging](https://git-scm.com/book/en/v2/Git-Basics-Tagging)
