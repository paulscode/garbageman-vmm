# Quick Reference: Enabling HTTPS

> **Quick Start Guide** - Follow these steps to enable HTTPS  
> **For detailed scenarios:** See [TLS_SETUP.md](TLS_SETUP.md)  
> **For security considerations:** See [CADDY_SECURITY.md](CADDY_SECURITY.md)  
> **For technical implementation:** See [TLS_DEV_NOTES.md](TLS_DEV_NOTES.md)

## For Standalone Deployments Only

**⚠️ WARNING:** If you're using Start9 or Umbrel, **DO NOT** enable this. Wrappers handle HTTPS at their own layer.

---

## 1. Enable Caddy Service

Edit `devtools/compose.webui.yml` and **uncomment** the Caddy service block (around line 165):

```yaml
caddy:
  image: caddy:2-alpine
  container_name: gm-caddy
  ports:
    - "443:443"
    - "80:80"
  volumes:
    - ./Caddyfile:/etc/caddy/Caddyfile:ro
    - caddy-data:/data
    - caddy-config:/config
  networks:
    - garbageman-net
  depends_on:
    - webui-ui
    - webui-api
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:80"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 10s
```

---

## 2. Configure Domain (Production Only)

**For localhost development:** Skip this step.

**For production with a domain:**

Edit `devtools/Caddyfile` and change the first line:

```caddy
# Change from:
localhost {

# To your domain:
garbageman.yourdomain.com {
```

**Optional:** Add your email for Let's Encrypt notifications:
```caddy
garbageman.yourdomain.com {
    tls your-email@example.com
    
    # ... rest stays the same
}
```

---

## 3. Start Services

```bash
cd devtools
docker compose -f compose.webui.yml up -d
```

---

## 4. Access via HTTPS

### Localhost (Development)
- **UI:** https://localhost
- **API:** https://localhost/api

**Expected:** Browser will show certificate warning (self-signed). Click "Advanced" → "Proceed to localhost"

### Production Domain
- **UI:** https://garbageman.yourdomain.com
- **API:** https://garbageman.yourdomain.com/api

**Expected:** Trusted certificate from Let's Encrypt (no warning)

---

## Verification

### Check Caddy is Running
```bash
docker ps | grep caddy
```

### View Caddy Logs
```bash
docker logs gm-caddy
```

Look for: `"certificate obtained successfully"` (for Let's Encrypt)

### Test HTTPS Connection
```bash
curl -k https://localhost/api/health
```

Should return: `{"status":"ok"}`

---

## Troubleshooting

### Certificate Warning Won't Go Away (localhost)
**Cause:** Self-signed certificate  
**Solution:** This is normal. Click through the warning or add exception in browser settings.

### Let's Encrypt Rate Limit
**Cause:** Too many certificate requests  
**Solution:** Use staging environment for testing:
```caddy
garbageman.yourdomain.com {
    tls {
        ca https://acme-staging-v02.api.letsencrypt.org/directory
    }
    # ... rest of config
}
```

### Port 443 Already in Use
**Cause:** Another web server is running  
**Solution:** Stop the other service or change Caddy ports:
```yaml
ports:
  - "8443:443"
  - "8080:80"
```

### Certificate Not Renewing
**Check DNS:** Domain must point to your server  
**Check Ports:** 80 and 443 must be accessible from internet  
**Manual Reload:** `docker exec gm-caddy caddy reload`

---

## Disabling HTTPS

To go back to HTTP-only:

1. **Comment out Caddy service** in `compose.webui.yml`
2. **Restart:** `docker compose down && docker compose up -d`
3. **Access:** http://localhost:5173

---

## Security Notes

**Docker Volumes (Default - Safe):**
- Caddy stores certificates in Docker volumes
- Volumes are isolated and NOT tracked by Git
- Contains private keys, ACME credentials, certificates
- ✅ Safe from accidental commits

**What's Protected:**
The `.gitignore` already protects against accidental commits of:
- `caddy-data/` - TLS private keys and certificates
- `caddy-config/` - Runtime configuration cache
- `caddy.log`, `access.log` - Logs with IPs and requests
- `Caddyfile.local` - Local overrides with sensitive data

**Best Practice:**
- ✅ Use Docker volumes (the default configuration)
- ✅ Keep `devtools/Caddyfile` free of secrets
- ✅ For sensitive overrides, use `Caddyfile.local` (gitignored)
- ❌ Don't mount host directories for Caddy data

---

## Full Documentation

See [`TLS_SETUP.md`](TLS_SETUP.md) for:
- Complete deployment scenarios
- Custom certificate setup
- Security best practices
- Detailed troubleshooting

---

## Summary

| What | Where | Default |
|------|-------|---------|
| **Enable Service** | `compose.webui.yml` line 165 | Commented out |
| **Configure Domain** | `Caddyfile` line 29 | `localhost` |
| **HTTPS Port** | Host port 443 | Mapped when enabled |
| **HTTP Port** | Host port 80 | Redirects to HTTPS |

**Result:** Automatic HTTPS with zero code changes to your services.
