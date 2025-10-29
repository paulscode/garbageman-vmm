# GitHub Release Guide

This guide explains how to create GitHub releases with pre-synced base VM exports for garbageman-vmm.

## Why Create Releases?

- Let users skip the 24-28 hour blockchain sync
- Share pre-synced VMs at specific block heights
- Provide verified, sanitized base VMs for the community
- Enable quick deployment for new users

## Prerequisites

- A fully synced base VM (`gm-base`)
- ~25GB free space in `~/Downloads` for export
- Git access to push tags
- GitHub account with write access to the repository

## Step-by-Step Process

### 1. Export the Base VM

From the main menu:

```
Option 3: Manage Base VM → export
```

This creates:
- `~/Downloads/gm-base-export-YYYYMMDD-HHMMSS.tar.gz` (~22GB)
- `~/Downloads/gm-base-export-YYYYMMDD-HHMMSS.tar.gz.sha256` (checksum)

**What gets removed during export:**
- Tor hidden service keys (fresh .onion on import)
- SSH keys (fresh keys generated)
- Bitcoin peer databases (discovers peers independently)
- All logs (clean slate)

### 2. Split the Export for GitHub

GitHub has a 2GB file size limit for release assets, so we split the archive:

```bash
cd /path/to/garbageman-vmm
./devtools/split-export-for-github.sh
```

**What it does:**
1. Scans `~/Downloads` for export archives
2. Lets you select which one to split
3. Splits into 1.9GB parts (safely under 2GB limit)
4. Generates checksums for verification
5. Creates `MANIFEST.txt` with reassembly instructions

**Output location:**
```
~/Downloads/gm-base-export-YYYYMMDD-HHMMSS-github/
  ├── gm-base-export.tar.gz.part01
  ├── gm-base-export.tar.gz.part02
  ├── gm-base-export.tar.gz.part03
  ├── ... (typically 11-12 parts)
  ├── gm-base-export.tar.gz.sha256
  └── MANIFEST.txt
```

### 3. Create a Git Tag

Tags mark specific points in the repository history. Use semantic versioning:

```bash
# Get current blockchain height from the VM
# (shown in "Manage Base VM" menu when VM is running)

# Create annotated tag with blockchain info
git tag -a v1.0.0 -m "Release v1.0.0 - Block height 921348 (2025-10-29)"

# Push tag to GitHub
git push origin v1.0.0
```

**Tag naming convention:**
- `v1.0.0` - Major release (significant features)
- `v1.1.0` - Minor release (updates, improvements)
- `v1.1.1` - Patch release (bug fixes)

For blockchain exports, you might use:
- `v1.0.0` - First release at a milestone block height
- `v1.1.0` - Updated export with newer blocks
- Date-based: `v2025.10.29` - Export from specific date

### 4. Create GitHub Release

1. **Go to releases page:**
   ```
   https://github.com/paulscode/garbageman-vmm/releases
   ```

2. **Click "Draft a new release"**

3. **Select your tag:**
   - Choose the tag you just pushed (e.g., `v1.0.0`)
   - Or create a new tag from the web interface

4. **Fill in release details:**

   **Release title example:**
   ```
   v1.0.0 - Base VM with Blockchain at Height 921348
   ```

   **Description example:**
   ```markdown
   ## Pre-Synced Base VM Export
   
   This release includes a fully synced Garbageman base VM ready for import.
   
   **Blockchain Status:**
   - Block height: 921,348
   - Export date: 2025-10-29
   - Blockchain size: ~25GB (pruned)
   
   **What's Included:**
   - Alpine Linux 3.18 VM
   - Bitcoin Knots (Garbageman fork) compiled and configured
   - Tor configured for .onion connectivity
   - Fully synced and pruned blockchain
   - All sensitive data removed (fresh Tor/SSH keys on import)
   
   **How to Use:**
   1. Run `garbageman-vmm.sh`
   2. Choose "Create Base VM" → "Import from GitHub"
   3. Select this release
   4. Script downloads, verifies, and imports automatically (~22GB download)
   
   **Manual Import:**
   If you prefer to download manually:
   1. Download all `.part*` files to a directory
   2. Download `gm-base-export.tar.gz.sha256`
   3. Verify: `sha256sum -c gm-base-export.tar.gz.sha256`
   4. Reassemble: `cat gm-base-export.tar.gz.part* > gm-base-export.tar.gz`
   5. Move to `~/Downloads/` and import via "Import from file"
   
   See `MANIFEST.txt` for detailed instructions.
   
   **Checksums:**
   All parts are checksummed. The import process verifies integrity automatically.
   ```

5. **Upload assets:**

   Drag and drop or click to upload all files from the split directory:
   - `gm-base-export.tar.gz.part01`
   - `gm-base-export.tar.gz.part02`
   - `gm-base-export.tar.gz.part03`
   - ... (all parts)
   - `gm-base-export.tar.gz.sha256`
   - `MANIFEST.txt`

   **Upload tips:**
   - GitHub supports bulk upload
   - Files must be under 2GB each (our parts are 1.9GB)
   - Upload can take a while (~22GB total)
   - Use a stable internet connection

6. **Set as pre-release (optional):**
   - Check "This is a pre-release" if it's for testing
   - Leave unchecked for stable releases

7. **Publish release:**
   - Click "Publish release"
   - Release is now public and downloadable

### 5. Verify the Release

After publishing, test the import:

```bash
./garbageman-vmm.sh
# Choose: Create Base VM → Import from GitHub
# Select your new release
# Verify it downloads and imports correctly
```

## Managing Multiple Releases

- **Keep recent releases:** Maintain 2-3 recent blockchain heights
- **Delete old releases:** Remove outdated exports to save space
- **Tag strategy:** Use consistent versioning (date-based or semantic)
- **Release frequency:** Monthly or at significant block milestones

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
- Check checksums match
- Ensure `MANIFEST.txt` is included
- Test download yourself from clean environment

## Best Practices

1. **Always test exports before releasing:**
   - Import on a fresh system
   - Verify blockchain syncs from export point
   - Check Tor connectivity works

2. **Document blockchain state:**
   - Include exact block height
   - Note export date/time
   - Mention any special configurations

3. **Keep exports current:**
   - Release every 1-3 months
   - After significant network events
   - When major script updates occur

4. **Verify checksums:**
   - Always include `.sha256` file
   - Test checksum verification
   - Document verification steps

5. **Provide fallback options:**
   - Include manual reassembly instructions
   - Document "Import from file" method
   - Offer alternative download methods if needed

## Security Considerations

- **Sanitization is automatic:** Export process removes all sensitive data
- **Verify checksums:** Users should always verify download integrity
- **Fresh keys on import:** Tor and SSH keys regenerate on first boot
- **No wallet data:** Garbageman doesn't store private keys in the VM
- **Reproducible:** Users can always build from scratch to verify

## Example Release Workflow

```bash
# 1. Export base VM (from main menu)
# 2. Split for GitHub
./devtools/split-export-for-github.sh
# Select the export, parts created in ~/Downloads/gm-base-export-*-github/

# 3. Create and push tag
git tag -a v2025.10.29 -m "Release 2025.10.29 - Block 921348"
git push origin v2025.10.29

# 4. Create release on GitHub
# - Go to releases page
# - Draft new release
# - Select tag v2025.10.29
# - Add description with block height
# - Upload all files from split directory
# - Publish

# 5. Test
./garbageman-vmm.sh
# Create Base VM → Import from GitHub → Select v2025.10.29
# Verify import completes successfully

# 6. Announce
# - Update README if needed
# - Post to relevant communities
# - Document any known issues
```

## Questions?

- **How often to release?** Monthly or when >1000 blocks behind
- **What to name tags?** Date-based (`v2025.10.29`) or semantic (`v1.2.0`)
- **Delete old releases?** Keep last 2-3, delete older ones
- **Pre-release vs release?** Use pre-release for testing, regular for stable

## Resources

- [GitHub Releases Documentation](https://docs.github.com/en/repositories/releasing-projects-on-github)
- [Semantic Versioning](https://semver.org/)
- [Git Tagging](https://git-scm.com/book/en/v2/Git-Basics-Tagging)
