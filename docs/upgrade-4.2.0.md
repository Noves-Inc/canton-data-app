# Upgrade to 4.2.0

Upgrade directly from any published release 4.0.0 or later. The schema upgrade is verified from 4.0.0, 4.0.3, 4.0.4, 4.1.0, 4.1.1 and 4.1.3 through 4.1.6. Installing 4.1.6 first is not required.

Before upgrading:

1. Take a database backup and keep it until the upgrade is verified. Startup migrations change the schema, and there is no downgrade below 4.2.0 once they have run.
2. Declare `DATABASE_VOLUME_CAPACITY` for the database volume. Without it the volume brake is not evaluated and index reclaim does not run. Helm installations that use an existing claim or migration mode must set `backend.performance.readModel.databaseVolumeCapacity`; Compose installations set `DATABASE_VOLUME_CAPACITY` in `.env`. See [Environment variables](environment-variables.md).
3. Check free space on the database volume. The rebuilt history uses a new indexed layout that stays about 50% larger than the history it replaces, and during the rebuild the volume also holds the previous copy until each party switches over. Keep free space of at least the current history size before upgrading.

On first start the backend rebuilds the transaction history in the background, one party at a time. The app keeps serving the previous history for each party until its rebuilt copy replaces it, and the database is temporarily larger while both copies exist.

## Docker Compose

Rerun `scripts/install-compose.sh --directory <same directory>` from the 4.2.0 bundle. Changing image pins alone leaves per-installation credentials disabled. An installation older than 4.1.4 gets a new `.state/installation-kek` file on that run; back it up together with the database. See the [Compose upgrade procedure](docker-compose.md#upgrade-procedure).

## Helm

Upgrade with a values file containing only your overrides, as described in [Helm installation](helm.md#4-create-application-secrets). Never use `--reuse-values`. Argo CD and `helm template` installations cannot use chart `lookup`, so when upgrading from 4.1.3 or earlier, create the installation KEK and canary Secrets first, following [Manage the installation Secrets yourself](helm.md#manage-the-installation-secrets-yourself).
