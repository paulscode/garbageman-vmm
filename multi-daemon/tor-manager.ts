/**
 * Tor Hidden Service Manager
 * 
 * Manages a single Tor process with multiple hidden services (one per instance).
 * Each instance gets its own HiddenServiceDir and unique .onion address.
 */

import * as fs from 'fs';
import * as path from 'path';
import { spawn, ChildProcess } from 'child_process';

const TOR_DATA_DIR = '/data/tor';
const TOR_CONFIG_FILE = path.join(TOR_DATA_DIR, 'torrc');
const TOR_CONTROL_PORT = 9051;
const TOR_SOCKS_PORT = 9050;

let torProcess: ChildProcess | null = null;

interface HiddenService {
  instanceId: string;
  hiddenServiceDir: string;
  p2pPort: number;
}

const hiddenServices = new Map<string, HiddenService>();

/**
 * Generate torrc configuration file with all hidden services
 */
function generateTorrc(): string {
  const lines = [
    '# Tor configuration for Garbageman multi-daemon',
    'DataDirectory /data/tor/data',
    `ControlPort ${TOR_CONTROL_PORT}`,
    'CookieAuthentication 1',
    `SocksPort ${TOR_SOCKS_PORT}`,
    '',
  ];

  // Add a hidden service for each instance
  for (const [instanceId, hs] of hiddenServices.entries()) {
    lines.push(`# Hidden service for ${instanceId}`);
    lines.push(`HiddenServiceDir ${hs.hiddenServiceDir}`);
    lines.push('HiddenServiceVersion 3');
    lines.push(`HiddenServicePort 8333 127.0.0.1:${hs.p2pPort}`);
    lines.push('');
  }

  return lines.join('\n');
}

/**
 * Write torrc configuration file
 */
function writeTorrc(): void {
  const config = generateTorrc();
  fs.writeFileSync(TOR_CONFIG_FILE, config, 'utf8');
  console.log('[Tor] Updated torrc configuration');
}

/**
 * Start the Tor daemon
 */
export async function startTor(): Promise<void> {
  if (torProcess) {
    console.log('[Tor] Already running');
    return;
  }

  // Ensure directories exist
  fs.mkdirSync(path.join(TOR_DATA_DIR, 'data'), { recursive: true });
  
  // Generate initial torrc (might be empty if no instances yet)
  writeTorrc();

  console.log('[Tor] Starting Tor daemon...');
  
  torProcess = spawn('tor', ['-f', TOR_CONFIG_FILE], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  if (torProcess.stdout) {
    torProcess.stdout.on('data', (data: Buffer) => {
      console.log(`[Tor] ${data.toString().trim()}`);
    });
  }

  if (torProcess.stderr) {
    torProcess.stderr.on('data', (data: Buffer) => {
      console.error(`[Tor] ERROR: ${data.toString().trim()}`);
    });
  }

  torProcess.on('exit', (code) => {
    console.log(`[Tor] Process exited with code ${code}`);
    torProcess = null;
  });

  torProcess.on('error', (err: Error) => {
    console.error(`[Tor] Failed to start: ${err.message}`);
    torProcess = null;
  });

  // Wait a bit for Tor to initialize
  await new Promise((resolve) => setTimeout(resolve, 3000));
  console.log('[Tor] Daemon started');
}

/**
 * Stop the Tor daemon gracefully
 */
export async function stopTor(): Promise<void> {
  if (!torProcess) {
    return;
  }

  console.log('[Tor] Stopping daemon...');
  torProcess.kill('SIGTERM');
  
  await new Promise<void>((resolve) => {
    const timeout = setTimeout(() => {
      if (torProcess) {
        console.log('[Tor] Force killing after timeout');
        torProcess.kill('SIGKILL');
      }
      resolve();
    }, 10000);

    torProcess!.once('exit', () => {
      clearTimeout(timeout);
      torProcess = null;
      resolve();
    });
  });

  console.log('[Tor] Daemon stopped');
}

/**
 * Reload Tor configuration (SIGHUP)
 */
function reloadTor(): void {
  if (!torProcess || !torProcess.pid) {
    console.log('[Tor] Not running, cannot reload');
    return;
  }

  console.log('[Tor] Reloading configuration...');
  torProcess.kill('SIGHUP');
}

/**
 * Add a hidden service for an instance
 */
export async function addHiddenService(instanceId: string, p2pPort: number): Promise<void> {
  const hiddenServiceDir = path.join(TOR_DATA_DIR, 'hidden-services', instanceId);
  
  // Create hidden service directory
  fs.mkdirSync(hiddenServiceDir, { recursive: true, mode: 0o700 });
  
  // Store hidden service info
  hiddenServices.set(instanceId, {
    instanceId,
    hiddenServiceDir,
    p2pPort,
  });

  // Update torrc and reload
  writeTorrc();
  
  if (torProcess) {
    reloadTor();
    // Wait for Tor to generate the onion address
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }

  console.log(`[Tor] Added hidden service for ${instanceId} on port ${p2pPort}`);
}

/**
 * Remove a hidden service for an instance
 */
export async function removeHiddenService(instanceId: string): Promise<void> {
  const hs = hiddenServices.get(instanceId);
  if (!hs) {
    return;
  }

  hiddenServices.delete(instanceId);
  
  // Update torrc and reload
  writeTorrc();
  
  if (torProcess) {
    reloadTor();
  }

  // Optionally remove the hidden service directory
  // (keeping it preserves the .onion address for potential re-use)
  console.log(`[Tor] Removed hidden service for ${instanceId}`);
}

/**
 * Get the .onion address for an instance
 */
export function getOnionAddress(instanceId: string): string | null {
  const hs = hiddenServices.get(instanceId);
  if (!hs) {
    return null;
  }

  const hostnameFile = path.join(hs.hiddenServiceDir, 'hostname');
  
  if (!fs.existsSync(hostnameFile)) {
    return null;
  }

  try {
    return fs.readFileSync(hostnameFile, 'utf8').trim();
  } catch (err) {
    console.error(`[Tor] Failed to read hostname for ${instanceId}:`, err);
    return null;
  }
}

/**
 * Initialize Tor manager (load existing hidden services from disk)
 */
export function initializeTorManager(): void {
  const hiddenServicesDir = path.join(TOR_DATA_DIR, 'hidden-services');
  
  if (!fs.existsSync(hiddenServicesDir)) {
    fs.mkdirSync(hiddenServicesDir, { recursive: true });
    return;
  }

  // Scan for existing hidden service directories
  // This would need to be coordinated with instance configs
  // For now, we'll register them when instances are loaded
}
