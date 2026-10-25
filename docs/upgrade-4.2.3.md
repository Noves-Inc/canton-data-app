# Upgrade to 4.2.3

Use the complete 4.2.3 release bundle: the Helm chart or Docker Compose files and all three pinned images. Keep your existing installation configuration and credentials.

## Before upgrading

Take a database backup and retain the installation KEK with it. This release upgrades the database compatibility level. Returning to an older, incompatible backend requires restoring the pre-upgrade database backup; changing the image tag alone is not a rollback.

If upgrading from a version before 4.2.2, also follow the [4.2.2 upgrade requirements](upgrade-4.2.2.md), including installation credentials, enrollment, and storage capacity configuration.

## Docker Compose

Follow the [Compose upgrade procedure](docker-compose.md#operations-and-upgrades), using the 4.2.3 bundle and the same installation directory. From the 4.2.3 checkout, rerun `scripts/install-compose.sh --directory <same installation directory>`. Preserve `.env` and `.state`, including the installation KEK and certificates. Reload any reverse proxy that caches container addresses after the containers are recreated.

## Helm

Use the attached `noves-canton-app-4.2.3.tgz` chart and your installation's values file. Follow the [Helm guide](helm.md). Do not use `--reuse-values`; keep your overrides separate from chart defaults and preserve the installation Secrets and database volume.

## Verify the upgrade

Wait for the backend to become ready, then verify sign-in, the selected validator, transaction history, and exports. Background initialization may continue after startup; views identify data that is still being prepared.

Public party search, exports, and validator views require the applicable account access. Public financial, activity, and raw-data exports work without indexing the party locally. Accounting rollups and cost-basis exports still require indexed party history.

New CSV downloads start with their column headers and use readable column and category names. Update integrations that depended on comment preambles or older machine-style report labels. Saved downloads retain the contents produced when they were created; regenerate a report to obtain the new format.
