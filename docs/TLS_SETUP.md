# TLS/HTTPS Deployment Guide

> **Audience:** End users deploying Garbageman WebUI  
> **Purpose:** Step-by-step instructions for enabling HTTPS  
> **Note:** This is a user-facing deployment guide.  
> **For Developers:** See [TLS_DEV_NOTES.md](TLS_DEV_NOTES.md) for technical details

## Overview

Garbageman WebUI supports optional TLS/HTTPS through a Caddy reverse proxy. This is designed for **standalone deployments only**. If you're using a wrapper project like **Start9** or **Umbrel**, you should **NOT** enable this - those platforms handle TLS at their own reverse proxy layer.

## Deployment Scenarios

### Scenario 1: Local Development (HTTP Only)

**Best for:** Fast iteration, local testing, no security requirements

```bash
# Standard docker compose (no TLS)
docker compose -f devtools/compose.webui.yml up
```

Access:
- UI: http://localhost:5173
- API: http://localhost:8080

**Security:** None. Use only on trusted local networks.

---

### Scenario 2: Standalone with Self-Signed Certificates

**Best for:** Private networks, internal deployments, testing HTTPS locally

#### Step 1: Enable Caddy Service

Edit `devtools/compose.webui.yml` and uncomment the `caddy` service block (lines ~160-180).

#### Step 2: Start Services

```bash
docker compose -f devtools/compose.webui.yml up
```

#### Step 3: Access via HTTPS

Access:
- UI: https://localhost
- API: https://localhost/api

**Expected:** Browser will show a certificate warning for the self-signed certificate. This is normal - click "Advanced" and "Proceed to localhost" (or equivalent in your browser).

**Security:** Encrypted traffic, but certificate is not trusted by browsers.

---

### Scenario 3: Production with Let's Encrypt

**Best for:** Public internet deployments with a domain name

#### Prerequisites

- Domain name pointing to your server's public IP
- Ports 80 and 443 accessible from the internet
- Server with persistent storage

#### Step 1: Configure Domain

Edit `devtools/Caddyfile`:

```caddy
# Change this line:
localhost {

# To your domain:
garbageman.yourdomain.com {
```

Optionally, add your email for Let's Encrypt notifications:

```caddy
garbageman.yourdomain.com {
    tls your-email@example.com
    
    # ... rest of config
}
```

#### Step 2: Enable Caddy Service

Edit `devtools/compose.webui.yml` and uncomment the `caddy` service block.

#### Step 3: Update API Base URL

Edit `devtools/compose.webui.yml` in the `webui-ui` service:

```yaml
environment:
  NEXT_PUBLIC_API_BASE: https://garbageman.yourdomain.com/api
```

#### Step 4: Start Services

```bash
docker compose -f devtools/compose.webui.yml up -d
```

#### Step 5: Verify Let's Encrypt Certificate

Caddy will automatically:
1. Request a certificate from Let's Encrypt
2. Prove domain ownership via HTTP-01 challenge
3. Install the certificate
4. Renew automatically before expiration

Check logs:
```bash
docker logs gm-caddy
```

Look for: `"certificate obtained successfully"`

#### Step 6: Access via HTTPS

Access: https://garbageman.yourdomain.com

**Security:** Full encryption with browser-trusted certificate. Automatic renewal every 60 days.

---

### Scenario 4: Production with Custom Certificates

**Best for:** Enterprise deployments with internal CA

#### Step 1: Prepare Certificates

Place your certificate files somewhere accessible:
```
/path/to/certs/
├── fullchain.pem  (certificate + intermediate chain)
└── privkey.pem    (private key)
```

#### Step 2: Configure Caddy

Edit `devtools/Caddyfile`:

```caddy
garbageman.yourdomain.com {
    tls /certs/fullchain.pem /certs/privkey.pem
    
    # ... rest of config
}
```

#### Step 3: Mount Certificates

Edit `devtools/compose.webui.yml` in the `caddy` service:

```yaml
caddy:
  # ... other config
  volumes:
    - ./Caddyfile:/etc/caddy/Caddyfile:ro
    - caddy-data:/data
    - caddy-config:/config
    - /path/to/certs:/certs:ro  # Add this line
```

#### Step 4: Start Services

```bash
docker compose -f devtools/compose.webui.yml up -d
```

---

## Wrapper Deployments (Start9/Umbrel)

**DO NOT enable the Caddy service** if you're deploying within a wrapper project.

Wrappers like Start9 and Umbrel provide their own reverse proxy infrastructure that handles:
- TLS/HTTPS termination
- Certificate management
- Domain routing
- Access control

The Garbageman WebUI services should run in **HTTP-only mode** and let the wrapper handle HTTPS. The standard `compose.webui.yml` configuration (without Caddy) is designed for this use case.

---

## Troubleshooting

### Certificate Warning on localhost

**Expected behavior.** Self-signed certificates are not trusted by browsers. Click through the warning or add an exception.

### Let's Encrypt Rate Limits

Let's Encrypt has rate limits:
- 50 certificates per registered domain per week
- 5 failed validation attempts per account per hour

For testing, use the staging environment:

```caddy
garbageman.yourdomain.com {
    tls {
        ca https://acme-staging-v02.api.letsencrypt.org/directory
    }
    # ... rest of config
}
```

### Port 80/443 Already in Use

If you're already running a web server:

**Option A:** Run Caddy on different ports
```yaml
caddy:
  ports:
    - "8443:443"
    - "8080:80"
```

**Option B:** Use your existing web server as the reverse proxy instead of Caddy.

### Check Caddy Health

```bash
docker exec gm-caddy caddy health
docker logs gm-caddy
```

### Certificate Renewal Failed

Caddy automatically renews certificates 30 days before expiration. If renewal fails:

1. Check domain DNS still points to your server
2. Ensure ports 80/443 are accessible
3. Check Caddy logs: `docker logs gm-caddy`
4. Manually trigger renewal: `docker exec gm-caddy caddy reload`

---

## Security Best Practices

1. **Use HTTPS in Production**: Always enable TLS for public deployments
2. **Keep Caddy Updated**: Update the image regularly for security patches
3. **Monitor Certificate Expiration**: Although Caddy auto-renews, set up monitoring
4. **Firewall Rules**: Only expose ports 80/443, keep 5173/8080/9000 internal
5. **Regular Backups**: Backup Caddy data volume (contains certificates)
6. **Strong Ciphers**: Caddy uses modern TLS 1.2+ by default
7. **HSTS**: Enabled by default in the Caddyfile (forces HTTPS)

### Protecting Sensitive Caddy Data

**Docker Volumes (Recommended):**
- By default, Caddy uses Docker volumes for data storage
- Volumes are isolated and NOT tracked by Git
- Contains: private keys, ACME credentials, certificates
- Safe from accidental commits

**Host Directories (Advanced Users):**
If you mount host directories instead of volumes:

```yaml
volumes:
  - ./caddy-data:/data        # ⚠️ DANGER: Contains private keys
  - ./caddy-config:/config    # Contains runtime cache
```

**NEVER commit these directories!** They contain:
- TLS certificate private keys
- Let's Encrypt ACME account credentials
- Certificate chains with your domain info
- Access logs with IP addresses and request patterns

The repository's `.gitignore` already protects against common patterns:
```gitignore
caddy-data/
caddy-config/
.caddy/
caddy/data/
caddy/config/
caddy/logs/
```

**Best Practice:** Use Docker volumes (the default) to avoid any risk.

### Caddyfile Security

The `devtools/Caddyfile` in the repository is safe to commit:
- ✅ Contains only configuration (no secrets)
- ✅ Example comments for production domains
- ✅ No hardcoded emails or credentials
- ✅ Security headers and logging configuration

**User Customization:**
If you add sensitive data to your Caddyfile (not recommended):
- API keys for DNS providers
- Authentication credentials
- Internal network topology details

Consider creating `Caddyfile.local` (gitignored) for sensitive overrides.

---

## Architecture

```
Internet
    ↓
[Caddy :443] ← TLS termination, security headers, HTTPS
    ↓
    ├→ [webui-ui :5173] ← Next.js frontend
    └→ [webui-api :8080] ← Fastify API
```

**Benefits:**
- Zero code changes to services
- Optional/opt-in for standalone deployments
- No interference with wrapper projects
- Industry-standard TLS with Caddy
- Automatic certificate management

---

## Additional Resources

- [Caddy Documentation](https://caddyserver.com/docs/)
- [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/)
- [TLS Best Practices](https://wiki.mozilla.org/Security/Server_Side_TLS)
