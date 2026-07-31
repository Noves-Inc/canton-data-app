# Noves Data App

<img width="1906" height="911" alt="noves-data-app-dashboard" src="https://github.com/user-attachments/assets/b887b869-acf8-4719-b9ec-b6dedb4718ad" />

The Noves Data App indexes, interprets, and presents data from your Canton
validator. You run it in your own infrastructure and connect it to your
existing identity provider, so ledger data stays under your control.

Version 4 includes:

- dashboards, charts, filters, and CSV exports;
- enriched transaction history for reporting and reconciliation;
- accounting, cost-basis, and rollup exports;
- traffic-cost analysis, processed by the backend with no separate collector
  or log-forwarding service;
- alerts, connectors, and WebSocket streams;
- optional wallet and embedded-mode features; and
- a dedicated PostgreSQL database for indexed data and application metadata.

<img width="1766" height="729" alt="noves-data-app-transactions" src="https://github.com/user-attachments/assets/2e242be7-0e64-47d9-b2d9-d78ec2f6c984" />

## Installation options

Choose the guide that matches your environment:

- [Install with Helm](docs/helm.md) beside a validator deployed with the
  standard Canton Helm chart.
- [Install with Docker Compose](docs/docker-compose.md) beside a validator
  deployed with the standard Canton Compose bundle.
- [Upgrade from v3.16.1](docs/migrate-v3.16.1.md) if you already run the latest
  v3 release.

Both fresh-install paths deploy three containers: the frontend, backend, and
database. The Helm chart and Compose bundle pin the matching v4 images. Use the
artifacts from one v4 release together.

After creating the Secrets and values described in the Helm guide, install the
chart with:

```bash
helm upgrade --install noves-canton-data-app \
  ./chart/noves-canton-data-app \
  --namespace validator \
  --values enterprise-values.yaml
```

For Compose, copy `.env.example`, create the state files described in the
guide, then run:

```bash
./scripts/install-compose.sh --directory /opt/noves-canton-data-app-v4
```

## Requirements

Before installation, prepare:

- a running Canton validator and network access to its Ledger API;
- an Auth0 tenant or Keycloak realm for browser login;
- a dedicated machine-to-machine client for participant-wide capture;
- an installation credential supplied by Noves;
- durable database storage and a backup plan; and
- HTTPS hostnames for the frontend and, when exposed, the backend API.

The capture identity needs `CanReadAsAnyParty` and no broader rights. Do not
reuse a participant administrator identity. See the [security model](docs/security.md)
before creating credentials or exposing routes.

Initial indexing can add load to the validator and database. Start with at
least these resources and adjust capacity based on your ledger volume:

| Component | CPU | Memory |
|---|---:|---:|
| Backend | 1 core | 1 GiB |
| Database | 1 core | 2 GiB |
| Frontend | 0.5 core | 512 MiB |

Plan database storage at about 70% of the validator PostgreSQL volume as an
initial estimate. Measure your own retention and transaction volume before
sizing production storage.

## Authentication

The frontend supports Auth0 and Keycloak through OIDC. Configure one provider:

- [Auth0 setup](docs/authentication/auth0.md)
- [Keycloak setup](docs/authentication/keycloak.md)

Users sign in with their existing identity-provider account. Canton rights
determine which parties they can read. The capture process uses a separate
machine identity so it can maintain the participant-wide index without using a
person's browser session.

## Storage and networking

PostgreSQL stores indexed ledger data and application metadata. Keep its volume
private and persistent. The backend writes generated export artifacts to a
persistent `/exports` volume by default; you can select S3-compatible storage
instead. Transaction-history backups use a separate optional S3 destination.

The standard routed deployment uses two HTTPS names:

```text
data.example.com      frontend and browser-facing API
api.data.example.com  backend API and API documentation
```

You may keep the backend hostname private and route browser requests through
the frontend. Keep PostgreSQL and the participant Ledger API off the public
network. See [encryption at rest](encryption_at_rest.md) for storage guidance.

## Optional features

Wallet features require access to the validator Scan API. The app leaves the
wallet routes unavailable when no validator URL is configured.

[Embedded mode](embedded-mode/embedded_mode.md) lets an approved parent origin
host the app in an iframe. Configure an allowlist before enabling it.

Traffic-cost analysis runs inside the v4 backend with no separate collector,
sidecar, enablement flag, or extra port.

## Operations

Use the Backend Status page to monitor startup, capture, and selected-party
materialization. The backend exposes `/health`, `/ready`, `/startupStatus`, and
`/api/v2/capture/status` for deployment checks. The Helm and Compose guides
include the commands for these endpoints.

Preserve the database, export storage, and accounting encryption key during
upgrades or restores. Never delete Compose volumes or Kubernetes PVCs as part
of a routine application upgrade.

## Documentation

- [Helm installation](docs/helm.md)
- [Docker Compose installation](docs/docker-compose.md)
- [Upgrade from v3.16.1](docs/migrate-v3.16.1.md)
- [Security model](docs/security.md)
- [Encryption at rest](encryption_at_rest.md)
- [Embedded mode](embedded-mode/embedded_mode.md)

## Support

Contact [support@noves.fi](mailto:support@noves.fi) for installation
credentials, licensing, or deployment support. Include the v4 release version,
deployment method, and the failing health or status response. Do not send
tokens, client secrets, database passwords, or private keys.
