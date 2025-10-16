# Kubernetes Deployment for Canton Data App

This directory contains Kubernetes manifests and deployment instructions for the Canton Data App.

## Quick Start

1. **Complete authentication setup first**: Choose your authentication provider:
   - **Auth0**: [../authentication/auth0.md](../authentication/auth0.md)
   - **Keycloak**: [../authentication/keycloak.md](../authentication/keycloak.md)

2. **Follow the deployment guide**: [kubernetes_deployment.md](kubernetes_deployment.md)

3. **Update the manifests** in `manifests/` directory with your actual values:
   - Namespace
   - Participant service name
   - Authentication provider credentials (Auth0 or Keycloak)
   - Hostnames
   - Ingress configuration

4. **Deploy**:
   ```bash
   kubectl apply -f manifests/persistentvolumeclaims.yaml
   kubectl apply -f manifests/configmaps.yaml
   kubectl apply -f manifests/services.yaml
   kubectl apply -f manifests/deployments.yaml
   kubectl apply -f manifests/ingress.yaml
   ```

## Files in This Directory

- **kubernetes_deployment.md**: Comprehensive deployment guide with troubleshooting
- **manifests/**: Kubernetes YAML manifests (templates)
  - `persistentvolumeclaims.yaml`: Storage for backend database
  - `configmaps.yaml`: Environment variable configuration
  - `services.yaml`: ClusterIP services for backend and frontend
  - `deployments.yaml`: Pod specifications
  - `ingress.yaml`: nginx Ingress routing

## Prerequisites

- Existing Canton validator node deployed via Kubernetes
- Access to the validator's namespace
- nginx Ingress Controller installed
- Auth0 or Keycloak instance configured with appropriate client
- TLS certificates (or cert-manager for automatic provisioning)

## Documentation

For complete deployment instructions, see: [kubernetes_deployment.md](kubernetes_deployment.md)

For architecture and overview, see: [../readme.md](../readme.md)

