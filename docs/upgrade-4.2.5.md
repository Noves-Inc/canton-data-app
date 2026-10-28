# Upgrade to 4.2.5

Use the complete 4.2.5 release bundle, including the pinned backend, frontend, and database images. Keep your installation configuration, credentials, and database volume.

For Docker Compose, follow the [Compose upgrade procedure](docker-compose.md#operations-and-upgrades) with the same installation directory. Preserve `.env` and `.state`. Reload any reverse proxy that caches container addresses after recreating the containers.

For Helm, use the attached 4.2.5 chart with your own values file, following the [Helm guide](helm.md). Do not use `--reuse-values`; preserve the installation Secrets and database volume.

This patch adds no database migration beyond 4.2.4. Upgrades from earlier releases must also follow the [installation upgrade requirements](upgrade-4.2.2.md) and the [4.2.3 database and rollback guidance](upgrade-4.2.3.md).

After upgrading, confirm backend readiness, account access, and version 4.2.5 in the frontend. Check Canton Coin balances and dashboard history for your selected parties. Indexing may need time to catch up; unresolved errors should be checked through a fresh diagnostic report.
