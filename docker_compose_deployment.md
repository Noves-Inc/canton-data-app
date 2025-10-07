# Canton Data App - Docker Compose Deployment

## Prerequisites
- Docker & Docker Compose
- Existing Canton validator node
- Domain with DNS access
- Auth0 account

## Quick Setup

### 1. DNS Setup
Create DNS records:
- `canton-translate.yourdomain.com` → Your server IP
- `canton-translate-ui.yourdomain.com` → Your server IP

### 2. Auth0 Configuration

1. Create SPA application in Auth0
2. Set callback URL: `https://canton-translate-ui.yourdomain.com/callback`
3. Set logout URL: `https://canton-translate-ui.yourdomain.com`
4. Note: Domain and Client ID

Depending on your auth0 setup, you should have an Machine to Machine application with a `${CLIENT_ID}@clients` user which has 

### 3. Update Environment Variables
Edit `compose.yaml`:
```yaml
VITE_AUTH0_DOMAIN: "your-tenant.auth0.com"
VITE_AUTH0_CLIENT_ID: "your_client_id"
VITE_AUTH0_REDIRECT_URI: "https://canton-translate-ui.yourdomain.com/callback"
VITE_AUTH0_LOGOUT_URL: "https://canton-translate-ui.yourdomain.com"
```

### 4. Nginx Configuration
The following steps are exclusive to the existing nginx setup. If you are using a different setup, you can skip these steps and adjust the configuration accordingly.

Also, this assumes you have an SSL setup for the domain `*.yourdomain.com`.

1. Create a DNS entry of type A for the services in your domain pointing to the server IP.
    a. `canton-translate-ui.yourdomain.com`
    b. `canton-translate.yourdomain.com`
2. Update domains in `canton-data-app.conf` to
    a. `canton-translate-ui.yourdomain.com`
    b. `canton-translate.yourdomain.com`
3. include the `canton-data-app.conf` file in the nginx configuration.

A simple and modular way to manage the nginx configuration is to have the provided nginx configuration file included in the main nginx configuration file.

```nginx
include /etc/nginx/conf.d/nginx/canton-data-app.conf;
```

### Useful commands

### Networking setup
Canton-translate port is hardcoded to 8080