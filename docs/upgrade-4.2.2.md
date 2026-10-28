# Upgrade to 4.2.5

4.2.5 includes the installation security requirements described below. Upgrade with the full 4.2.5 bundle, either the Docker Compose bundle or the Helm chart. Changing only the image tag is not supported: the bundle carries the configuration the new backend requires.

Upgrade directly from any published release 4.0.0 or later. Keep your installation configuration, credentials, and database volume. Take a database backup first and retain the installation KEK with it until the upgrade is verified.

4.2.5 adds no database migration beyond 4.2.4. If upgrading from before 4.2.3, the upgrade changes the database compatibility level. Returning to an older, incompatible backend requires restoring the pre-upgrade database backup; changing the image tag alone is not a rollback.

## Requirements

- Installation KEK file: the backend requires the installation KEK. Compose installations get `.state/installation-kek` when you rerun `scripts/install-compose.sh --directory <same directory>` from the 4.2.5 bundle; back it up together with the database. Helm installations that manage Secrets themselves must create the KEK and canary Secrets first, as described in [Manage the installation Secrets yourself](helm.md#manage-the-installation-secrets-yourself).
- Enrollment: the installation must be enrolled so that per-installation credentials are active. Rerunning the installer enrolls it; changing image pins alone leaves credentials disabled.
- Declare `DATABASE_VOLUME_CAPACITY` (Compose) or `backend.performance.readModel.databaseVolumeCapacity` (Helm). See [Environment variables](environment-variables.md).

## Docker Compose

Rerun `scripts/install-compose.sh --directory <same directory>` from the 4.2.5 bundle. Preserve `.env` and `.state`, including the installation KEK and certificates. See the [Compose upgrade procedure](docker-compose.md#operations-and-upgrades).

The upgrade recreates the three containers, so their addresses on the Docker network change. If a reverse proxy in front of the Data App reaches the containers by name (for example nginx `proxy_pass http://noves-canton-frontend-v4:3000`), reload it after the upgrade (`nginx -s reload`); otherwise it keeps the previous addresses and answers 502.

## Helm

Upgrade with a values file containing only your overrides, as described in [Helm installation](helm.md#4-create-application-secrets). Use the 4.2.5 chart and preserve the installation Secrets and database volume. Never use `--reuse-values`.

## Pruned participants

If your participant has pruned its ledger history, do a fresh install of 4.2.5 and run the owned-party scan backfill to recover history. An in-place upgrade cannot rebuild history the participant no longer holds.

## Verify the upgrade

Wait for backend readiness, then confirm sign-in, account access, the selected validator, and version 4.2.5 in the frontend. Check Canton Coin balances, transaction history, and exports. Background initialization may continue after startup; check unresolved errors through a fresh diagnostic report. Account access errors should be investigated separately from the plan displayed while account verification is unavailable.

Public party search, exports, and validator views require the applicable account access. Public financial, activity, and raw-data exports work without indexing the party locally. Accounting rollups and cost-basis exports still require indexed party history.

When upgrading from before 4.2.3, update CSV integrations that depended on comment preambles or machine-style report labels. New CSV downloads start with their column headers and use readable column and category names. Saved downloads retain their original contents; regenerate a report to obtain the new format.
