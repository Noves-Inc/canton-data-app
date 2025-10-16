# Data App - Kubernetes Deployment

## Prerequisites
- Existing Canton validator node deployed via Kubernetes (following [Splice Kubernetes deployment guide](https://docs.dev.sync.global/sv_operator/sv_helm.html))
- `kubectl` installed and configured with access to your validator cluster
- Access to the namespace where your validator is deployed (typically `validator` or similar)
- Domain with DNS access (or ability to configure DNS records)
- Auth0 or Keycloak instance with admin access
- Access to Canton participant's Ledger API (gRPC)

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Auth0 Configuration](#auth0-configuration)
3. [Namespace and Network Considerations](#namespace-and-network-considerations)
4. [Preparing Kubernetes Manifests](#preparing-kubernetes-manifests)
5. [Storage Configuration](#storage-configuration)
6. [Service Configuration](#service-configuration)
7. [Deployment Configuration](#deployment-configuration)
8. [Ingress Configuration](#ingress-configuration)
9. [Deployment](#deployment)
10. [Verification & Testing](#verification--testing)
11. [Debugging Commands](#debugging-commands)
12. [Troubleshooting](#troubleshooting)
13. [Operational Commands](#operational-commands)

---

## Architecture Overview

The Data App consists of two Kubernetes deployments:

- **Backend (`canton-data-app-backend`)**: Indexes Canton ledger data via gRPC Ledger API, enriches it, and exposes a REST API
- **Frontend (`canton-data-app-frontend`)**: UI that authenticates users via Auth0 or Keycloak (OIDC) and displays data from the backend

Both deployments run in the same Kubernetes namespace as your Canton validator node to enable direct service-to-service communication via Kubernetes DNS.

### Authentication Flow

1. User logs into frontend via Auth0 or Keycloak (OIDC provider)
2. Frontend receives JWT token from the authentication provider
3. Frontend sends user's JWT token to backend with data requests
4. Backend forwards the same JWT token to Canton's Ledger API (passthrough)
5. Canton validates JWT and returns data for authorized parties only

**Important:** The backend acts as a passthrough. It does not generate its own tokens or authenticate with the OIDC provider directly.

### Network Diagram

```
                         ┌───────────────────────────────────────┐
                         │   nginx Ingress Controller            │
                         │   (ingress-nginx ns)                  │
                         └────────────────┬──────────────────────┘
                                          │
                                          │ (Ingress Rules)
                         ┌────────────────┴──────────────────────┐
                         │ /canton → backend                     │
                         │ /       → frontend                    │
                         └────────────────┬──────────────────────┘
                                          │
                  ┌───────────────────────┴──────────────────────┐
                  │                                               │
    ┌─────────────▼──────────────┐              ┌────────────────▼────────────┐
    │  data-app-frontend         │              │  data-app-backend           │
    │  Service                   │              │  Service                    │
    └─────────────┬──────────────┘              └────────────────┬────────────┘
                  │                                               │
    ┌─────────────▼──────────────┐              ┌────────────────▼────────────┐
    │  data-app-frontend         │◄───Auth0─────│  data-app-backend           │
    │  Deployment (Pod)          │    Login     │  Deployment (Pod)           │
    │                            │──JWT Token──►│                             │
    └────────────────────────────┘              └────────────────┬────────────┘
                                                                  │
                                                                  │ JWT Passthrough
                                                                  │
                                                     ┌────────────▼────────────┐
                                                     │  Participant (Ledger    │
                                                     │  API) Service           │
                                                     └─────────────────────────┘
```

---

## Authentication Configuration

**Before proceeding with deployment, complete your authentication provider setup:**

Choose your authentication provider and complete its setup:
- **Auth0**: 📄 **[Auth0 Setup Guide](../authentication/auth0.md)**
- **Keycloak**: 📄 **[Keycloak Setup Guide](../authentication/keycloak.md)**

You'll need the following information from your chosen provider:

**For Auth0:**
- Auth0 domain (e.g., `your-tenant.us.auth0.com`)
- SPA Client ID
- Audience/API identifier (same as used by your validator)

**For Keycloak:**
- Keycloak URL (e.g., `https://keycloak.yourdomain.com`)
- Realm name
- Public Client ID
- Ensure `daml_ledger_api` scope is configured as a default scope

---

## Namespace and Network Considerations

### Namespace

Your validator node is likely deployed in a dedicated namespace. The Data App should ideally be deployed in the **same namespace** to enable seamless service-to-service communication.

Common namespace names:
- `validator` (typical for validator deployments)
- `sv` (for Super Validator deployments)
- Custom namespace specified during validator deployment

To verify your validator namespace:

```bash
# List all namespaces
kubectl get namespaces

# Find validator pods
kubectl get pods --all-namespaces | grep participant

# Example output:
# validator   participant-1-abc123   1/1   Running   0   5d
```

**For the rest of this guide, we'll use `validator` as the namespace name. Replace with your actual namespace.**

### Service DNS Names

Within the same namespace, services can be reached using short DNS names:

```
<service-name>.<namespace>.svc.cluster.local
# Or simplified (within same namespace):
<service-name>
```

For Canton validator deployments, the participant service is typically named `participant` and exposes the Ledger API on port 5001 by default. The data app backend can then reach it at:
- `participant:5001` (within same namespace)
- `participant.validator.svc.cluster.local:5001` (fully qualified - recommended)

**Note**: Port 5001 should be exposed by default in the participant deployment when deploying a validator node following the Splice documentation.

---

## Preparing Kubernetes Manifests

Create a directory for your Kubernetes manifests:

```bash
mkdir -p canton-data-app/kubernetes/manifests
cd canton-data-app/kubernetes
```

We'll create the following manifest files:
1. `persistentvolumeclaims.yaml` - Storage for backend database
2. `configmaps.yaml` - Environment variable configuration
3. `deployments.yaml` - Pod specifications
4. `services.yaml` - Internal networking
5. `ingress.yaml` - nginx Ingress routing

---

## Storage Configuration

The backend and frontend each require their own persistent storage. 

See [`manifests/persistentvolumeclaims.yaml`](manifests/persistentvolumeclaims.yaml) for the complete configuration.

**What to update:**
- Namespace (all occurrences)
- Storage sizes if needed (defaults: backend 20Gi, frontend-data 10Gi, frontend-exports 5Gi)
- `storageClassName` if your cluster requires it

**Storage Considerations:**
- **Backend data volume** (20Gi): Stores the bakcend database. Size depends on transaction volume.
- **Frontend data volume** (10Gi): Frontend application data.
- **Frontend exports volume** (5Gi): Stores CSV export files generated by the frontend.
- Each container has its own dedicated storage - they do not share volumes.
- **Access Mode**: `ReadWriteOnce` is sufficient since each volume is mounted by only one pod.
- Adjust `storage` values based on your needs and cluster capacity.
- Some clusters require `storageClassName` to be specified (check with your cluster administrator).

---

## Configuration Management

Environment variables are managed via ConfigMaps.

See [`manifests/configmaps.yaml`](manifests/configmaps.yaml) for the complete configuration.

**What to update in the ConfigMaps:**
- **Namespace**: Update in both ConfigMaps
- **CANTON_NODE_ADDR**: Update namespace if different from `validator`
- **CANTON_INDEXER_PAGE_SIZE**: Indexer page size

**For Auth0 Authentication:**
- **VITE_AUTH0_DOMAIN**: Your Auth0 tenant domain
- **VITE_AUTH0_CLIENT_ID**: Replace `<SPA_CLIENT_ID>` with your actual Auth0 SPA Client ID
- **VITE_AUTH0_AUDIENCE**: Auth0 API identifier - required for JWT tokens
- **VITE_AUTH0_REDIRECT_URI**: Replace `canton-data-ui.yourdomain.com` with your actual frontend hostname
- **VITE_AUTH0_LOGOUT_URL**: Replace `canton-data-ui.yourdomain.com` with your actual frontend hostname
- Comment out or remove Keycloak variables

**For Keycloak Authentication:**
- **VITE_KEYCLOAK_URL**: Base URL of your Keycloak server
- **VITE_KEYCLOAK_REALM**: Your Keycloak realm name
- **VITE_KEYCLOAK_CLIENT_ID**: Your Keycloak Public Client ID
- **VITE_KEYCLOAK_REDIRECT_URI**: Replace `canton-data-ui.yourdomain.com` with your actual frontend hostname
- **VITE_KEYCLOAK_LOGOUT_URL**: Replace `canton-data-ui.yourdomain.com` with your actual frontend hostname
- Comment out or remove Auth0 variables

**Note:** The presence of `VITE_KEYCLOAK_URL` triggers Keycloak authentication. Configure **either** Auth0 **or** Keycloak variables, not both.

To update configuration, edit the ConfigMap and restart the pods.

---

## Service Configuration

Services provide stable internal networking for the backend and frontend pods.

See [`manifests/services.yaml`](manifests/services.yaml) for the complete configuration.

**What to update:**
- Namespace in both services

**Note:** These services use `ClusterIP` type as they will be accessed via nginx Ingress, not directly exposed.

---

## Deployment Configuration

Deployments define the pod specifications for backend and frontend applications.

See [`manifests/deployments.yaml`](manifests/deployments.yaml) for the complete configuration.

**What to update:**
- Namespace in both deployments
- Resource limits if needed (adjust based on your cluster capacity and expected load)

**Key features:**
- Backend uses ConfigMap `data-app-backend-config` for environment variables
- Frontend uses ConfigMap `data-app-frontend-config` for environment variables
- Both mount their respective PersistentVolumeClaims

### TLS Configuration (Optional and likely not needed)

If your participant requires TLS authentication for the Ledger API (unlikely scenario, as the default Canton topology is to terminate TLS at the nginx ingress level):

#### Step 1: Create a Kubernetes Secret with the Certificate

```bash
# Obtain the participant TLS certificate
# (path depends on your validator deployment)

kubectl create secret generic participant-tls-cert \
  --from-file=participant.crt=/path/to/participant.crt \
  -n validator
```

#### Step 2: Update the Backend ConfigMap and Deployment

1. Update `manifests/configmaps.yaml`:
   ```yaml
   CANTON_NODE_CERT_FILE_PATH: "/app/certs/participant.crt"  # Changed from ""
   ```

2. Uncomment the TLS-related sections in `manifests/deployments.yaml`:
   - Uncomment the `participant-cert` volume mount in the backend container
   - Uncomment the `participant-cert` volume definition

---

## Ingress Configuration

We assume you'll be using nginx Ingress for external access. You may also use any other k8s ingress controller.

### Prerequisites

Your cluster should have:
- nginx Ingress Controller installed
- cert-manager (optional, for automatic TLS certificate management)


### Configuring Hostnames

Choose a subdomain for your Data App:

**Example:**
- Frontend: `data.validator.yourdomain.com`
- Backend (optional): `data-api.validator.yourdomain.com`

### TLS Certificate Configuration

You have two options for TLS certificates:

#### Option 1: Using cert-manager (Recommended)

If you have cert-manager installed, the Ingress manifest includes annotations to automatically provision certificates:

```yaml
annotations:
  cert-manager.io/cluster-issuer: "letsencrypt-prod"  # Update with your issuer
```

cert-manager will automatically create the TLS secret specified in the Ingress.

#### Option 2: Manual TLS Secret

Create a TLS secret manually:

```bash
# If you have a certificate and key
kubectl create secret tls data-app-frontend-tls \
  --cert=/path/to/tls.crt \
  --key=/path/to/tls.key \
  -n validator

# For backend (if separate)
kubectl create secret tls data-app-backend-tls \
  --cert=/path/to/tls.crt \
  --key=/path/to/tls.key \
  -n validator
```

If not using cert-manager, remove the `cert-manager.io/cluster-issuer` annotation from `manifests/ingress.yaml`.

### Create Ingress Configuration

See [`manifests/ingress.yaml`](manifests/ingress.yaml) for the complete Ingress configuration.

**What to update:**
- Namespace
- Hostnames (e.g., `data.validator.yourdomain.com`)
- TLS secret names
- cert-manager annotation (update or remove if not using cert-manager)
- IngressClassName if different from `nginx`

**Important Notes:**

1. **Path Order**: The `/canton` path must come before `/` to ensure API requests are routed to the backend
2. **Hostname**: Update `data.validator.yourdomain.com` with your actual domain
3. **TLS Secret**: The `secretName` must match your TLS certificate secret
4. **IngressClassName**: Ensure `nginx` matches your ingress controller's class name

### DNS Configuration

Create DNS A records pointing to your nginx ingress controller's external IP:

```bash
# Get nginx ingress controller external IP
kubectl get svc -n ingress-nginx

# Example output:
# ingress-nginx-controller   LoadBalancer   10.x.x.x   203.0.113.10   80:30080/TCP,443:30443/TCP

# Create DNS A record:
# data.validator.yourdomain.com -> 203.0.113.10
# data-api.validator.yourdomain.com -> 203.0.113.10 (if using separate backend ingress)
```

---

## Deployment (step by step)

### Step 1: Review Configuration

Before deploying, review and update all manifest files:

- [`manifests/persistentvolumeclaims.yaml`](manifests/persistentvolumeclaims.yaml) - Update namespace and storage sizes
- [`manifests/configmaps.yaml`](manifests/configmaps.yaml) - Update namespace, CANTON_NODE_ADDR, and all Auth0 configuration
- [`manifests/deployments.yaml`](manifests/deployments.yaml) - Update namespace and resource limits
- [`manifests/services.yaml`](manifests/services.yaml) - Update namespace
- [`manifests/ingress.yaml`](manifests/ingress.yaml) - Update namespace, hostnames, TLS configuration

See each section above for specific configuration details.

### Step 2: Create PersistentVolumeClaims

```bash
kubectl apply -f manifests/persistentvolumeclaims.yaml

# Verify PVCs are created
kubectl get pvc -n validator
```

### Step 3: Create ConfigMaps

```bash
kubectl apply -f manifests/configmaps.yaml

# Verify ConfigMaps are created
kubectl get configmaps -n validator | grep data-app
```

### Step 4: Create Services

```bash
kubectl apply -f manifests/services.yaml

# Verify services
kubectl get svc -n validator | grep data-app
```

### Step 5: Deploy Applications

```bash
kubectl apply -f manifests/deployments.yaml

# Watch deployment progress
kubectl get deployments -n validator -w

# Check pod status
kubectl get pods -n validator | grep data-app
```

### Step 6: Create Ingress

```bash
kubectl apply -f manifests/ingress.yaml

# Verify ingress
kubectl get ingress -n validator

# Check ingress details
kubectl describe ingress data-app-frontend -n validator
```

### Step 7: Monitor Startup

Watch logs for successful startup:

```bash
# Backend logs
kubectl logs -f deployment/data-app-backend -n validator

# Frontend logs
kubectl logs -f deployment/data-app-frontend -n validator
```

Look for:
- Backend: Connection to participant established
- Backend: Database initialized
- Frontend: Server listening on port 8091

**Note:** The backend will take approximately 2-3 minutes to index the first batch of data after startup.

---

## Verification & Testing

### Test Pod Status

```bash
# Check all pods are running
kubectl get pods -n validator | grep data-app

# Expected output:
# data-app-backend-xxxxx    1/1   Running   0   5m
# data-app-frontend-xxxxx   1/1   Running   0   5m
```

### Test Frontend Access

1. Navigate to your frontend URL (e.g., `https://data.validator.yourdomain.com`)
2. Click "Log in"
3. Authenticate with your configured provider (Auth0 or Keycloak)
4. Should see dashboard with your data

If you encounter issues, proceed to the debugging section below.

### Test Backend API Access

If you configured a separate ingress for the backend API:

```bash
# Get a JWT token (via frontend login or Auth0)
export ACCESS_TOKEN="your_jwt_token"

# Test backend API
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  https://data-api.validator.yourdomain.com/canton/parties
```

---

## Debugging Commands

### View Logs

```bash
# Backend logs
kubectl logs deployment/data-app-backend -n validator

# Follow backend logs
kubectl logs -f deployment/data-app-backend -n validator

# Frontend logs
kubectl logs deployment/data-app-frontend -n validator

# Previous pod logs (if pod crashed)
kubectl logs deployment/data-app-backend -n validator --previous

# All logs from a specific pod
kubectl logs data-app-backend-xxxxx -n validator
```

### Describe Resources

```bash
# Describe deployments
kubectl describe deployment data-app-backend -n validator
kubectl describe deployment data-app-frontend -n validator

# Describe pods
kubectl describe pod data-app-backend-xxxxx -n validator

# Describe services
kubectl describe svc data-app-backend -n validator

# Describe virtual services
kubectl describe virtualservice data-app-frontend -n validator

# Describe PVCs
kubectl describe pvc data-app-backend-pvc -n validator
```

### Check Resource Status

```bash
# All data-app resources
kubectl get all -n validator | grep data-app

# Check PVC status
kubectl get pvc -n validator | grep data-app

# Check if pods are ready
kubectl get pods -n validator -l app=data-app-backend
kubectl get pods -n validator -l app=data-app-frontend
```

### Check Ingress Configuration

```bash
# Check Ingress status
kubectl get ingress -n validator

# Describe ingress for detailed info
kubectl describe ingress data-app-frontend -n validator

# Check TLS certificate (if using cert-manager)
kubectl get certificate -n validator

# Check TLS secrets
kubectl get secret data-app-frontend-tls -n validator

# Check nginx ingress controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller
```

### Authentication Token Debugging

For authentication provider token debugging and inspection:
- **Auth0**: See [Auth0 Setup Guide - Token Inspection](../authentication/auth0.md#token-inspection)
- **Keycloak**: See [Keycloak Setup Guide - Token Inspection](../authentication/keycloak.md#token-inspection)


---

## Troubleshooting

### Backend Can't Connect to Participant

**Symptoms**: Logs show "connection refused", "connection timeout", or gRPC errors

**Solutions**:

1. Verify participant service name:
   ```bash
   kubectl get svc -n validator | grep participant
   ```

2. Check participant is running:
   ```bash
   kubectl get pods -n validator | grep participant
   ```

3. Verify `CANTON_NODE_ADDR` in deployment:
   ```bash
   kubectl get deployment data-app-backend -n validator -o yaml | grep CANTON_NODE_ADDR
   # Should show: participant.validator.svc.cluster.local:5001
   ```

4. Check if participant requires TLS:
   - If yes, ensure TLS certificate is mounted and `CANTON_NODE_CERT_FILE_PATH` is set
   - If no, ensure `CANTON_NODE_CERT_FILE_PATH` is set to empty string `""`

### Pods Not Starting

**Symptoms**: Pods stuck in `Pending`, `ImagePullBackOff`, or `CrashLoopBackOff`

**Solutions**:

1. Check pod status and events:
   ```bash
   kubectl describe pod data-app-backend-xxxxx -n validator
   ```

2. **If ImagePullBackOff**:
   - Verify you have access to `ghcr.io/noves-inc` images
   - Check if credentials are needed:
     ```bash
     kubectl create secret docker-registry ghcr-secret \
       --docker-server=ghcr.io \
       --docker-username=your-github-username \
       --docker-password=your-github-token \
       -n validator
     
     # Update deployment to use the secret
     kubectl patch deployment data-app-backend -n validator \
       -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-secret"}]}}}}'
     ```

3. **If Pending**:
   - Check PVC status: `kubectl get pvc -n validator | grep data-app`
   - Check node resources: `kubectl top nodes`
   - Check events: `kubectl get events -n validator --sort-by='.lastTimestamp'`

4. **If CrashLoopBackOff**:
   - Check logs: `kubectl logs deployment/data-app-backend -n validator --previous`
   - Common causes:
     - Invalid `CANTON_NODE_ADDR`
     - Missing or incorrect TLS certificate
     - Permission issues with mounted volumes

### Authentication Errors

**Symptoms**: "PERMISSION_DENIED" or "UNAUTHENTICATED" errors in logs or UI

**Solutions**:

See provider-specific troubleshooting:
- **Auth0**: [Auth0 Setup Guide - Troubleshooting](../authentication/auth0.md#troubleshooting-auth0-issues)
- **Keycloak**: [Keycloak Setup Guide - Troubleshooting](../authentication/keycloak.md#troubleshooting-keycloak-issues)

**Quick Checks**:

1. Verify authentication configuration in frontend deployment:
   ```bash
   # For Auth0
   kubectl get deployment data-app-frontend -n validator -o yaml | grep AUTH0
   
   # For Keycloak
   kubectl get deployment data-app-frontend -n validator -o yaml | grep KEYCLOAK
   ```

2. Test user JWT token claims:
   ```bash
   # Get token from browser or authentication provider
   echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d | jq .
   ```

3. Verify user has Canton `can_read_as` rights (see provider-specific guide)

4. Check callback URLs in your authentication provider match frontend URL exactly

5. For Keycloak: Ensure `daml_ledger_api` scope is in the token's scope claim

### No Data Showing in Dashboard

**Symptoms**: Dashboard loads but shows no transactions/data

**Solutions**:

1. Check backend logs for errors:
   ```bash
   kubectl logs deployment/data-app-backend -n validator | grep -i "error\|permission\|denied"
   ```

2. Verify backend is indexing data:
   ```bash
   # Look for indexing progress in logs
   kubectl logs deployment/data-app-backend -n validator | grep -i "index"
   ```

3. Check if user has `can_read_as` rights for parties (see Auth0 guide)

### Ingress Not Routing Correctly

**Symptoms**: 404, 502, or connection errors when accessing frontend/backend URLs

**Solutions**:

1. Verify Ingress configuration:
   ```bash
   kubectl get ingress -n validator -o yaml
   ```

2. Check Ingress status and rules:
   ```bash
   kubectl describe ingress data-app-frontend -n validator
   ```

3. Verify ingress controller is running:
   ```bash
   kubectl get pods -n ingress-nginx
   kubectl get svc -n ingress-nginx
   ```

4. Check if TLS certificate is ready:
   ```bash
   # If using cert-manager
   kubectl get certificate -n validator
   kubectl describe certificate data-app-frontend-tls -n validator
   
   # Check TLS secret exists
   kubectl get secret data-app-frontend-tls -n validator
   ```

5. Test internal service connectivity:
   ```bash
   kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n validator -- \
     curl http://data-app-frontend:8091
   ```

6. Check nginx ingress controller logs:
   ```bash
   kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=100
   ```

7. Verify DNS resolution:
   ```bash
   nslookup data.validator.yourdomain.com
   # Should point to nginx ingress controller external IP
   ```

8. Test with curl directly:
   ```bash
   # Get ingress IP
   INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   
   # Test with Host header
   curl -H "Host: data.validator.yourdomain.com" http://$INGRESS_IP
   ```

### TLS/Certificate Issues

**Symptoms**: TLS errors, certificate validation failures

**Solutions**:

1. Check if secret exists:
   ```bash
   kubectl get secret participant-tls-cert -n validator
   ```

2. Verify secret contains certificate:
   ```bash
   kubectl describe secret participant-tls-cert -n validator
   ```

3. Test with TLS disabled temporarily:
   ```bash
   # Update deployment to set CANTON_NODE_CERT_FILE_PATH to ""
   kubectl set env deployment/data-app-backend CANTON_NODE_CERT_FILE_PATH="" -n validator
   ```

### PVC Binding Issues

**Symptoms**: Pods stuck in `Pending` with "PVC is not bound" message

**Solutions**:

1. Check PVC status:
   ```bash
   kubectl get pvc -n validator | grep data-app
   ```

2. Describe PVC to see events:
   ```bash
   kubectl describe pvc data-app-backend-pvc -n validator
   ```

3. Check if storageClass is available:
   ```bash
   kubectl get storageclass
   kubectl describe storageclass <your-storage-class>
   ```

4. If no default storageClass, specify one in PVC:
   ```yaml
   spec:
     storageClassName: standard  # or your cluster's storage class
   ```

5. Check cluster has available storage:
   ```bash
   kubectl get pv
   ```

6. Verify access modes are correct:
   ```bash
   kubectl get pvc data-app-backend-pvc -n validator -o jsonpath='{.spec.accessModes}'
   # Should show: ["ReadWriteOnce"]
   
   kubectl get pvc data-app-frontend-pvc -n validator -o jsonpath='{.spec.accessModes}'
   # Should show: ["ReadWriteOnce"]
   
   kubectl get pvc data-app-frontend-exports-pvc -n validator -o jsonpath='{.spec.accessModes}'
   # Should show: ["ReadWriteOnce"]
   ```

---

## Support

This is an early-stage product. It's possible that issues will arise, and we're here to help in any way we can.

If you spot any issues or run into a snag during deployment, contact us through our shared Slack channel `#canton-data-app` (ask us for an invite link if you're not a member already).

---

## Additional Resources

- [Main README](../readme.md) - Overview and architecture
- [Auth0 Setup Guide](../authentication/auth0.md) - Detailed authentication configuration
- [Docker Compose Deployment](../docker-compose/docker_compose_deployment.md) - Alternative deployment method
- [Splice Validator Documentation](https://docs.dev.sync.global/sv_operator/sv_helm.html) - Canton validator deployment guide
- [nginx Ingress Controller Documentation](https://kubernetes.github.io/ingress-nginx/) - nginx Ingress setup and configuration
- [cert-manager Documentation](https://cert-manager.io/docs/) - Automatic TLS certificate management

