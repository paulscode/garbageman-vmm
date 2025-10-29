#!/bin/bash
#
# split-export-for-github.sh - Split VM export into GitHub-compatible parts
#
# Purpose: Prepare exported base VM for GitHub release assets
# GitHub has a 2GB file size limit, so large exports need to be split
#
# Flow:
#   1. Scan ~/Downloads for gm-base-export-*.tar.gz files
#   2. Let user select which export to split
#   3. Split into <2GB parts (1.9GB to be safe)
#   4. Generate checksums for verification
#   5. Create output directory with all parts ready for upload
#
# Output:
#   - Directory: ~/Downloads/gm-base-export-TIMESTAMP-github/
#   - Files: gm-base-export.tar.gz.part01, part02, etc.
#   - Checksum: gm-base-export.tar.gz.sha256
#   - Manifest: MANIFEST.txt with part count and assembly instructions

set -euo pipefail

DOWNLOADS_DIR="$HOME/Downloads"
SPLIT_SIZE="1900M"  # 1.9GB to stay safely under 2GB limit

echo "╔════════════════════════════════════════════════════════════════════════════════╗"
echo "║               Split Export for GitHub Release                                  ║"
echo "╚════════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Find all export archives
echo "Scanning ~/Downloads for export archives..."
mapfile -t archives < <(find "$DOWNLOADS_DIR" -maxdepth 1 -name "gm-base-export-*.tar.gz" -type f 2>/dev/null | sort -r)

if [[ ${#archives[@]} -eq 0 ]]; then
  echo "❌ No export archives found in ~/Downloads"
  echo ""
  echo "Looking for files matching: gm-base-export-*.tar.gz"
  exit 1
fi

echo "Found ${#archives[@]} export archive(s):"
echo ""

# Display archives with size and selection number
for i in "${!archives[@]}"; do
  archive="${archives[$i]}"
  basename=$(basename "$archive")
  size=$(du -h "$archive" | cut -f1)
  echo "  [$((i+1))] $basename ($size)"
done

echo ""
read -p "Select export to split [1-${#archives[@]}]: " selection

if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#archives[@]} ]]; then
  echo "❌ Invalid selection"
  exit 1
fi

selected_archive="${archives[$((selection-1))]}"
archive_basename=$(basename "$selected_archive")
archive_size=$(du -h "$selected_archive" | cut -f1)
archive_size_bytes=$(stat -c%s "$selected_archive")

echo ""
echo "Selected: $archive_basename ($archive_size)"
echo ""

# Extract timestamp from filename for output directory
timestamp=$(echo "$archive_basename" | grep -oP 'gm-base-export-\K[0-9]{8}-[0-9]{6}')
output_dir="$DOWNLOADS_DIR/gm-base-export-${timestamp}-github"

# Check if output directory already exists
if [[ -d "$output_dir" ]]; then
  read -p "⚠  Output directory already exists. Overwrite? [y/N]: " overwrite
  if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
  rm -rf "$output_dir"
fi

mkdir -p "$output_dir"

echo "Creating GitHub-compatible split..."
echo "  Output directory: $output_dir"
echo "  Split size: $SPLIT_SIZE (per part)"
echo ""

# Calculate expected number of parts
split_size_bytes=$((1900 * 1024 * 1024))
expected_parts=$(( (archive_size_bytes + split_size_bytes - 1) / split_size_bytes ))
echo "  Expected parts: ~$expected_parts"
echo ""

# Split the archive
echo "[1/3] Splitting archive into parts..."
cd "$output_dir"
split -b "$SPLIT_SIZE" -d -a 2 "$selected_archive" "gm-base-export.tar.gz.part"

# Rename parts to start from 01 instead of 00 (two-pass to avoid clobbering)
# First pass: add .tmp suffix
for part in gm-base-export.tar.gz.part[0-9][0-9]; do
  if [[ -f "$part" ]] && [[ "$part" =~ part([0-9]{2})$ ]]; then
    num="${BASH_REMATCH[1]}"
    new_num=$(printf '%02d' $((10#$num + 1)))
    mv "$part" "gm-base-export.tar.gz.part${new_num}.tmp"
  fi
done

# Second pass: remove .tmp suffix
for part in gm-base-export.tar.gz.part[0-9][0-9].tmp; do
  if [[ -f "$part" ]]; then
    mv "$part" "${part%.tmp}"
  fi
done

# Count actual parts
part_count=$(ls -1 gm-base-export.tar.gz.part[0-9][0-9] 2>/dev/null | wc -l)
echo "    ✓ Created $part_count parts"

# Generate checksums
echo ""
echo "[2/3] Generating checksums..."
# First, checksum for the original (unsplit) archive
echo "# Original archive checksum (for verification after reassembly)" > gm-base-export.tar.gz.sha256
(cd "$(dirname "$selected_archive")" && sha256sum "$(basename "$selected_archive")") | \
  sed 's/gm-base-export-[0-9]*-[0-9]*.tar.gz/gm-base-export.tar.gz/' >> gm-base-export.tar.gz.sha256
echo "" >> gm-base-export.tar.gz.sha256
echo "# Individual part checksums" >> gm-base-export.tar.gz.sha256
sha256sum gm-base-export.tar.gz.part* >> gm-base-export.tar.gz.sha256
echo "    ✓ Checksums saved to gm-base-export.tar.gz.sha256"

# Create manifest file
echo ""
echo "[3/3] Creating manifest..."
cat > MANIFEST.txt << EOF
Garbageman VMM - Base VM Export (Split for GitHub)
==================================================

Export Date: $timestamp
Parts: $part_count
Original Size: $archive_size
Part Size: ~1.9GB each

Files:
EOF

for ((i=1; i<=part_count; i++)); do
  part_name="gm-base-export.tar.gz.part$(printf '%02d' $i)"
  part_size=$(du -h "$part_name" | cut -f1)
  echo "  - $part_name ($part_size)" >> MANIFEST.txt
done

cat >> MANIFEST.txt << 'EOF'

Reassembly Instructions:
========================

1. Download all parts to the same directory
2. Verify checksums (optional but recommended):
   sha256sum -c gm-base-export.tar.gz.sha256

3. Reassemble the archive:
   cat gm-base-export.tar.gz.part* > gm-base-export.tar.gz

4. Import using garbageman-vmm.sh:
   - Move gm-base-export.tar.gz to ~/Downloads/
   - Run script → Option 1: Create Base VM → Import from file

GitHub Release Instructions:
============================

1. Create a new release tag:
   git tag -a v1.0.0 -m "Release v1.0.0"
   git push origin v1.0.0

2. Go to: https://github.com/paulscode/garbageman-vmm/releases
3. Click "Draft a new release"
4. Select the tag you just created
5. Upload all files from this directory:
   - All .part* files
   - gm-base-export.tar.gz.sha256
   - MANIFEST.txt
6. Add release notes describing the blockchain height and date
7. Publish release

EOF

echo "    ✓ Manifest saved to MANIFEST.txt"
echo ""
echo "╔════════════════════════════════════════════════════════════════════════════════╗"
echo "║                          Split Complete!                                       ║"
echo "╚════════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📦 Output directory: $output_dir"
echo ""
echo "📋 Summary:"
echo "   Parts created: $part_count"
echo "   Total size: $archive_size"
echo "   Files ready for GitHub release upload"
echo ""
echo "Next steps:"
echo "   1. Review MANIFEST.txt in the output directory"
echo "   2. Follow the GitHub Release Instructions in MANIFEST.txt"
echo "   3. Upload all files as release assets"
echo ""
