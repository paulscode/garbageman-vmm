# WebUI Authentication

## Overview

The Garbageman WebUI uses JWT-based authentication to secure access. The system is designed to work seamlessly in both wrapper environments (Start9/Umbrel) and standalone deployments.

## Architecture

### Components

1. **Authentication Route** (`webui/api/src/routes/auth.ts`)
   - `POST /api/auth/login` - Login endpoint
   - `POST /api/auth/validate` - Token validation endpoint
   - JWT generation and verification
   - Rate limiting (10 attempts/minute)

2. **Auth Middleware** (`webui/api/src/server.ts`)
   - Protects all API endpoints except `/api/health` and `/api/auth/*`
   - Validates JWT tokens in Authorization header
   - Returns 401 on invalid/expired tokens

3. **Client Authentication** (`webui/ui/src/app/page.tsx`)
   - Password dialog on startup
   - JWT token storage in sessionStorage
   - Authenticated fetch wrapper for all API calls
   - Auto-lock on token expiration

## Password Configuration

### For Wrapper Deployments (Start9/Umbrel)

Set the password via environment variable:

```bash
WRAPPER_UI_PASSWORD=your_password_from_wrapper
```

Wrappers should inject this variable when starting the webui-api container.

### For Standalone Deployments

**Option 1: Set custom password**
```bash
WEBUI_PASSWORD=your_secure_password
```

**Option 2: Auto-generated password (default)**

If no password is configured, the system generates a secure random password on startup and logs it to the console:

```
═══════════════════════════════════════════════════════════
⚠️  NO PASSWORD CONFIGURED - GENERATED RANDOM PASSWORD
═══════════════════════════════════════════════════════════
WebUI Password: kJ8xL2mP9qR4tY6wZ3nB5vC7dF1gH0j
To set a custom password, use environment variable:
  WEBUI_PASSWORD=your_secure_password
For wrapper deployments (Start9/Umbrel), use:
  WRAPPER_UI_PASSWORD=<password_from_wrapper>
═══════════════════════════════════════════════════════════
```

## Security Features

### Server-Side Validation
- All password validation happens on the server
- Client cannot bypass authentication
- Prevents password exposure in client code

### Rate Limiting
- Login endpoint: 10 attempts per minute
- Prevents brute force attacks
- Failed attempts logged with IP address

### Constant-Time Comparison
- Uses `crypto.timingSafeEqual()` for password comparison
- Prevents timing attacks
- 1-second delay on failed login attempts

### JWT Token Security
- 24-hour token expiration
- HMAC-SHA256 signature
- Tokens stored in sessionStorage (cleared on browser close)
- Automatic re-authentication on expiration

### Protected Endpoints
All API endpoints except health and auth require valid JWT:
- `/api/instances/*` - Instance management
- `/api/artifacts/*` - Artifact management
- `/api/events/*` - Event feed
- `/api/peers/*` - Peer discovery

## Usage Example

### Login Flow

```typescript
// Client requests authentication
const response = await fetch('http://localhost:8080/api/auth/login', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ password: 'your_password' })
});

const { success, token } = await response.json();

if (success) {
  // Store token
  sessionStorage.setItem('auth_token', token);
}
```

### Authenticated API Requests

```typescript
// Add token to all API requests
const token = sessionStorage.getItem('auth_token');

const response = await fetch('http://localhost:8080/api/instances', {
  headers: {
    'Authorization': `Bearer ${token}`
  }
});

// 401 response = expired token, re-authenticate
if (response.status === 401) {
  // Show login dialog
  sessionStorage.removeItem('auth_token');
}
```

## Development

### Testing Authentication

```bash
# Get a token
curl -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"password":"your_password"}'

# Use token for API calls
TOKEN="<token_from_above>"

curl http://localhost:8080/api/instances \
  -H "Authorization: Bearer $TOKEN"
```

### Customizing Token Expiry

Edit `TOKEN_EXPIRY_MS` in `webui/api/src/routes/auth.ts`:

```typescript
const TOKEN_EXPIRY_MS = 24 * 60 * 60 * 1000; // 24 hours
```

### Customizing Rate Limits

Edit rate limit in `webui/api/src/routes/auth.ts`:

```typescript
{
  config: {
    rateLimit: {
      max: 10, // attempts per timeWindow
      timeWindow: '1 minute',
    },
  },
}
```

## Deployment Notes

### Docker Compose

```yaml
services:
  webui-api:
    environment:
      # For wrapper deployments
      - WRAPPER_UI_PASSWORD=${UI_PASSWORD}
      
      # For standalone deployments
      - WEBUI_PASSWORD=my_secure_password
      
      # Optional: Custom JWT secret
      - JWT_SECRET=your_secret_key_here
```

### Kubernetes

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: webui-auth
type: Opaque
stringData:
  password: "your_secure_password"
---
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: webui-api
        env:
        - name: WEBUI_PASSWORD
          valueFrom:
            secretKeyRef:
              name: webui-auth
              key: password
```

## Migration from Stub Password

The hardcoded stub password (`admin`) has been completely removed:

1. ✅ Client-side password check removed
2. ✅ Server-side JWT authentication implemented
3. ✅ All API endpoints protected
4. ✅ Environment-based configuration

**Action Required:** Set `WRAPPER_UI_PASSWORD` or `WEBUI_PASSWORD` environment variable before deploying.

## Troubleshooting

### "Authentication required" error

- Check that token is present in sessionStorage
- Verify token hasn't expired (24 hours)
- Check browser console for errors

### "Invalid password" error

- Verify correct password is set in environment
- Check API logs for failed login attempts
- Ensure rate limit not exceeded (10/min)

### Auto-generated password not showing

- Check API container logs on startup
- Look for the password warning message
- Ensure no `WEBUI_PASSWORD` or `WRAPPER_UI_PASSWORD` is set

## Security Considerations

### Production Deployment

1. **Use HTTPS** - Authentication over HTTP exposes tokens
2. **Secure Password** - Use strong, randomly generated passwords
3. **Monitor Logs** - Watch for failed login attempts
4. **Rotate Secrets** - Change JWT_SECRET periodically
5. **Network Isolation** - Use firewall rules to limit access

### Future Enhancements

- [ ] HTTP-only cookies instead of sessionStorage
- [ ] Refresh tokens for longer sessions
- [ ] Multi-factor authentication (MFA)
- [ ] OAuth2/OIDC integration
- [ ] Certificate-based authentication
- [ ] User roles and permissions
