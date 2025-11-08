# Contributing to Garbageman Nodes Manager

Thanks for your interest in contributing! This project provides a web-based control plane for managing multiple Bitcoin daemon instances (Garbageman/Knots) with peer discovery, artifact management, and Tor integration.

## Project Overview

Garbageman NM consists of:
- **WebUI** (`webui/ui/`) - React/Next.js frontend with dark neon aesthetic
- **API Server** (`webui/api/`) - Express/TypeScript backend with peer discovery services
- **Multi-Daemon Supervisor** (`multi-daemon/`) - Process manager for Bitcoin daemon instances
- **Tor Integration** - SOCKS5 proxy for privacy-preserving peer discovery
- **TUI Script** (`garbageman-nm.sh`) - Bash-based menu system for container/VM deployments and artifact generation

### Component Roles

**WebUI (Primary Interface):**
- Modern web-based management for multiple daemon instances
- Real-time monitoring, peer discovery, artifact management
- Development focus for new features

**TUI Script (Production Deployment & Artifacts):**
- Generates release artifacts (pre-built binaries, pre-synced blockchains)
- Manages container-based and VM-based deployments
- Handles system-level configuration (networking, storage, isolation)
- Production-ready tooling for operators

Both components are actively maintained and serve complementary roles.

---

## How to Contribute

### Reporting Bugs

If you find a bug, please open an issue with:
- **Component affected**: UI, API, supervisor, Tor discovery, etc.
- **Environment**: OS, Docker version, Node.js version, browser (for UI issues)
- **Steps to reproduce**: Detailed reproduction steps
- **Expected vs actual behavior**: What should happen vs what does happen
- **Logs**: Relevant console output, API logs, browser console errors
- **Screenshots**: For UI issues, include screenshots or screen recordings

### Suggesting Features

Feature requests are welcome! Please open an issue describing:
- **The problem**: What are you trying to accomplish?
- **Proposed solution**: How should it work?
- **Alternative approaches**: Any other ways to solve this?
- **Component**: Which part of the system would this affect?
- **Priority**: Nice-to-have or critical for your use case?

### Submitting Code

1. **Fork the repository** and create a feature branch
2. **Set up development environment** (see Development Setup below)
3. **Make your changes** following code style guidelines
4. **Test thoroughly** (see Testing Checklist below)
5. **Update documentation** - README.md, inline comments, and relevant .md files
6. **Submit a pull request** with a clear description and any relevant issue references

---

## Development Setup

### Prerequisites

- **Docker** 20.10+ with Docker Compose v2+
- **Node.js** 18+ (for local development without Docker)
- **Git** for version control
- **Tor** (optional, for testing Tor peer discovery)

### Quick Start

**For WebUI development:**
```bash
# Clone the repository
git clone https://github.com/paulscode/garbageman-nm.git
cd garbageman-nm

# Start all services with Docker Compose
cd devtools
make up

# Services will be available at:
# - UI: http://localhost:5173
# - API: http://localhost:8080
# - Supervisor: http://localhost:9000
# - Tor SOCKS5: localhost:9050
```

**For TUI script work:**
```bash
# The TUI script is standalone and requires only bash
./garbageman-nm.sh

# For testing artifact generation:
# 1. Use the menu to build Garbageman/Knots from source
# 2. Generate pre-synced blockchain data
# 3. Package artifacts for distribution

# See QUICKSTART.md for detailed TUI usage
```

### Local Development (without Docker)

**API Server:**
```bash
cd webui/api
npm install
npm run dev  # Starts on port 8080 with hot reload
```

**UI:**
```bash
cd webui/ui
npm install
npm run dev  # Starts on port 5173 with hot reload
```

**Multi-Daemon Supervisor:**
```bash
cd multi-daemon
npm install
npm run dev  # Starts on port 9000
```

### Useful Commands

From `devtools/` directory:

```bash
make help       # Show all available commands
make logs       # Tail all service logs
make api        # View API logs only
make ui         # View UI logs only
make supervisor # View supervisor logs only
make tor        # View Tor proxy logs
make restart    # Restart all services
make clean      # Stop and remove all containers
make rebuild    # Clean + build + start
```

---

## Code Style Guidelines

### TypeScript (API & UI)

- **Formatting**: Use 2-space indentation
- **Naming**:
  - `PascalCase` for types, interfaces, classes, components
  - `camelCase` for variables, functions, methods
  - `UPPER_SNAKE_CASE` for constants
- **Types**: Prefer explicit types over `any`
- **Comments**: Use JSDoc for functions, clear inline comments for complex logic
- **Imports**: Group by external → internal → relative, alphabetize within groups
- **Async/Await**: Prefer over `.then()` chains
- **Error Handling**: Always handle promise rejections and errors

**Example:**
```typescript
/**
 * Discovers Bitcoin peers via Tor network
 * @param maxPeers Maximum number of peers to discover
 * @returns Array of discovered onion peers
 */
async function discoverTorPeers(maxPeers: number): Promise<OnionPeer[]> {
  try {
    const peers = await torDiscoveryService.probe(maxPeers);
    return peers.filter(p => p.networkType === NetworkType.TORV3);
  } catch (error) {
    console.error('[TorDiscovery] Failed to discover peers:', error);
    throw new Error('Tor peer discovery failed');
  }
}
```

### React/Next.js (UI)

- **Components**: Use functional components with hooks
- **File naming**: `PascalCase.tsx` for components, `camelCase.ts` for utilities
- **Props**: Define explicit prop types with TypeScript interfaces
- **State**: Use appropriate hooks (`useState`, `useEffect`, `useCallback`, etc.)
- **Styling**: Use Tailwind CSS classes, CSS variables for theme colors
- **Accessibility**: Include ARIA labels, keyboard navigation support

### Bash Scripts (TUI)

- **Indentation**: 4 spaces (not tabs)
- **Safety**: Use `set -euo pipefail` at script start for error handling
- **Quoting**: Always quote variables: `"$variable"` to prevent word splitting
- **Functions**: Add header comments documenting purpose, parameters, and return values
- **Error handling**: Check command exit codes, provide clear error messages to users
- **User feedback**: Show progress for long operations, confirm destructive actions
- **Testing**: Test on clean system, verify all menu options work correctly
- **shellcheck**: Run `shellcheck garbageman-nm.sh` and fix warnings before submitting

**Key areas for TUI contributions:**
- Artifact generation and packaging
- Container/VM instance management
- System-level configuration (networking, storage)
- Build automation for Garbageman/Knots from source
- Pre-sync blockchain data generation

---

## Testing Checklist

### Before Submitting a PR

**General:**
- [ ] Code follows style guidelines above
- [ ] No TypeScript errors (`tsc --noEmit`)
- [ ] No ESLint warnings in modified files
- [ ] Documentation updated (README.md, inline comments, .md files)
- [ ] No sensitive data in commits (API keys, IPs, private keys)
- [ ] Git history is clean (squash WIP commits if needed)

**UI Changes:**
- [ ] Tested in Chrome/Firefox
- [ ] Responsive design works (mobile, tablet, desktop)
- [ ] No console errors or warnings
- [ ] Dark theme colors are consistent
- [ ] Keyboard navigation works
- [ ] Loading states and error states display correctly

**API Changes:**
- [ ] Endpoints return correct status codes
- [ ] Error responses include helpful messages
- [ ] Input validation works (reject invalid data)
- [ ] No memory leaks (long-running services)
- [ ] Logs include helpful debug information

**Peer Discovery Changes:**
- [ ] Tor connections work via SOCKS5 proxy
- [ ] No clearnet IP exposure (verify with network monitoring)
- [ ] Handles Tor unavailability gracefully
- [ ] Seed addresses load correctly
- [ ] Only .onion addresses saved to database

**Instance Management Changes:**
- [ ] Daemons start and stop cleanly
- [ ] Config files generated correctly
- [ ] Logs are accessible and useful
- [ ] Process cleanup on failures
- [ ] Port conflicts detected and handled

**TUI Script Changes:**
- [ ] All menu options work without errors
- [ ] User prompts are clear and accurate
- [ ] Destructive operations require confirmation
- [ ] Error messages explain what went wrong and how to fix it
- [ ] Tested on clean system (verify dependencies are documented)
- [ ] shellcheck passes with no warnings
- [ ] Works with both systemd and non-systemd systems (if applicable)

### Manual Testing

**For WebUI changes:**

1. **Start fresh environment**: `make clean && make up`
2. **Import artifact**: Test GitHub import
3. **Create instance**: Test instance creation with mainnet/testnet
4. **Start instance**: Verify daemon starts and syncs
5. **Peer discovery**: Check clearnet and Tor peer discovery
6. **Stop instance**: Verify clean shutdown
7. **View logs**: Check all log outputs are useful

**For TUI script changes:**

1. **Fresh system test**: Test on clean VM or container
2. **Menu navigation**: Verify all options display and work correctly
3. **Artifact generation**: Build from source, generate artifacts
4. **Instance creation**: Create and start daemon instances
5. **Error handling**: Test invalid inputs, missing dependencies
6. **Cleanup**: Verify proper cleanup of temp files and processes

---

## Component-Specific Guidelines

### Working on Peer Discovery

**Files:**
- `webui/api/src/services/peer-discovery.ts` - Clearnet DNS-based discovery
- `webui/api/src/services/tor-peer-discovery.ts` - Tor-based .onion discovery
- `webui/api/src/routes/peers.ts` - API endpoints

**Key considerations:**
- All Tor connections must use SOCKS5 proxy (never direct sockets)
- Only save .onion addresses to database (filter IPv4/IPv6)
- Respect rate limiting and backoff periods
- Handle network errors gracefully
- Log security events (rejected addresses, Tor unavailability)

**Testing:**
```bash
# Verify Tor connections
sudo ss -tunap | grep 9050  # Should only see Tor proxy connections

# Check for clearnet leaks
sudo tcpdump -i any -n 'port 8333 and not host 127.0.0.1'  # Should be empty
```

### Working on Instance Management

**Files:**
- `multi-daemon/supervisor.stub.ts` - Instance lifecycle management
- `webui/api/src/routes/instances.ts` - Instance API endpoints
- `webui/ui/src/components/NodeCard.tsx` - Instance UI component

**Key considerations:**
- Validate all user inputs (paths, ports, network types)
- Generate unique instance IDs
- Handle port conflicts gracefully
- Clean up resources on failures
- Provide clear error messages

### Working on UI

**Files:**
- `webui/ui/src/app/page.tsx` - Main dashboard
- `webui/ui/src/components/` - React components
- `webui/ui/src/styles/` - CSS and theme

**Key considerations:**
- Follow dark neon orange aesthetic
- Use CSS variables from `tokens.css`
- Maintain responsive design (mobile-first)
- Add loading and error states
- Keep components small and focused

### Working on TUI Script

**Files:**
- `garbageman-nm.sh` - Main TUI script

**Key areas:**
- **Artifact generation**: Building from source, packaging binaries, pre-syncing blockchain data
- **Instance management**: Creating, starting, stopping container/VM-based instances
- **System configuration**: Network setup, storage allocation, isolation
- **Build automation**: Compiling Garbageman/Knots with proper dependencies

**Key considerations:**
- Test on fresh system (Ubuntu, Debian) to verify all dependencies work
- Handle missing dependencies gracefully (check before use, suggest installation)
- Provide clear progress feedback for long-running operations
- Confirm destructive operations (deletion, cleanup) before executing
- Document system requirements in README if adding new dependencies
- Ensure compatibility with both container and VM deployments
- Keep menu structure logical and easy to navigate

**Testing specific to TUI:**
```bash
# Run shellcheck
shellcheck garbageman-nm.sh

# Test on clean Ubuntu/Debian system
lxc launch ubuntu:22.04 test-gm
lxc exec test-gm bash
# ... run script and test menu options ...

# Verify artifact generation
# 1. Build from source
# 2. Check artifact integrity
# 3. Verify artifacts can be imported in WebUI
```

---

## Documentation Standards

### Code Comments

- **Why, not what**: Explain reasoning, not obvious syntax
- **Context**: Note non-obvious dependencies or constraints
- **TODOs**: Use `TODO:` prefix for future improvements
- **Security**: Call out security-sensitive operations

### Markdown Documentation

- **Headers**: Use ATX style (`#`, `##`, not underlines)
- **Code blocks**: Always specify language for syntax highlighting
- **Links**: Use descriptive text, not "click here"
- **Examples**: Include real, working examples
- **Updates**: Keep documentation in sync with code changes

---

## Git Workflow

### Branch Naming

- `feature/description` - New features
- `fix/description` - Bug fixes
- `docs/description` - Documentation updates
- `refactor/description` - Code restructuring

### Commit Messages

Use clear, descriptive commit messages:

```
Short summary (50 chars or less)

More detailed explanation if needed. Wrap at 72 characters.
Explain the problem being solved and why this approach was chosen.

- Bullet points are fine
- Reference issues: Fixes #123, Related to #456
```

**Good examples:**
- `Add Tor peer discovery with BIP155 support`
- `Fix IPv6 address formatting in addnode configuration`
- `Update QUICKSTART.md with accurate Tor discovery details`

**Bad examples:**
- `Fixed stuff`
- `WIP`
- `asdf`

---

## Getting Help

- **Questions?** Open a discussion or issue
- **Stuck?** Check existing issues or documentation
- **Security concerns?** See SECURITY.md for responsible disclosure

---

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
