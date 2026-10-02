# Noves Data App 4.1.4 release notes (draft)

This draft is finalized in the 4.1.4 release bundle commit, which also pins the published image digests.

## Per-installation credential

Each 4.1.4 installation now proves which Noves account it belongs to and signs every account call with its own key:

1. On first start, the backend generates a signing key and stores it encrypted in the database.
2. Noves places a private enrollment challenge on the ledger that only your validator party can see. The backend reads it through its own participant connection and answers it, which binds the installation to the account that owns that validator party.
3. The backend and the frontend each run a health check through the new path. The installation then becomes active, and its account stops accepting the shared credential that earlier releases use for account functions.

Enrollment is automatic. The Admin page shows the installation status: `not enrollable` with its reason, `enrolling`, `activating`, or `active`. Until an installation is active, it behaves exactly as 4.1.3.

Account functions are the Platform API key, the Account page with its users and plan, purchases, add-ons, subscription linking, and earnings withdrawal. Indexing, ledger access, dashboards, reports, and exports do not depend on the credential.

## Before you upgrade

**Ledger connection.** Enrollment reads the challenge through the backend's participant connection, so that connection must be able to read as your validator party. An installation whose Ledger API connection or M2M indexing credential is not configured cannot enroll. The Admin page shows it as `not enrollable` with the reason, and it keeps the 4.1.3 behaviour unless another installation of the same account becomes active (see below). Data App v3 installations do not enroll either.

**New secrets, no new configuration.** Helm and the Compose installer generate two new secrets automatically:

- an installation key-encryption key (KEK), mounted only into the backend;
- a canary capability, shared by the frontend and the backend, never sent to browsers.

**Back up the KEK together with the database, and restore them together.** The database without its KEK cannot use its installation credential. Helm keeps the generated KEK Secret during uninstall and refuses to replace it while the release depends on it; the Compose installer keeps `.state/installation-kek` and refuses to replace it once it has created one. Operators who render the chart client-side, for example with Argo CD, set `installation.kek.existingSecret` and `installation.canary.existingSecret`. See [Helm installation](helm.md#4-create-application-secrets), [Docker Compose installation](docker-compose.md#installation-credential-secrets), and [Security model](security.md#installation-credential-secrets).

The Compose installer now recreates the backend and frontend containers on every run, so both read the same canary capability.

## Accounts with several installations

Many accounts link more than one validator party, for example mainnet and testnet. When the first installation of an account becomes active, the whole account stops accepting the shared credential for account functions. The account's other installations that still run an earlier release keep indexing, ledger access, dashboards, and reports, but lose the account functions listed above until they are upgraded to 4.1.4. Each upgraded installation enrolls on its own and gets those functions back automatically.

Upgrade every installation of an account in the same maintenance window to avoid the gap.

## Rolling back

After an installation becomes active, its account no longer accepts the shared credential that 4.1.3 and earlier releases use. Rolling back to one of those releases keeps indexing, ledger access, dashboards, and reports working, but loses the account functions for every installation of that account. To roll back, move to another 4.1.4 or later build and keep the same database and KEK.

## Recommended: a Ledger API audience on the participant

The backend now validates each browser sign-in through your participant before it acts on the account. The participant checks the token's audience only when its Ledger API JWT authentication is configured with one (`target-audience`). Without an audience, an access token that your identity provider issued to the same user for a different application is also accepted for that user. Configure the participant with your Ledger API audience, and keep that audience in both the browser and the M2M tokens, as the [Security model](security.md#identities) requires.
