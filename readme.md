# Noves Canton Data App v4

Self-host the Noves Canton Data App next to a validator installed with the standard Canton
Helm chart or Docker Compose bundle. The supplied defaults use the validator namespace,
`participant:5001`, `http://validator-app:5003`, and the standard Compose network
`splice-validator_splice_validator`.

The current prerelease deployment uses three private images:

- `noves.azurecr.io/cda-backend:prod-19b8de69-1785353655`
- `noves.azurecr.io/cda-frontend:prod-6110f60d-1785354653`
- `ghcr.io/noves-inc/noves-canton-database-v4:candidate-30160846627-1`

The database image is also digest-pinned in Helm values. Configure `imagePullSecrets` or the
cluster registry identity before installing. Noves will replace these references when the public
v4 artifacts ship.

## Guided install

The optional setup wizard opens on localhost, verifies the participant and OIDC configuration,
and then removes itself. The host installer can stream the validator's existing
participant-admin machine credential into setup-service memory only. The credential never
reaches the browser, a Data App Secret, a values file, the database, or the final deployment.

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
cp docker-compose/.env.example docker-compose/.env
mkdir -p docker-compose/.state
mkdir -p docker-compose/.secrets
cp docker-compose/config/nodes-config.json docker-compose/.state/nodes-config.json
# Add dedicated M2M settings to .state/capture.env and the installation
# gateway credential to .secrets/noves-gateway-auth-token, then:
chmod 600 docker-compose/.env docker-compose/.state/capture.env \
  docker-compose/.secrets/noves-gateway-auth-token
docker compose --env-file docker-compose/.env -f docker-compose/compose.yaml up -d
```

See [Docker Compose](docs/docker-compose.md) for the required files.

## Before installation

You need:

- a running Canton validator and access to its Ledger API;
- one public HTTPS URL for the frontend/BFF;
- an Auth0 tenant or Keycloak realm;
- a browser OIDC client for users;
- a separate M2M client and matching Canton user for capture;
- a backup plan and durable storage for the shipped database container;
- for production Kubernetes, encrypted SSD-backed block storage: AKS `managed-csi-premium`,
  encrypted EKS `gp3`, GKE `premium-rwo`, or an equivalent measured on-premises class.

The capture identity must have only `CanReadAsAnyParty`. Do not reuse the validator identity.
Do not grant `ParticipantAdmin`, identity-provider administration, act-as, execute-as, or their
any-party variants. The wizard rejects those broader rights.

## Documentation

- [Helm installation](docs/helm.md)
- [Docker Compose](docs/docker-compose.md)
- [Setup wizard](docs/setup-wizard.md)
- [Auth0](docs/authentication/auth0.md)
- [Keycloak](docs/authentication/keycloak.md)
- [Security model](docs/security.md)
- [Streams, alerts, connectors, and WebSockets](docs/streaming.md)
- [Encryption at rest](encryption_at_rest.md)
- [Migrate from Data App v3.16.1](docs/migrate-v3.16.1.md)
- [v4 upgrades and future major versions](docs/upgrades.md)

Only the database image shipped with Data App v4 is supported. The backend and database stay
private; only the frontend/BFF is routed to users.
