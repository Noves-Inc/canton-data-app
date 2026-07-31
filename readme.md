# Noves Data App

<img width="1906" height="911" alt="noves-data-app-dashboard" src="https://github.com/user-attachments/assets/b887b869-acf8-4719-b9ec-b6dedb4718ad" />

The Noves Data App gives Canton validators a clear view of their ledger
activity. It collects data from your participant, interprets it, and makes it
available through dashboards, reports, exports, and APIs.

The app runs in your infrastructure and connects to your existing identity
provider. Your ledger data stays under your control, and each user sees only
the parties their Canton account can read.

You can explore transaction history, balances, rewards, and activity over time.
The app also produces CSV files, accounting reports, cost basis reports, and
rollups. Alerts, connectors, and WebSocket streams make the same data available
to other systems.

Traffic cost is calculated automatically by the backend. There is no extra
collector or log forwarding service to install. Wallet tools and embedded mode
are available for deployments that need them.

<img width="1766" height="729" alt="noves-data-app-transactions" src="https://github.com/user-attachments/assets/2e242be7-0e64-47d9-b2d9-d78ec2f6c984" />

## Install

- [Install with Helm](docs/helm.md) if your validator uses the standard Canton
  Helm chart.
- [Install with Docker Compose](docs/docker-compose.md) if your validator uses
  the standard Canton Compose bundle.
- [Upgrade from v3.16.1](docs/migrate-v3.16.1.md) if you already run the latest
  v3 release.

Both installation methods run a frontend, backend, and database. The release
artifacts pin compatible images. Keep the chart or Compose files and their
image references together.

For Helm, create the Secrets and values described in the guide, then run:

```bash
helm upgrade --install noves-canton-data-app \
  ./chart/noves-canton-data-app \
  --namespace validator \
  --values enterprise-values.yaml
```

For Compose, prepare `.env` and the state files described in the guide, then
run:

```bash
./scripts/install-compose.sh --directory /opt/noves-canton-data-app
```

## What you need

- A running Canton validator with a reachable Ledger API
- Auth0 or Keycloak for browser login
- A separate machine client for data capture
- An installation credential from Noves
- Persistent database storage and a backup plan
- HTTPS addresses for the frontend and any public backend route

The capture identity needs `CanReadAsAnyParty` and no broader rights. Do not
reuse a participant administrator identity. Read the [security model](docs/security.md)
before creating credentials or exposing routes.

Initial indexing adds load to the validator and database. These numbers are a
reasonable starting point:

| Component | CPU | Memory |
|---|---:|---:|
| Backend | 1 core | 1 GiB |
| Database | 1 core | 2 GiB |
| Frontend | 0.5 core | 512 MiB |

As an initial estimate, allow database storage equal to about 70% of the
validator's PostgreSQL volume. Your transaction volume and retention policy
will determine the amount you need.

## Authentication

The frontend supports Auth0 and Keycloak through OIDC. Configure one provider:

- [Auth0 setup](docs/authentication/auth0.md)
- [Keycloak setup](docs/authentication/keycloak.md)

Users sign in with an account from your identity provider. Canton rights
determine which parties they can read. Data capture uses a separate machine
identity so the index can cover the participant without relying on a person's
browser session.

## Storage and networking

PostgreSQL stores ledger data and application metadata. Keep its volume private
and persistent. The backend stores generated exports on a persistent `/exports`
volume by default. You can use S3 storage instead. Transaction history backups
can use a separate S3 destination.

A standard public deployment uses two HTTPS addresses:

```text
data.example.com      frontend and browser API
api.data.example.com  backend API and API documentation
```

You can keep the backend address private and send browser requests through the
frontend. Keep PostgreSQL and the participant Ledger API off the public
network. See [encryption at rest](encryption_at_rest.md) for storage guidance.

## Optional features

Wallet tools require access to the validator Scan API. The wallet pages remain
unavailable when no validator URL is configured.

[Embedded mode](embedded-mode/embedded_mode.md) lets an approved parent origin
host the app in an iframe. Configure an allowlist before enabling it.

## Operations

The Backend Status page shows startup, capture, and materialization for the
party currently open. The backend also provides `/health`, `/ready`,
`/startupStatus`, and `/api/v2/capture/status` for deployment checks. The Helm
and Compose guides include commands for each endpoint.

Preserve the database, export storage, and accounting encryption key during an
upgrade or restore. Do not delete Compose volumes or Kubernetes PVCs during a
routine application upgrade.

## Documentation

- [Helm installation](docs/helm.md)
- [Docker Compose installation](docs/docker-compose.md)
- [Upgrade from v3.16.1](docs/migrate-v3.16.1.md)
- [Security model](docs/security.md)
- [Encryption at rest](encryption_at_rest.md)
- [Embedded mode](embedded-mode/embedded_mode.md)

## Support

Contact [support@noves.fi](mailto:support@noves.fi) for installation
credentials, licensing, or deployment support. Include your deployment method
and the failing health or status response. Do not send tokens, client secrets,
database passwords, or private keys.
