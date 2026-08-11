# Security model

## Identities

Use two distinct OIDC clients and keep the provisioning administrator separate from both:

| Identity | Purpose | Matching Canton user |
|---|---|---|
| Public browser client and human account | Interactive sign-in. The browser access token is forwarded to the selected participant. | The token's exact, case-sensitive `sub`, with only the `CanReadAs` and `CanActAs` rights appropriate for that person. |
| Confidential M2M client | Unattended backend indexing. It is never used to sign in to the UI. | The token's exact, case-sensitive `sub`, with only `CanReadAsAnyParty`. |
| Participant administrator | Creates and inspects Canton users during provisioning. | An existing participant administrator. Its credential is never stored by the Data App. |

Both browser and M2M access tokens must contain the participant Ledger API audience. The clients may have different subjects and flows, but they target the same Ledger API. Do not add the M2M client ID itself as the browser token's Ledger API audience.

Creating the M2M identity does not replace or change existing browser users. A human signs in with a normal account from the configured identity provider; the participant resolves that token's `sub` to the matching Canton user and applies that user's rights.

Create a Canton user whose ID exactly matches the M2M token's `sub`. Grant only `CanReadAsAnyParty`. Leave `participantAdmin`, `identityProviderAdmin`, `actAs`, `readAs`, `executeAs`, and `executeAsAnyParty` empty or false.

In a Canton console connected with an administrative token, the least-privilege create operation is:

```scala
participant.ledger_api.users.create(
  id = "<exact-token-subject>",
  readAsAnyParty = true
)
```

Use the participant reference name from your own Canton deployment. If the user already exists:

```scala
participant.ledger_api.users.rights.grant(
  id = "<exact-token-subject>",
  readAsAnyParty = true
)
```

List the rights afterward and remove anything broader.

## Network exposure

The standard Helm route publishes the frontend/BFF and backend API on separate HTTPS hostnames. The backend hostname exposes the complete API, including Swagger at `/docs`. Protected endpoints keep their existing authorization checks. Set `routing.backend.enabled: false` when an external gateway or the frontend/BFF is the only permitted backend entry point.

Keep the PostgreSQL Service and participant Ledger API private. The Compose bundle binds both application ports to loopback by default; expose them through a TLS reverse proxy instead of opening the container ports directly.

The backend blocks webhook delivery to private network addresses by default. Set `backend.allowPrivateWebhookTargets: true` in Helm or `ALLOW_PRIVATE_WEBHOOK_TARGETS=true` in Compose only when you trust the target and intend to deliver alerts or connector events inside a private network.

The chart enables a database ingress NetworkPolicy that accepts PostgreSQL traffic only from the release's backend pod. Broader frontend and backend policies depend on cluster-specific ingress controller, DNS, participant, identity provider, and Noves API selectors. Add those policies through your platform policy layer after verifying the required egress.

The default in-cluster participant connection is unencrypted because it stays inside the validator namespace. For cross-namespace or cross-network connections, mount the participant CA and use TLS.

## Secrets

Kubernetes values contain only Secret names. Store Secret values in your normal secret manager. Compose stores local secret files with mode `0600`. Rotate the M2M secret in the identity provider and deployment Secret together, then restart the backend.

If you're choosing an accounting provider integration (Quickbooks or Xero), Helm generates the installation's `ACCOUNTING_TOKEN_ENCRYPTION_KEY` unless `accounting.tokenEncryption.existingSecret` names an operator-managed Secret. Helm retains the generated Secret during uninstall and reuses its value during upgrades. Back it up with the database. A replacement key cannot decrypt accounting provider credentials stored with the old key.

The Compose installer applies the same rule in `.state/accounting.env`: it generates one 32-byte base64 key on first use, sets mode `0600`, and reuses the file on later runs. A manual Compose installation must create that file before starting the backend. Back it up with the database and never regenerate it during an upgrade.

Never:

- reuse a validator, wallet, or administrative credential;
- put M2M credentials in the browser OIDC client;
- publish the database or participant Ledger API;
- commit `.env`, `m2m-indexing.env`, tokens, or client secrets.

Canton-user provisioning requires an administrator credential, used only as administrator authority and never as the app's M2M indexing credential. Use your normal Canton administrator procedure for Helm and Compose installations.

## Data

The database and export volumes contain private transaction data. Encrypt storage, back it up, limit administrative access, and preserve it during ordinary upgrades. The shipped database container is the only supported database runtime.

The backend container is non-root (`1654:1654`). Its pod uses `fsGroup: 1654` with `fsGroupChangePolicy: OnRootMismatch` to make the exports PVC group-writable. Keep this setting when copying or wrapping the chart. Do not solve export-volume permissions by running the backend as root or adding a privileged volume-permissions container.

The database pod runs as its image's `postgres` account (`70:70`) with `fsGroup: 70`, `allowPrivilegeEscalation: false`, and all capabilities dropped. The pinned PostgreSQL 18 image has been tested both initializing an empty group-owned volume and restarting the initialized volume under those settings. CSI drivers must honor `fsGroup`; a driver that does not set group ownership will leave PostgreSQL unable to write the claim.

The backend alone mounts the exports PVC. The frontend reads exports through the backend API. `exports.storage: s3` removes the PVC and mount; configure bucket-side encryption and a least-privilege credentials Secret before selecting it. The independent `backup.s3` block stores transaction history backups.
