# Noves Data App

The Noves Data App is a private block explorer and reporting suite for Canton Network. It lets you browse and filter private ledger activity, understand transactions in context, export data in reconcilable financial formats, and build applications on top of its API.

The app runs in your infrastructure and connects to your existing identity
provider. The ledger index stays in your database, and each user sees only the
parties their Canton account can read. Noves does not operate or host that
database.

## Features

You can explore transaction history, balances, rewards, and activity over time.
The app also produces CSV exports, accounting reports, cost basis reports, and
rollups. Smaller exports download in the browser. Larger transaction, cost
basis, and rollup exports run as background jobs and write to S3 or a persistent
`/exports` volume.

Alerts, connectors, and WebSocket streams make the same data available to other
systems.

Traffic cost is calculated inside the backend, with no extra collector or log
forwarding service to install.

The app also shows your validator's ledger packages, remaining synchronizer
traffic, and other tools for node operators.

The wallet supports Canton Coin and other CIP tokens. Users can send and receive
assets, keep an address book, and use any party their Canton account is allowed
to act as.

[Embedded mode](embedded-mode/embedded_mode.md) lets an approved host application
include the Data App in an iframe.

You can install and use the app without contacting Noves. A free tier is
included.

## Install

- [Install with Helm](docs/helm.md) if you use Kubernetes.
- [Install with Docker Compose](docs/docker-compose.md) if you use Docker
Compose.
- [Upgrade from v3.16.1](docs/migrate-v3.16.1.md) if you already run the latest
v3 release.

Both installation methods run the same three components: a frontend, a backend,
and a database. The release files pin compatible image versions. Each major
release also has its own `latest` image tags; if you use them, update all three
images together.

The examples start with the service names and network used by Canton's standard
deployment bundles. You can change the namespace, Docker network, participant
address, validator URL, identity provider, and routing settings to match your
environment. The installation guides list the required Secrets and environment
settings.

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
- Auth0 or Keycloak for browser sign-in and dedicated indexing user

After installation, sign in to start using the free tier. Upgrade from the
Account page if you need more history, parties, users, or features.

## Hardware requirements

Resource needs vary with the number of parties and the transaction volume on
your node. These figures are a reasonable starting point based on our
benchmarks:


| Component | CPU      | Memory  |
| --------- | -------- | ------- |
| Backend   | 1 core   | 1 GiB   |
| Database  | 1 core   | 2 GiB   |
| Frontend  | 0.5 core | 512 MiB |


As an initial estimate, allow database storage equal to about 50% of the
validator's PostgreSQL volume.

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
volume by default. You can use S3 for exports instead. Transaction history
backups can use a separate S3 destination.

A typical public deployment uses two HTTPS addresses:

```text
data.example.com      frontend and browser API
api.data.example.com  backend API and API documentation
```

You can keep the backend address private and send browser requests through the
frontend. Keep PostgreSQL and the participant Ledger API off the public
network. See [encryption at rest](encryption_at_rest.md) for storage guidance.

## Operations

The Backend Status page shows startup, capture, and materialization for the
party currently open. The backend also provides `/health`, `/ready`, and
`/startup-status` for deployment checks. The Helm and Compose guides include
commands for each endpoint.

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

Contact [support@noves.fi](mailto:support@noves.fi) for billing or deployment
support. You can also join `#noves-data-app` in the Canton Network Slack. Contact
us if you need an invitation.
