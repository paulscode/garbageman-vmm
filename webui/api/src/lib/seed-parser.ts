/**
 * Seed Parser Utility
 * ====================
 * Parses Libre Relay seed files (nodes_main.txt format) and categorizes
 * addresses by type (.onion, IPv6, I2P, etc.)
 * 
 * File Format (from Libre Relay contrib/seeds):
 * - IPv6 addresses: [fcXX:XXXX:...]:port
 * - Tor v3 addresses: xxxxx.onion:port
 * - I2P addresses: xxxxx.b32.i2p:port
 * 
 * We prioritize .onion addresses for privacy and can use IPv6 via Tor proxy
 * as fallback. I2P addresses are currently unsupported (no I2P proxy configured).
 */

import fs from 'fs/promises';
import path from 'path';

export enum SeedAddressType {
  ONION = 'onion',      // Tor v3 .onion addresses
  IPV6 = 'ipv6',        // IPv6 addresses (accessed via Tor proxy)
  I2P = 'i2p',          // I2P addresses (currently unsupported)
  UNKNOWN = 'unknown'
}

export interface SeedAddress {
  host: string;
  port: number;
  type: SeedAddressType;
  raw: string;  // Original line from file
}

export interface ParsedSeeds {
  onion: SeedAddress[];
  ipv6: SeedAddress[];
  i2p: SeedAddress[];
  unknown: SeedAddress[];
  total: number;
}

/**
 * Parse a single line from the seeds file
 */
function parseSeedLine(line: string): SeedAddress | null {
  const trimmed = line.trim();
  
  // Skip empty lines and comments
  if (!trimmed || trimmed.startsWith('#')) {
    return null;
  }

  // Remove inline comments (e.g., "address:port # AS12345")
  const withoutComment = trimmed.split('#')[0].trim();
  if (!withoutComment) {
    return null;
  }

  let host: string;
  let port: number;
  let type: SeedAddressType;

  // Match .onion addresses: xxxxx.onion:port
  const onionMatch = withoutComment.match(/^([a-z0-9]{16,56}\.onion):(\d+)$/);
  if (onionMatch) {
    host = onionMatch[1];
    port = parseInt(onionMatch[2], 10);
    type = SeedAddressType.ONION;
    return { host, port, type, raw: withoutComment };
  }

  // Match IPv6 addresses: [fcXX:XXXX:...]:port
  const ipv6Match = withoutComment.match(/^\[([a-f0-9:]+)\]:(\d+)$/);
  if (ipv6Match) {
    host = ipv6Match[1];
    port = parseInt(ipv6Match[2], 10);
    type = SeedAddressType.IPV6;
    return { host, port, type, raw: withoutComment };
  }

  // Match IPv4 addresses: X.X.X.X:port
  const ipv4Match = withoutComment.match(/^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d+)$/);
  if (ipv4Match) {
    host = ipv4Match[1];
    port = parseInt(ipv4Match[2], 10);
    // We support IPv4 via Tor proxy, so treat it like IPv6
    type = SeedAddressType.IPV6;  // Group with IPv6 as "clearnet via Tor"
    return { host, port, type, raw: withoutComment };
  }

  // Match I2P addresses: xxxxx.b32.i2p:port
  const i2pMatch = withoutComment.match(/^([a-z0-9]{52}\.b32\.i2p):(\d+)$/);
  if (i2pMatch) {
    host = i2pMatch[1];
    port = parseInt(i2pMatch[2], 10);
    type = SeedAddressType.I2P;
    return { host, port, type, raw: withoutComment };
  }

  // Unknown format - skip silently (likely a format we don't support)
  return null;
}

/**
 * Parse a seeds file and categorize addresses by type
 */
export async function parseSeedsFile(filePath: string): Promise<ParsedSeeds> {
  try {
    const content = await fs.readFile(filePath, 'utf-8');
    const lines = content.split('\n');

    const result: ParsedSeeds = {
      onion: [],
      ipv6: [],
      i2p: [],
      unknown: [],
      total: 0
    };

    for (const line of lines) {
      const seed = parseSeedLine(line);
      if (!seed) continue;

      result.total++;

      switch (seed.type) {
        case SeedAddressType.ONION:
          result.onion.push(seed);
          break;
        case SeedAddressType.IPV6:
          result.ipv6.push(seed);
          break;
        case SeedAddressType.I2P:
          result.i2p.push(seed);
          break;
        default:
          result.unknown.push(seed);
      }
    }

    console.log(`[SeedParser] Parsed ${result.total} seeds: ${result.onion.length} onion, ${result.ipv6.length} IPv6, ${result.i2p.length} I2P, ${result.unknown.length} unknown`);

    return result;
  } catch (error) {
    console.error(`[SeedParser] Error reading seeds file ${filePath}:`, error);
    throw error;
  }
}

/**
 * Shuffle an array in place using Fisher-Yates algorithm
 */
function shuffleArray<T>(array: T[]): T[] {
  const shuffled = [...array];
  for (let i = shuffled.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
  }
  return shuffled;
}

/**
 * Build a prioritized seed list with .onion addresses preferred
 * 
 * Strategy: Interleave 2-3 .onion addresses for every 1 other address type
 * This gives .onion addresses ~66-75% of connection attempts while still
 * maintaining some diversity for peer discovery.
 * 
 * @param seeds Parsed seeds
 * @param onionRatio Number of .onion addresses to try between other types (default: 2-3 randomly)
 * @returns Shuffled array with .onion addresses prioritized
 */
export function buildPrioritizedSeedList(
  seeds: ParsedSeeds,
  onionRatio: { min: number; max: number } = { min: 2, max: 3 }
): Array<{ host: string; port: number }> {
  // Shuffle each category independently
  const shuffledOnion = shuffleArray(seeds.onion);
  const shuffledOthers = shuffleArray([...seeds.ipv6]); // Only use IPv6, skip I2P for now
  
  const result: Array<{ host: string; port: number }> = [];
  let onionIndex = 0;
  let othersIndex = 0;

  // Interleave with random ratio between min and max
  while (onionIndex < shuffledOnion.length || othersIndex < shuffledOthers.length) {
    // Add 2-3 .onion addresses
    const onionCount = Math.floor(Math.random() * (onionRatio.max - onionRatio.min + 1)) + onionRatio.min;
    for (let i = 0; i < onionCount && onionIndex < shuffledOnion.length; i++) {
      const seed = shuffledOnion[onionIndex++];
      result.push({ host: seed.host, port: seed.port });
    }

    // Add 1 other address type
    if (othersIndex < shuffledOthers.length) {
      const seed = shuffledOthers[othersIndex++];
      result.push({ host: seed.host, port: seed.port });
    }
  }

  console.log(`[SeedParser] Built prioritized list: ${result.length} total seeds`);
  return result;
}

/**
 * Load and parse the default mainnet seeds file
 */
export async function loadMainnetSeeds(dataDir: string = './data/seeds'): Promise<ParsedSeeds> {
  const seedsPath = path.join(dataDir, 'nodes_main.txt');
  return parseSeedsFile(seedsPath);
}
