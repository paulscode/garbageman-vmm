# Bitcoin Peer Seeds

This directory contains the `nodes_main.txt` file sourced from Libre Relay's contrib/seeds directory. This file provides high-quality Bitcoin network seed addresses used for peer discovery.

## File Format

The `nodes_main.txt` file contains Bitcoin peer addresses in three formats:

- **Tor v3 (.onion)**: `xxxxxxxxxxxxx.onion:8333` (512 addresses)
  - 56-character base32 .onion addresses (Tor v3 hidden services)
  - Port 8333 is the Bitcoin mainnet default
  
- **IPv6**: `[fcXX:XXXX:XXXX:XXXX:XXXX:XXXX:XXXX:XXXX]:8333` (495 addresses)  
  - IPv6 addresses in bracket notation
  - Can be accessed via Tor exit nodes for added privacy
  
- **I2P**: `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.b32.i2p:0` (512 addresses)
  - 52-character base32 I2P addresses
  - Port 0 indicates I2P (uses different transport)
  - Currently unsupported (no I2P proxy configured in this project)

**Total: 1,519 seed addresses**

## How Garbageman Uses These Seeds

The Tor Peer Discovery service (`webui/api/src/services/tor-peer-discovery.ts`) uses these seeds to bootstrap peer connections with privacy-first networking.

### Prioritization Strategy

Seeds are prioritized to maximize privacy while maintaining network diversity:

1. **Tor v3 addresses (highest priority)** - Direct .onion connections through Tor SOCKS5 proxy
2. **IPv6 addresses (fallback)** - Accessed through Tor exit nodes when .onion unavailable
3. **I2P addresses (skipped)** - Currently unsupported due to lack of I2P proxy

### Connection Ratio

The discovery service uses a **2-3:1 ratio** when probing seeds:
- Tries 2-3 .onion addresses for every 1 non-.onion address
- Results in ~66-75% of connections using .onion for maximum privacy
- Maintains some clearnet seed diversity for network robustness

This prioritization is implemented in `buildPrioritizedSeedList()` function within seed-parser.ts.

## Updating Seeds

When Libre Relay publishes updated seed lists, follow these steps:

1. **Download the new seeds file:**
   ```bash
   # From Libre Relay repository contrib/seeds/nodes_main.txt
   wget https://raw.githubusercontent.com/petertodd/bitcoin/libre-relay/contrib/seeds/nodes_main.txt
   ```

2. **Replace both copies:**
   ```bash
   # Update source (this directory)
   cp nodes_main.txt /path/to/garbageman-nm/seeds/
   
   # Update runtime data (used by API service)
   cp nodes_main.txt /path/to/garbageman-nm/webui/api/data/seeds/
   ```

3. **Restart services:**
   ```bash
   # Seeds are loaded once on API service startup
   docker-compose restart api
   # Or for development:
   cd webui/api && npm run dev
   ```

**Note:** The seed file in `webui/api/data/seeds/nodes_main.txt` is the operational copy read by the discovery service. This directory (`seeds/`) serves as the source-of-truth for version control.

## Seed Quality

These seeds are curated by the Libre Relay project using:
- Data from multiple Bitcoin DNS seeders
- Community-maintained peer crawlers
- Quality filtering for well-connected, responsive nodes
- Regular updates to reflect current network topology

The Libre Relay project maintains these lists specifically for privacy-focused Bitcoin nodes that need reliable Tor-capable peers.

## Source

**Original source:** [Libre Relay](https://github.com/petertodd/bitcoin) contrib/seeds directory  
**License:** Same as Bitcoin Core (MIT)  
**Maintainer:** Peter Todd and the Libre Relay community
