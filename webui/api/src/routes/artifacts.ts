/**
 * Artifacts Route - Import Daemon Binaries
 * ==========================================
 * Handles importing Bitcoin artifacts from GitHub releases or file uploads.
 * 
 * Flow:
 *  1. GET /api/artifacts/github/releases - Fetch available releases
 *  2. POST /api/artifacts/github/import - Download & import selected release
 *  3. POST /api/artifacts/import - Upload archive file for import
 *  4. GET /api/artifacts - List imported artifacts
 * 
 * Expected Binary Names:
 *  - Garbageman: bitcoind-gm, bitcoin-cli-gm
 *  - Knots: bitcoind-knots, bitcoin-cli-knots
 * 
 * File Upload Format:
 *  Archive can contain files in root or in a single subfolder.
 *  Expected files: bitcoind-gm, bitcoin-cli-gm, bitcoind-knots, bitcoin-cli-knots,
 *                  container-image.tar.gz, blockchain.tar.gz (or .part files)
 */

import type { FastifyInstance } from 'fastify';
import multipart from '@fastify/multipart';
import { promises as fs } from 'fs';
import { pipeline } from 'stream/promises';
import { createWriteStream } from 'fs';
import path from 'path';
import { spawn } from 'child_process';
import type {
  ImportArtifactRequest,
  ImportArtifactResponse,
} from '../lib/types.js';
import { logArtifactImported, logArtifactDeleted } from '../lib/events.js';

const GITHUB_REPO = 'paulscode/garbageman-nm';
const GITHUB_API_URL = `https://api.github.com/repos/${GITHUB_REPO}/releases`;

// Import progress tracking
interface ImportProgress {
  tag: string;
  status: 'downloading' | 'reassembling' | 'complete' | 'error';
  progress: number; // 0-100
  currentFile?: string;
  totalFiles: number;
  downloadedFiles: number;
  error?: string;
  startedAt: number;
  completedAt?: number;
}

const importProgressMap = new Map<string, ImportProgress>();

interface GitHubRelease {
  tag_name: string;
  name: string;
  published_at: string;
  assets: Array<{
    name: string;
    browser_download_url: string;
    size: number;
  }>;
}

interface ReleaseInfo {
  tag: string;
  name: string;
  publishedAt: string;
  hasGarbageman: boolean;
  hasKnots: boolean;
  blockchainParts: number;
  hasContainer: boolean;
  hasVM: boolean;
  totalSizeGB: number;
}

interface LocalArtifact {
  tag: string;
  importedAt: string;
  hasGarbageman: boolean;
  hasKnots: boolean;
  hasContainer: boolean;
  hasBlockchain?: boolean;
  path: string;
}

export default async function artifactsRoute(fastify: FastifyInstance) {
  
  // Register multipart for file uploads
  await fastify.register(multipart, {
    limits: {
      fileSize: 20 * 1024 * 1024 * 1024, // 20GB max file size for blockchain exports
    },
  });
  
  // --------------------------------------------------------------------------
  // GET /api/artifacts - List locally imported artifacts
  // --------------------------------------------------------------------------
  
  fastify.get('/api/artifacts', async (request, reply) => {
    try {
      const fs = await import('fs/promises');
      const path = await import('path');
      
      const artifactsDir = '/app/.artifacts';
      
      // Check if artifacts directory exists
      try {
        await fs.access(artifactsDir);
      } catch {
        // Directory doesn't exist, return empty list
        return reply.send({ artifacts: [] });
      }
      
      // Read all subdirectories (each is a tag)
      const entries = await fs.readdir(artifactsDir, { withFileTypes: true });
      const tagDirs = entries.filter(e => e.isDirectory());
      
      // Read metadata.json from each tag directory
      const artifacts: LocalArtifact[] = [];
      
      for (const tagDir of tagDirs) {
        const metadataPath = path.join(artifactsDir, tagDir.name, 'metadata.json');
        
        try {
          const metadataContent = await fs.readFile(metadataPath, 'utf-8');
          const metadata = JSON.parse(metadataContent);
          
          artifacts.push({
            tag: metadata.tag,
            importedAt: metadata.importedAt,
            hasGarbageman: metadata.hasGarbageman || false,
            hasKnots: metadata.hasKnots || false,
            hasContainer: metadata.hasContainer || false,
            hasBlockchain: metadata.hasBlockchain || false,
            path: path.join(artifactsDir, tagDir.name),
          });
        } catch (error) {
          fastify.log.warn({ tagDir: tagDir.name, error }, 'Failed to read artifact metadata');
        }
      }
      
      // Sort by import date (newest first)
      artifacts.sort((a, b) => 
        new Date(b.importedAt).getTime() - new Date(a.importedAt).getTime()
      );
      
      reply.send({ artifacts });
      
    } catch (error) {
      fastify.log.error({ error }, 'Failed to list artifacts');
      reply.code(500).send({
        error: 'Failed to list artifacts',
        message: error instanceof Error ? error.message : 'Unknown error',
      });
    }
  });
  
  // --------------------------------------------------------------------------
  // GET /api/artifacts/import/progress/:tag - Get import progress
  // --------------------------------------------------------------------------
  
  fastify.get<{
    Params: { tag: string };
  }>('/api/artifacts/import/progress/:tag', async (request, reply) => {
    const { tag } = request.params;
    const progress = importProgressMap.get(tag);
    
    if (!progress) {
      return reply.code(404).send({
        error: 'No import in progress for this artifact',
      });
    }
    
    reply.send(progress);
  });
  
  // --------------------------------------------------------------------------
  // GET /api/artifacts/github/releases - Fetch available GitHub releases
  // --------------------------------------------------------------------------
  
  fastify.get('/api/artifacts/github/releases', async (request, reply) => {
    try {
      fastify.log.info('Fetching GitHub releases...');
      
      // Fetch releases from GitHub API
      const response = await fetch(GITHUB_API_URL, {
        headers: {
          'User-Agent': 'garbageman-webui',
          'Accept': 'application/vnd.github.v3+json',
        },
        signal: AbortSignal.timeout(10000),
      });
      
      if (!response.ok) {
        throw new Error(`GitHub API error: ${response.status}`);
      }
      
      const releases: GitHubRelease[] = await response.json() as GitHubRelease[];
      
      // Parse each release to determine what's available
      const releaseInfos: ReleaseInfo[] = releases.map(release => {
        const assets = release.assets;
        
        // Check for binaries
        const hasGarbageman = assets.some(a => a.name === 'bitcoind-gm') &&
                              assets.some(a => a.name === 'bitcoin-cli-gm');
        const hasKnots = assets.some(a => a.name === 'bitcoind-knots') &&
                         assets.some(a => a.name === 'bitcoin-cli-knots');
        
        // Count blockchain parts
        const blockchainParts = assets.filter(a => 
          /^blockchain\.tar\.gz\.part\d+$/.test(a.name)
        ).length;
        
        // Check for images
        const hasContainer = assets.some(a => a.name === 'container-image.tar.gz');
        const hasVM = assets.some(a => a.name === 'vm-image.tar.gz');
        
        // Estimate total size (rough approximation)
        const totalBytes = assets.reduce((sum, a) => sum + a.size, 0);
        const totalSizeGB = Math.round(totalBytes / 1024 / 1024 / 1024 * 10) / 10;
        
        return {
          tag: release.tag_name,
          name: release.name || release.tag_name,
          publishedAt: release.published_at,
          hasGarbageman,
          hasKnots,
          blockchainParts,
          hasContainer,
          hasVM,
          totalSizeGB,
        };
      });
      
      reply.send({
        releases: releaseInfos,
      });
      
    } catch (error) {
      fastify.log.error({ error }, 'Failed to fetch GitHub releases');
      reply.code(500).send({
        error: 'Failed to fetch releases from GitHub',
        message: error instanceof Error ? error.message : 'Unknown error',
      });
    }
  });
  
  // --------------------------------------------------------------------------
  // POST /api/artifacts/github/import - Import artifacts from GitHub release
  // --------------------------------------------------------------------------
  
  fastify.post<{
    Body: {
      tag: string;
      skipBlockchain?: boolean; // For now, we'll skip blockchain download
    };
    Reply: {
      success: boolean;
      message: string;
      artifactPath?: string;
      alreadyExists?: boolean;
    };
  }>(
    '/api/artifacts/github/import',
    async (request, reply) => {
      const { tag, skipBlockchain = true } = request.body;
      
      try {
        fastify.log.info(`Starting artifact import for release: ${tag}`);
        
        // Check if import is already in progress
        const existingProgress = importProgressMap.get(tag);
        if (existingProgress && (existingProgress.status === 'downloading' || existingProgress.status === 'reassembling')) {
          return reply.code(409).send({
            success: false,
            message: `Import already in progress for ${tag}`,
            alreadyExists: false,
          });
        }
        
        // Check if artifact already exists
        const artifactPath = `/app/.artifacts/${tag}`;
        const fs = await import('fs/promises');
        
        let existingMetadata: any = null;
        let artifactExists = false;
        
        try {
          await fs.access(artifactPath);
          artifactExists = true;
          
          // Artifact exists - check metadata
          const metadataPath = `${artifactPath}/metadata.json`;
          try {
            const metadataContent = await fs.readFile(metadataPath, 'utf-8');
            existingMetadata = JSON.parse(metadataContent);
            
            // Check if user wants blockchain but artifact doesn't have it
            const needsBlockchain = !skipBlockchain && !existingMetadata.hasBlockchain;
            
            if (!needsBlockchain) {
              // Artifact fully exists with all requested data
              fastify.log.info(`Artifact ${tag} already exists at ${artifactPath}`);
              return reply.code(200).send({
                success: true,
                message: `Artifact ${tag} is already imported`,
                artifactPath,
                alreadyExists: true,
              });
            }
            
            // Continue to download blockchain data
            fastify.log.info(`Artifact ${tag} exists but missing blockchain data, will download blockchain`);
          } catch {
            // Directory exists but no metadata - continue with full import
            fastify.log.info(`Artifact directory exists but incomplete, continuing import`);
          }
        } catch {
          // Directory doesn't exist, continue with import
        }
        
        // Fetch release details from GitHub
        const releaseResponse = await fetch(`${GITHUB_API_URL}/tags/${tag}`, {
          headers: {
            'User-Agent': 'garbageman-webui',
            'Accept': 'application/vnd.github.v3+json',
          },
          signal: AbortSignal.timeout(10000),
        });
        
        if (!releaseResponse.ok) {
          throw new Error(`GitHub API error: ${releaseResponse.status}`);
        }
        
        const release: GitHubRelease = await releaseResponse.json() as GitHubRelease;
        
        // Parse assets
        const assets = release.assets;
        const bitcoindGm = assets.find(a => a.name === 'bitcoind-gm');
        const bitcoinCliGm = assets.find(a => a.name === 'bitcoin-cli-gm');
        const bitcoindKnots = assets.find(a => a.name === 'bitcoind-knots');
        const bitcoinCliKnots = assets.find(a => a.name === 'bitcoin-cli-knots');
        const containerImage = assets.find(a => a.name === 'container-image.tar.gz');
        const sha256sums = assets.find(a => a.name === 'SHA256SUMS');
        const manifest = assets.find(a => a.name === 'MANIFEST.txt');
        
        // Create artifact directory (artifactPath and fs already declared above)
        await fs.mkdir(artifactPath, { recursive: true });
        
        fastify.log.info(`Created artifact directory: ${artifactPath}`);
        
        // Download files we need
        const downloads: Array<{ name: string; url: string }> = [];
        
        // If artifact exists and we're only adding blockchain, skip binaries
        const onlyDownloadBlockchain = artifactExists && existingMetadata && !skipBlockchain;
        
        if (!onlyDownloadBlockchain) {
          // Download checksums and manifest
          if (sha256sums) downloads.push({ name: 'SHA256SUMS', url: sha256sums.browser_download_url });
          if (manifest) downloads.push({ name: 'MANIFEST.txt', url: manifest.browser_download_url });
          
          // Download binaries
          if (bitcoindGm) downloads.push({ name: 'bitcoind-gm', url: bitcoindGm.browser_download_url });
          if (bitcoinCliGm) downloads.push({ name: 'bitcoin-cli-gm', url: bitcoinCliGm.browser_download_url });
          if (bitcoindKnots) downloads.push({ name: 'bitcoind-knots', url: bitcoindKnots.browser_download_url });
          if (bitcoinCliKnots) downloads.push({ name: 'bitcoin-cli-knots', url: bitcoinCliKnots.browser_download_url });
          
          // Download container image
          if (containerImage) downloads.push({ name: 'container-image.tar.gz', url: containerImage.browser_download_url });
        }
        
        // Download blockchain parts if requested
        if (!skipBlockchain) {
          const blockchainParts = assets.filter(a => a.name.startsWith('blockchain.tar.gz.part'));
          for (const part of blockchainParts) {
            downloads.push({ name: part.name, url: part.browser_download_url });
          }
          fastify.log.info(`Will download ${blockchainParts.length} blockchain parts`);
        }
        
        // Initialize progress tracking
        importProgressMap.set(tag, {
          tag,
          status: 'downloading',
          progress: 0,
          totalFiles: downloads.length,
          downloadedFiles: 0,
          startedAt: Date.now(),
        });
        
        // Download each file
        for (let i = 0; i < downloads.length; i++) {
          const download = downloads[i];
          fastify.log.info(`Downloading ${download.name}...`);
          
          // Update progress at start of download
          const progressStart = Math.round((i / downloads.length) * 90);
          importProgressMap.set(tag, {
            ...importProgressMap.get(tag)!,
            currentFile: download.name,
            downloadedFiles: i,
            progress: progressStart,
          });
          fastify.log.info(`Progress update: ${progressStart}% (${i}/${downloads.length} files)`);
          
          const fileResponse = await fetch(download.url, {
            signal: AbortSignal.timeout(300000), // 5 min timeout per file
          });
          
          if (!fileResponse.ok) {
            throw new Error(`Failed to download ${download.name}: ${fileResponse.status}`);
          }
          
          const buffer = Buffer.from(await fileResponse.arrayBuffer());
          const filePath = `${artifactPath}/${download.name}`;
          await fs.writeFile(filePath, buffer);
          
          // Make binaries executable
          if (download.name.startsWith('bitcoind') || download.name.startsWith('bitcoin-cli')) {
            await fs.chmod(filePath, 0o755);
          }
          
          fastify.log.info(`Downloaded ${download.name} (${buffer.length} bytes)`);
          
          // Update progress after download completes
          const progressEnd = Math.round(((i + 1) / downloads.length) * 90);
          importProgressMap.set(tag, {
            ...importProgressMap.get(tag)!,
            downloadedFiles: i + 1,
            progress: progressEnd,
          });
          fastify.log.info(`Progress update: ${progressEnd}% (${i + 1}/${downloads.length} files)`);
        }
        
        // Update progress after downloads
        importProgressMap.set(tag, {
          ...importProgressMap.get(tag)!,
          downloadedFiles: downloads.length,
          progress: 90,
        });
        
        // Reassemble blockchain parts if they were downloaded
        if (!skipBlockchain) {
          const blockchainParts = downloads.filter(d => d.name.startsWith('blockchain.tar.gz.part'));
          if (blockchainParts.length > 0) {
            fastify.log.info(`Reassembling ${blockchainParts.length} blockchain parts...`);
            
            // Update progress
            importProgressMap.set(tag, {
              ...importProgressMap.get(tag)!,
              status: 'reassembling',
              progress: 92,
            });
            
            // Sort parts by name to ensure correct order
            blockchainParts.sort((a, b) => a.name.localeCompare(b.name));
            
            // Read and concatenate all parts
            const blockchainPath = `${artifactPath}/blockchain.tar.gz`;
            const writeStream = await fs.open(blockchainPath, 'w');
            
            for (const part of blockchainParts) {
              const partPath = `${artifactPath}/${part.name}`;
              const partData = await fs.readFile(partPath);
              await writeStream.write(partData);
              // Delete part file after concatenating
              await fs.unlink(partPath);
              fastify.log.info(`Reassembled ${part.name}`);
            }
            
            await writeStream.close();
            fastify.log.info(`Blockchain reassembly complete: ${blockchainPath}`);
          }
        }
        
        // Create or update metadata file
        const metadata = existingMetadata ? {
          ...existingMetadata,
          hasBlockchain: !skipBlockchain && downloads.some(d => d.name.startsWith('blockchain.tar.gz.part')),
        } : {
          tag,
          importedAt: new Date().toISOString(),
          hasGarbageman: !!(bitcoindGm && bitcoinCliGm),
          hasKnots: !!(bitcoindKnots && bitcoinCliKnots),
          hasContainer: !!containerImage,
          hasBlockchain: !skipBlockchain && downloads.some(d => d.name.startsWith('blockchain.tar.gz.part')),
          files: downloads.map(d => d.name).filter(name => !name.startsWith('blockchain.tar.gz.part')), // Exclude parts from file list
        };
        
        await fs.writeFile(
          `${artifactPath}/metadata.json`,
          JSON.stringify(metadata, null, 2)
        );
        
        fastify.log.info(`Artifact import complete: ${tag}`);
        
        // Log event
        logArtifactImported(tag, !skipBlockchain);
        
        // Mark progress as complete
        importProgressMap.set(tag, {
          ...importProgressMap.get(tag)!,
          status: 'complete',
          progress: 100,
          completedAt: Date.now(),
        });
        
        // Clean up progress after 30 seconds
        setTimeout(() => {
          importProgressMap.delete(tag);
        }, 30000);
        
        reply.code(201).send({
          success: true,
          message: `Successfully imported artifact ${tag}`,
          artifactPath,
        });
        
      } catch (error) {
        fastify.log.error({ error }, `Failed to import artifact ${tag}`);
        reply.code(500).send({
          success: false,
          message: error instanceof Error ? error.message : 'Unknown error',
        });
      }
    }
  );
  
  // --------------------------------------------------------------------------
  // DELETE /api/artifacts/:tag - Delete an artifact
  // --------------------------------------------------------------------------
  
  fastify.delete<{
    Params: {
      tag: string;
    };
    Reply: {
      success: boolean;
      message: string;
    };
  }>(
    '/api/artifacts/:tag',
    async (request, reply) => {
      const { tag } = request.params;
      
      try {
        const artifactPath = `/app/.artifacts/${tag}`;
        const fs = await import('fs/promises');
        
        // Check if artifact exists
        try {
          await fs.access(artifactPath);
        } catch {
          return reply.code(404).send({
            success: false,
            message: `Artifact ${tag} not found`,
          });
        }
        
        // Delete the artifact directory
        await fs.rm(artifactPath, { recursive: true, force: true });
        
        fastify.log.info(`Deleted artifact: ${tag}`);
        
        // Log event
        logArtifactDeleted(tag);
        
        reply.code(200).send({
          success: true,
          message: `Successfully deleted artifact ${tag}`,
        });
        
      } catch (error) {
        fastify.log.error({ error }, `Failed to delete artifact ${tag}`);
        reply.code(500).send({
          success: false,
          message: error instanceof Error ? error.message : 'Unknown error',
        });
      }
    }
  );
  
  // --------------------------------------------------------------------------
  // POST /api/artifacts/import - Import daemon artifacts from file upload
  // --------------------------------------------------------------------------
  
  fastify.post('/api/artifacts/import', async (request, reply) => {
    fastify.log.info('=== File upload request received ===');
    
    try {
      // Parse multipart data - get fields first, then file
      fastify.log.info('Attempting to parse multipart data...');
      const data = await request.file();
      
      if (!data) {
        fastify.log.warn('No file in multipart data');
        return reply.code(400).send({
          success: false,
          message: 'No file uploaded',
        });
      }
      
      fastify.log.info(`File received: ${data.filename}, mimetype: ${data.mimetype}`);
      fastify.log.info(`Fields keys: ${JSON.stringify(Object.keys(data.fields))}`);
      
      // Extract tag from fields - check different possible structures
      let tag: string | undefined;
      
      if (data.fields.tag) {
        const tagField = data.fields.tag as any;
        // Check if it's a MultipartValue with .value property
        tag = tagField.value || tagField;
        fastify.log.info(`Tag from data.fields.tag: ${tag}`);
      }
      
      if (!tag) {
        fastify.log.warn(`Tag field missing or invalid. Fields: ${JSON.stringify(data.fields)}`);
        return reply.code(400).send({
          success: false,
          message: 'Missing required field: tag (e.g., "v29.1.0")',
        });
      }
      
      fastify.log.info(`Using tag: ${tag}`);
      
      const fileData = data;
      
      fastify.log.info(`Processing file upload: ${fileData.filename} for tag ${tag}`);
      
      // Validate file extension
      const filename = fileData.filename;
      const validExtensions = ['.tar.gz', '.tar.xz', '.zip'];
      const hasValidExtension = validExtensions.some(ext => filename.endsWith(ext));
      
      if (!hasValidExtension) {
        return reply.code(400).send({
          success: false,
          message: 'Invalid file type. Must be .tar.gz, .tar.xz, or .zip',
        });
      }
      
      // Create temp directory for upload
      const tempDir = path.join('/tmp', `artifact-upload-${Date.now()}`);
      await fs.mkdir(tempDir, { recursive: true });
      
      const tempFilePath = path.join(tempDir, filename);
      
      try {
        // Save uploaded file to temp location
        await pipeline(fileData.file, createWriteStream(tempFilePath));
        
        // Check saved file size
        const fileStats = await fs.stat(tempFilePath);
        fastify.log.info(`File saved to ${tempFilePath}, size: ${fileStats.size} bytes (${(fileStats.size / 1024 / 1024).toFixed(2)} MB), starting extraction...`);
        
        // Extract to temp directory first
        const extractDir = path.join(tempDir, 'extracted');
        await fs.mkdir(extractDir, { recursive: true });
        
        // Extract based on file type
        let extractSuccess = false;
        
        if (filename.endsWith('.tar.gz')) {
          extractSuccess = await extractTar(tempFilePath, extractDir, 'gz');
        } else if (filename.endsWith('.tar.xz')) {
          extractSuccess = await extractTar(tempFilePath, extractDir, 'xz');
        } else if (filename.endsWith('.zip')) {
          extractSuccess = await extractZip(tempFilePath, extractDir);
        }
        
        fastify.log.info(`Extraction completed: ${extractSuccess ? 'success' : 'failed'}`);
        
        if (!extractSuccess) {
          await fs.rm(tempDir, { recursive: true, force: true });
          return reply.code(500).send({
            success: false,
            message: 'Failed to extract archive',
          });
        }
        
        // Check if files are in root or in a single subfolder
        const extractedFiles = await fs.readdir(extractDir);
        let workingDir = extractDir;
        
        // If there's only one entry and it's a directory, use that as the working directory
        if (extractedFiles.length === 1) {
          const singleEntry = extractedFiles[0];
          const singleEntryPath = path.join(extractDir, singleEntry);
          const stat = await fs.stat(singleEntryPath);
          
          if (stat.isDirectory()) {
            workingDir = singleEntryPath;
            fastify.log.info(`Files are in subfolder: ${singleEntry}`);
          }
        }
        
        // List all files in working directory
        const files = await fs.readdir(workingDir);
        fastify.log.info(`Files found: ${files.join(', ')}`);
        
        // Detect which implementations are present (using correct binary names)
        const hasGarbagemanBinaries = files.includes('bitcoind-gm') || files.includes('bitcoin-cli-gm');
        const hasKnotsBinaries = files.includes('bitcoind-knots') || files.includes('bitcoin-cli-knots');
        const hasBlockchainData = files.includes('blockchain.tar.gz') || files.some(f => f.startsWith('blockchain.tar.gz.part'));
        const hasContainerImage = files.includes('container-image.tar.gz');
        
        if (!hasGarbagemanBinaries && !hasKnotsBinaries) {
          await fs.rm(tempDir, { recursive: true, force: true });
          return reply.code(400).send({
            success: false,
            message: 'Archive must contain bitcoind-gm/bitcoin-cli-gm or bitcoind-knots/bitcoin-cli-knots binaries',
          });
        }
        
        // Create destination directory
        const destDir = path.join('/app/.artifacts', tag);
        await fs.mkdir(destDir, { recursive: true });
        
        // Copy files from working directory to destination
        for (const file of files) {
          const srcPath = path.join(workingDir, file);
          const destPath = path.join(destDir, file);
          await fs.copyFile(srcPath, destPath);
          
          // Make binaries executable
          if (file.startsWith('bitcoind') || file.startsWith('bitcoin-cli')) {
            await fs.chmod(destPath, 0o755);
          }
        }
        
        // Generate metadata matching GitHub import format
        const metadata = {
          tag,
          importedAt: new Date().toISOString(),
          hasGarbageman: hasGarbagemanBinaries,
          hasKnots: hasKnotsBinaries,
          hasContainer: hasContainerImage,
          hasBlockchain: hasBlockchainData,
          importMethod: 'upload',
          filename,
          files: files,
        };
        
        await fs.writeFile(
          path.join(destDir, 'metadata.json'),
          JSON.stringify(metadata, null, 2)
        );
        
        // Clean up temp files
        await fs.rm(tempDir, { recursive: true, force: true });
        
        fastify.log.info(`Artifact imported successfully: ${tag}`);
        logArtifactImported(tag, hasBlockchainData);
        
        reply.code(200).send({
          success: true,
          message: `Artifact ${tag} imported successfully`,
          artifact: {
            tag,
            hasGarbageman: hasGarbagemanBinaries,
            hasKnots: hasKnotsBinaries,
            hasContainer: hasContainerImage,
            hasBlockchain: hasBlockchainData,
            path: destDir,
          },
        });
      } catch (error) {
        // Clean up on error
        await fs.rm(tempDir, { recursive: true, force: true });
        await fs.rm(path.join('/app/.artifacts', tag), {
          recursive: true,
          force: true,
        }).catch(() => {}); // Ignore if doesn't exist
        throw error;
      }
    } catch (error) {
      fastify.log.error({ err: error }, 'File upload error');
      return reply.code(500).send({
        success: false,
        message: (error as Error).message || 'Failed to process file upload',
      });
    }
  });
  
  // Helper function to extract tar archives
  async function extractTar(
    archivePath: string,
    destDir: string,
    compression: 'gz' | 'xz'
  ): Promise<boolean> {
    return new Promise((resolve) => {
      const flag = compression === 'gz' ? 'z' : 'J';
      const tar = spawn('tar', [`-${flag}xf`, archivePath, '-C', destDir]);
      
      tar.on('close', (code) => {
        resolve(code === 0);
      });
      
      tar.on('error', (err) => {
        fastify.log.error({ err }, 'Tar extraction error');
        resolve(false);
      });
    });
  }
  
  // Helper function to extract zip archives
  async function extractZip(archivePath: string, destDir: string): Promise<boolean> {
    return new Promise((resolve) => {
      const unzip = spawn('unzip', ['-q', archivePath, '-d', destDir]);
      
      unzip.on('close', (code) => {
        fastify.log.info(`Unzip process exited with code: ${code}`);
        resolve(code === 0);
      });
      
      unzip.on('error', (err) => {
        fastify.log.error({ err }, 'Unzip error');
        resolve(false);
      });
    });
  }
  
  // --------------------------------------------------------------------------
  // GET /api/artifacts - List imported artifacts (stub)
  // --------------------------------------------------------------------------
}
