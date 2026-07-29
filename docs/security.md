# Security model

## Identities

Use two distinct OIDC clients:

- a public browser client for user sign-in;
- a confidential M2M client used only by backend capture.

Create a Canton user whose ID exactly matches the M2M token's `sub`. Grant only
`CanReadAsAnyParty`. Leave `participantAdmin`, `identityProviderAdmin`, `actAs`, `readAs`,
`executeAs`, and `executeAsAnyParty` empty or false.

During a guided installation, the host installer may read the validator's existing
participant-admin machine credential and stream it to setup-service memory only. The browser
never receives it. The setup service exchanges it for a short-lived token, verifies the
administrator subject and `ParticipantAdmin`, and may create or grant only
`CanReadAsAnyParty`. It clears the credential after completion, shutdown, or two hours. The
administrator credential and token are absent from the capture Secret, chart values, Compose
files, logs, database, setup result, and final deployment.

In a Canton console connected with an administrative token, the least-privilege create
operation is:

```scala
participant.ledger_api.users.create(
  id = "<exact-token-subject>",
  readAsAnyParty = true
)
```

Use the participant reference name from your own Canton deployment. If the user already
exists:

```scala
participant.ledger_api.users.rights.grant(
  id = "<exact-token-subject>",
  readAsAnyParty = true
)
```

List the rights afterward and remove anything broader. The Data App wizard performs the same
rights check before activation.

## Network exposure

Only the frontend/BFF receives public routing. Keep the backend, PostgreSQL Service, participant
Ledger API, and setup verification route private. Use HTTPS for the public application URL.

The chart enables a database ingress NetworkPolicy that accepts PostgreSQL traffic only from the
release's backend pod. Broader frontend and backend policies depend on cluster-specific ingress
controller, DNS, participant, identity-provider, and Noves API selectors. Add those policies through
your platform policy layer after verifying the required egress.

The default in-cluster participant connection is unencrypted because it stays inside the
validator namespace. For cross-namespace or cross-network connections, mount the participant
CA and use TLS.

## Secrets

Kubernetes values contain only Secret names. Store Secret values in your normal secret manager.
Compose stores local secret files with mode `0600`. Rotate the M2M secret in the identity
provider and deployment Secret together, then restart the backend.

Helm generates the installation's `ACCOUNTING_TOKEN_ENCRYPTION_KEY` unless
`accounting.tokenEncryption.existingSecret` names an operator-managed Secret. Helm retains the
generated Secret during uninstall and reuses its value during upgrades. Back it up with the
database. A replacement key cannot decrypt accounting provider credentials stored with the old
key.

The Noves gateway credential is installation-specific and separate from both OIDC clients. In
Kubernetes it is referenced through `novesGateway.existingSecret`. In Compose it is mounted from
`.secrets/noves-gateway-auth-token`. Rotate it in the source secret, restart both backend and
frontend, and verify readiness without printing the credential.

Never:

- reuse a validator, wallet, or administrative credential;
- put M2M credentials in the browser OIDC client;
- publish the backend or database;
- give the wizard a validator Secret or a broad Kubernetes Role;
- commit `.env`, `capture.env`, tokens, or client secrets.

The exception to “never reuse an administrator credential” is the transient guided provisioning
step described above: it uses the existing validator credential as administrator authority, never
as the Data App capture credential. Standard Helm and Compose installations do not require this
assisted path.

## Data

The database and export volumes contain private transaction data. Encrypt storage, back it up,
limit administrative access, and preserve it during ordinary upgrades. The shipped database
container is the only supported database runtime.

The backend container is non-root (`1654:1654`). Its pod uses `fsGroup: 1654` with
`fsGroupChangePolicy: OnRootMismatch` to make the exports PVC group-writable. Keep this setting when
copying or wrapping the chart. Do not solve export-volume permissions by running the backend as root
or adding a privileged volume-permissions container.

The database pod runs as its image's `postgres` account (`70:70`) with `fsGroup: 70`,
`allowPrivilegeEscalation: false`, and all capabilities dropped. The pinned PostgreSQL 18 image has
been tested both initializing an empty group-owned volume and restarting the initialized volume
under those settings. CSI drivers must honor `fsGroup`; a driver that does not set group ownership
will leave PostgreSQL unable to write the claim.

The backend alone mounts the exports PVC. The frontend reads exports through the backend API.
`exports.storage: s3` removes the PVC and mount; configure bucket-side encryption and a
least-privilege credentials Secret before selecting it. The independent `backup.s3` block stores
transaction-history backups.
