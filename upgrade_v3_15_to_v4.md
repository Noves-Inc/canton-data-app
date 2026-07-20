# Upgrade from Data App v3.15.0 to v4

This is the only supported Python-to-C# upgrade route. The source application and database must
be at exactly v3.15.0. Earlier v3 releases must first be upgraded to v3.15.0 and allowed to finish
their background database work.

> Do not run this procedure until the v4 release notes provide immutable public backend,
> frontend, and database image digests. A mutable `latest` tag is not acceptable for this
> major-version upgrade.

## What the upgrade does

The v4 backend owns database operations during container startup:

- It classifies and validates the existing database before changing application data.
- It converts supported user-owned configuration and metadata, including the Party Directory.
- It retains the Python `raw_txs` and `txs` tables for rollback/audit but does not import or
  classify their rows.
- It verifies that the configured Canton participant can replay history from offset zero.
- It rebuilds v4 ledger-derived tables from the participant using the backend capture identity.
- Normal application routes remain unavailable until required startup and replay work completes.

The Party Directory API and v4 frontend read the migrated directory rows. New v4 create/update
operations continue to use the same directory data.

The following items intentionally require user action:

- Accounting integrations must be reauthorized. Python Fernet ciphertext is retained for audit
  but is not copied into the v4 AES-256-GCM credential columns.
- Completed v3 accounting export artifacts and job history are retained as legacy records but
  are not served by v4. Users regenerate required exports after the upgrade.
- In-progress v3 export jobs do not resume in v4.

## Before the maintenance window

1. Confirm the running Python application reports v3.15.0.
2. Wait for all v3 background schema/data operations to finish.
3. Stop creating exports and other long-running jobs.
4. Create a database backup and restore it into a separate database. Prove the restored v3
   application starts successfully. An untested backup is not a rollback plan.
5. Record the v3 application image digests, database image digest, configuration, and secret
   names.
6. Confirm every participant retains history from offset zero. A pruned participant is not a
   supported source for this bridge.
7. Create or verify a self-renewing capture identity with the Ledger API permission needed to
   read every party the deployment indexes.
8. Record each exact participant ID and add it to the corresponding node configuration as
   `expectedParticipantId`.
9. Configure durable export storage: an S3 bucket or an encrypted persistent mount at
   `/exports`.
10. Keep the backend at one replica for the migration and hosted-worker topology.

## Required capture settings

The end-user browser login client and backend capture client are different identities. Configure
the backend capture client through secrets:

```text
M2M_INDEXER_ENABLED=true
M2M_TOKEN_ENDPOINT=https://your-issuer.example/oauth/token
M2M_CLIENT_ID=<client-id>
M2M_CLIENT_SECRET=<secret>
M2M_AUDIENCE=<ledger-api-audience>
```

Use `M2M_SCOPE` only when your identity provider requires a scope. Do not store the client
secret in a Compose file, ConfigMap, or Git.

## Maintenance-window procedure

1. Stop the v3 frontend and backend. Leave PostgreSQL running.
2. Take a final consistent database backup.
3. Apply the v4 node configuration, capture secret, export-storage configuration, and
   release-pinned images.
4. Start the v4 database and wait for `pg_isready`.
5. Start one v4 backend replica.
6. Observe the startup endpoints:

   - Liveness remains available while startup work is running.
   - `/startup-status` reports the current phase, timestamps, progress, and any terminal error.
   - Readiness is false and ordinary API routes return `503` until required work completes.

7. Do not terminate a healthy long replay merely because it takes hours. Use the reported replay
   cursor and participant ledger end to confirm progress.
8. Start or expose the v4 frontend only after the backend is ready.

The coordinator refuses before application-data mutation when the source version, schema,
participant identity, capture authorization, or offset-zero replay requirement is not satisfied.
Treat a refusal as an operator problem to correct; do not bypass the validation.

## Validation

Verify all of the following before ending the maintenance window:

- The schema journal reports the release migration head and supported compatibility epoch.
- Restarting the backend performs no duplicate bootstrap or replay work.
- Every configured node reports the expected participant ID.
- The Party Directory lists the same parties, display names, and metadata as v3.
- Directory create/update operations persist and survive a backend restart.
- Representative old and new ledger transactions, packages, balances, wallet data, and
  validator status are visible.
- The capture cursor advances and does not restart from zero after a normal restart.
- `raw_txs` and `txs` row counts/checksums are unchanged by the bridge.
- A new transaction export, cost-basis export, and rollup can be created and downloaded from the
  configured artifact provider.
- Accounting integrations show that reauthorization is required.
- `/health`, readiness, `/startup-status`, and the frontend Backend Status page agree.

## Rollback

There are no automatic down migrations.

- If v4 refuses before mutation, stop it, correct the preflight problem, or restart the pinned v3
  images against the unchanged database.
- If the database bridge or later migration committed, do not point an arbitrary older image at
  the database. Either use a release explicitly documented as compatible with the resulting
  epoch, apply a reviewed forward repair, or restore the verified pre-upgrade database backup
  and restart the pinned v3 stack.
- Restoring the database also requires restoring the matching configuration and image digests.
  Keep the failed v4 database separately until the incident has been understood.
