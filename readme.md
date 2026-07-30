# v4 of the Noves App

Self-host the Noves App next to a validator installed with the standard Canton
Helm chart or Docker Compose bundle. Both deployments use `participant:5001`. Helm uses
`http://validator-app:5003`; Compose uses `http://validator:5003` on the standard network
`splice-validator_splice_validator`.

The prerelease uses three private images:

- `noves.azurecr.io/cda-backend:prod-3e1a1fde-1785439104`
- `noves.azurecr.io/cda-frontend:prod-c78cdd33-1785419965`
- `ghcr.io/noves-inc/noves-canton-database-v4:candidate-30160846627-1`

Helm pins all three images by tag and digest. Configure `imagePullSecrets` or the
cluster registry identity before installing. Noves will replace these references when the public
v4 artifacts ship.

## Guided install

The optional setup wizard opens on localhost, verifies the participant and OIDC configuration,
and then removes itself. The host installer can stream the validator's existing
participant-admin machine credential into setup-service memory only. The credential never
reaches the browser, an app Secret, a values file, the database, or the final deployment.

Helm:

```bash
curl -fsSL https://raw.githubusercontent.com/Noves-Inc/canton-data-app/v4/install.sh | bash -s -- helm
```

Docker Compose:

```bash
curl -fsSL https://raw.githubusercontent.com/Noves-Inc/canton-data-app/v4/install.sh | bash -s -- compose
```

The wizard walks through the public application URL, Auth0 or Keycloak, and a new dedicated
capture identity. You still create the separate browser and capture clients in Auth0 or
Keycloak. The installer can pre-fill safe provider values and, after explicit confirmation,
create the matching Canton user with only `CanReadAsAnyParty`. See
[Setup wizard](docs/setup-wizard.md).

## Standard operator install

The wizard is not required. Enterprise operators can maintain values and secrets through their
usual GitOps or secret-management process:

```bash
helm upgrade --install noves-canton-data-app \
  ./chart/noves-canton-data-app \
  --namespace validator \
  --values enterprise-values.yaml
```

The chart defaults to `setupWizard.enabled=false`. It references existing Kubernetes Secrets
and never stores secret values in ordinary Helm values. Start with
[`chart/noves-canton-data-app/examples/enterprise-values.yaml`](chart/noves-canton-data-app/examples/enterprise-values.yaml)
and read [Helm installation](docs/helm.md).

For a standard Compose installation:

```bash
export APP_INSTALL_DIR=/opt/noves-canton-data-app-v4
mkdir -p "$APP_INSTALL_DIR/docker-compose/.state"
cp docker-compose/.env.example "$APP_INSTALL_DIR/docker-compose/.env"
cp docker-compose/config/nodes-config.json \
  "$APP_INSTALL_DIR/docker-compose/.state/nodes-config.json"

# Edit .env and nodes-config.json, then create capture.env and gateway.env as
# described in the full guide.
./scripts/install-compose.sh \
  --standard \
  --directory "$APP_INSTALL_DIR"
```

The installer generates the database password and accounting encryption key.
See [Docker Compose](docs/docker-compose.md) for the required identity-provider,
participant, and secret values.

## Before installation

You need:

- a running Canton validator and access to its Ledger API;
- public HTTPS URLs for the frontend/BFF and backend API;
- an Auth0 tenant or Keycloak realm;
- a browser OIDC client for users;
- a separate M2M client and matching Canton user for capture;
- a backup plan and durable storage for the shipped database container;
- for production Kubernetes, encrypted SSD-backed block storage: AKS `managed-csi-premium`,
  encrypted EKS `gp3`, GKE `premium-rwo`, or an equivalent measured on-premises class.

The Helm chart derives the backend hostname by adding `api.` to the frontend hostname. For
example, `data.example.com` uses `api.data.example.com` for the backend and its `/docs` page.
Both names can point to the same ingress address. Set `routing.backend.enabled: false` if your
edge proxy exposes only the frontend/BFF.

The capture identity must have only `CanReadAsAnyParty`. Do not reuse the validator identity.
Do not grant `ParticipantAdmin`, identity-provider administration, act-as, execute-as, or their
any-party variants. The wizard rejects those broader rights.

Compose currently requires an explicit `CANTON_NETWORK=testnet` or
`CANTON_NETWORK=devnet` on non-mainnet validators. The backend validates that setting against the
participant before capture.

## Documentation

- [Helm installation](docs/helm.md)
- [Docker Compose](docs/docker-compose.md)
- [Setup wizard](docs/setup-wizard.md)
- [Auth0](docs/authentication/auth0.md)
- [Keycloak](docs/authentication/keycloak.md)
- [Security model](docs/security.md)
- [Streams, alerts, connectors, and WebSockets](docs/streaming.md)
- [Encryption at rest](encryption_at_rest.md)
- [Migrate from v3.16.1 of the Noves App](docs/migrate-v3.16.1.md)
- [v4 upgrades and future major versions](docs/upgrades.md)

Use only the database image shipped with v4 of the Noves App. The standard routed deployment
publishes the frontend and backend on separate HTTPS hostnames. PostgreSQL, the participant
Ledger API, and setup services stay private.
