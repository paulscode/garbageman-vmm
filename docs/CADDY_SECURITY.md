# Caddy Security Checklist

## ✅ Repository Security

### Files Safe to Commit
- ✅ `devtools/Caddyfile` - Configuration only, no secrets
- ✅ `docs/TLS_SETUP.md` - Documentation
- ✅ `docs/ENABLE_HTTPS.md` - Quick reference
- ✅ `devtools/compose.webui.yml` - Service commented out by default
- ✅ `.gitignore` - Protects sensitive data

### Files NEVER to Commit (Protected by .gitignore)
- ❌ `caddy-data/` - TLS certificate private keys
- ❌ `caddy-config/` - Runtime cache, may contain tokens
- ❌ `.caddy/` - ACME account credentials
- ❌ `caddy/data/` - Alternative data directory
- ❌ `caddy/config/` - Alternative config directory
- ❌ `caddy/logs/` - Access logs with IPs and requests
- ❌ `caddy.log` - Error logs
- ❌ `access.log` - Access logs
- ❌ `Caddyfile.local` - User overrides with secrets
- ❌ `*.caddy.local` - Any local Caddy configs

## 🔒 What Caddy Stores

### In Docker Volumes (Default - Isolated)
```yaml
volumes:
  caddy-data:      # Certificates, private keys, ACME accounts
  caddy-config:    # Runtime configuration, cache
```

**Security:** ✅ Isolated from Git, safe by default

### Sensitive Data Contained
1. **TLS Private Keys**
   - Location: `caddy-data/certificates/`
   - Risk: Complete TLS compromise if leaked
   - Protection: Docker volume + .gitignore

2. **ACME Account Credentials**
   - Location: `caddy-data/acme/`
   - Risk: Unauthorized certificate issuance
   - Protection: Docker volume + .gitignore

3. **Let's Encrypt Tokens**
   - Location: `caddy-data/acme/`
   - Risk: Domain validation bypass
   - Protection: Docker volume + .gitignore

4. **Access Logs**
   - Location: Container `/var/log/caddy/`
   - Contains: IP addresses, User-Agents, request paths, timestamps
   - Risk: Privacy violation, reconnaissance data
   - Protection: Not mounted to host by default

## ⚠️ Risks if Using Host Directories

**DON'T do this:**
```yaml
volumes:
  - ./caddy-data:/data        # ❌ Exposes private keys on host
  - ./caddy-config:/config    # ❌ Exposes cache on host
```

**If you must use host directories:**
1. Ensure directory is in `.gitignore` (already done)
2. Set proper file permissions: `chmod 700 caddy-data/`
3. Regular backups to encrypted storage
4. Never commit, push, or share these directories

## 🛡️ Security Best Practices

### Development (Localhost)
- ✅ Use Docker volumes (default)
- ✅ Self-signed certificates expected
- ✅ No public exposure needed
- ✅ Browser warnings are normal

### Production (Public Domain)
- ✅ Use Docker volumes (default)
- ✅ Let's Encrypt automatic certificates
- ✅ Regular Caddy image updates
- ✅ Monitor certificate expiration
- ✅ Backup caddy-data volume to encrypted storage
- ✅ Firewall rules: only 80/443 exposed
- ✅ Keep Caddyfile free of secrets

### Wrapper Deployments (Start9/Umbrel)
- ❌ **DO NOT enable Caddy service**
- ✅ Wrappers handle TLS at their layer
- ✅ Services run HTTP-only internally

## 📋 Pre-Commit Checklist

Before committing changes:

- [ ] No `caddy-data/` directory in repository
- [ ] No `caddy-config/` directory in repository
- [ ] No `Caddyfile.local` or `*.caddy.local` files
- [ ] No log files (`caddy.log`, `access.log`)
- [ ] Caddyfile contains no API keys or passwords
- [ ] Caddyfile contains no production domain secrets
- [ ] `.gitignore` still contains Caddy patterns

**Quick Test:**
```bash
git status --short | grep -iE "caddy-data|caddy-config|\.caddy|caddy\.log|access\.log|Caddyfile\.local"
```

**Expected:** No output (all patterns ignored)

## 🔍 Audit Commands

### Check for Exposed Secrets
```bash
# Search repository for accidentally committed keys
git log --all --full-history --source -- "**/caddy-data/*" "**/caddy-config/*"

# Expected: No results
```

### Verify .gitignore Working
```bash
# Create test sensitive files
touch caddy.log access.log
mkdir -p caddy-data caddy-config

# Check git status
git status --short

# Expected: No mention of these files
```

### Check Docker Volume Contents
```bash
# List Caddy data volume contents (safe to inspect)
docker run --rm -v gm-caddy-data:/data alpine ls -la /data

# You should see: certificates/, acme/, locks/
```

## 🚨 If Secrets Are Committed

**Immediate Actions:**

1. **Remove from Git history:**
   ```bash
   # Use BFG Repo Cleaner or git filter-repo
   git filter-repo --path caddy-data/ --invert-paths
   git filter-repo --path caddy-config/ --invert-paths
   ```

2. **Revoke compromised credentials:**
   - Revoke all Let's Encrypt certificates
   - Generate new ACME account
   - Request new certificates

3. **Rotate affected certificates:**
   ```bash
   docker volume rm gm-caddy-data
   docker compose down
   docker compose up -d  # Fresh start
   ```

4. **Force push cleaned history:**
   ```bash
   git push --force-with-lease origin webui
   ```

5. **Notify users to re-clone:**
   - Anyone who cloned the compromised repo should delete and re-clone

## ✅ Current Protection Status

Based on implementation (November 8, 2025):

| Protection | Status | Notes |
|------------|--------|-------|
| .gitignore patterns | ✅ Implemented | 11 patterns covering all sensitive paths |
| Docker volumes default | ✅ Implemented | No host mounts in default config |
| Documentation warnings | ✅ Implemented | TLS_SETUP.md, ENABLE_HTTPS.md |
| Caddyfile sanitized | ✅ Verified | No secrets, only examples |
| Service opt-in | ✅ Implemented | Commented out by default |
| Test validation | ✅ Passed | Sensitive files properly ignored |

**Result:** ✅ Repository is secure against accidental Caddy secret commits.

---

**Last Updated:** November 8, 2025  
**Validated:** Yes  
**Risk Level:** Low (with proper Docker volume usage)
