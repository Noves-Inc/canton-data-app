# Noves Data App 4.1.4 release notes (draft)

This draft is finalized in the 4.1.4 release bundle commit, which also pins the published image digests.

## Per-installation credential

Each 4.1.4 installation now proves which Noves account it belongs to and signs every account call with its own key:

1. On first start, the backend generates a signing key and stores it encrypted in the database.
2. Noves places a private enrollment challenge on the ledger that only your validator party can see. The backend reads it through its own participant connection and answers it, which binds the installation to the account that owns that validator party.
3. The backend and the frontend each run a health check through the new path. The installation then waits until no installation of its account has used the old shared credential for 72 hours (see [Upgrade every installation of an account](#upgrade-every-installation-of-an-account)). After that it becomes active, and its account stops accepting the shared credential that earlier releases use for account functions.

Enrollment is automatic. Until an installation is active, it behaves exactly as 4.1.3.

### Check the enrollment status

Open the **Backend Status** page and find the **Installation Identity** section. It lists each node with its status:

| Status | Meaning |
|---|---|
| `Enrolling` | The installation is answering its enrollment challenge. |
| `Activating` | Enrollment succeeded. The installation is waiting for its health checks, or for the 72 hours without old shared credential use on its account. |
| `Active` | The installation signs account calls with its own credential. |
| `Not enrollable` | The installation cannot enroll. The reason is shown next to the status. |
| `Revoked` | Noves revoked the installation credential. Contact support. |

An installation can stay `Activating` for up to 72 hours after the last call from an older installation of the same account. That is expected, and every function keeps working while it waits.

Account functions are the Platform API key, the Account page with its users and plan, purchases, add-ons, subscription linking, and earnings withdrawal. Indexing, ledger access, dashboards, reports, and exports do not depend on the credential.

## Before you upgrade

**Ledger connection.** Enrollment reads the challenge through the backend's participant connection, so that connection must be able to read as your validator party. An installation whose Ledger API connection or M2M indexing credential is not configured cannot enroll. The Backend Status page shows it as `Not enrollable` with the reason, and it keeps the 4.1.3 behaviour until its account switches to per-installation credentials (see below). Data App v3 installations do not enroll either.

**New secrets, no new configuration.** Helm and the Compose installer generate two new secrets automatically:

- an installation key-encryption key (KEK), mounted only into the backend;
- a canary capability, shared by the frontend and the backend, never sent to browsers.

**Back up the KEK together with the database, and restore them together.** The database without its KEK cannot use its installation credential. Helm keeps the generated KEK Secret during uninstall and refuses to replace it while the release's live backend depends on it; renaming the release or changing `fullnameOverride` requires `installation.kek.existingSecret` pointing at the retained KEK; the Compose installer keeps `.state/installation-kek` and refuses to replace it once it has created one. Operators who render the chart client-side, for example with Argo CD, set `installation.kek.existingSecret` and `installation.canary.existingSecret`. See [Helm installation](helm.md#4-create-application-secrets), [Docker Compose installation](docker-compose.md#installation-credential-secrets), and [Security model](security.md#installation-credential-secrets).

The Compose installer now recreates the backend and frontend containers on every run, so both read the same canary capability.

## Upgrade every installation of an account

Many accounts link more than one validator party, for example mainnet and testnet, and run one Data App installation for each. **Every Data App installation that shares a Noves account must be upgraded to 4.1.4.**

The account switches to per-installation credentials automatically once none of its installations has used the old shared credential for 72 hours. Until then everything keeps working, on 4.1.3 and on 4.1.4 installations alike. An installation running 4.1.3 or an earlier release uses the shared credential on every request, so:

- **A 4.1.3 or older installation that is still running keeps the switch from happening.** The upgraded installations stay `Activating` until it is upgraded or shut down, and 72 hours have passed since its last request.
- **An installation that comes back after the switch must be upgraded.** For example, a testnet installation that was switched off for more than 72 hours and is started again on 4.1.3 keeps indexing, ledger access, dashboards, and reports, but has no account functions. Upgrade it to 4.1.4 with its own database and KEK; it enrolls as another installation of the account and gets its account functions back automatically.

After the switch, the account accepts only per-installation credentials for account functions. A new installation starts from its own empty database and enrolls on its own. A copy of an existing installation's database and KEK must never run as a second installation; see [Security model](security.md#installation-credential-secrets).

If you have upgraded every installation of the account and do not want to wait for the 72 hours to pass, contact [support@noves.fi](mailto:support@noves.fi). Support confirms with you that every installation of the account runs 4.1.4 and can then activate the account before the window ends. Any installation that still runs an earlier release loses its account functions at that moment.

## Rolling back

After the account switches to per-installation credentials, it no longer accepts the shared credential that 4.1.3 and earlier releases use. An installation rolled back to one of those releases keeps indexing, ledger access, dashboards, and reports working, but loses its account functions. Before the switch, a rollback keeps everything working and starts the 72 hour wait again, because the rolled back installation uses the shared credential. To roll back, move to another 4.1.4 or later build and keep the same database and KEK.

## Recommended: a Ledger API audience on the participant

The backend now validates each browser sign-in through your participant before it acts on the account. The participant checks the token's audience only when its Ledger API JWT authentication is configured with one (`target-audience`). Without an audience, an access token that your identity provider issued to the same user for a different application is also accepted for that user. Configure the participant with your Ledger API audience, and keep that audience in both the browser and the M2M tokens, as the [Security model](security.md#identities) requires.
