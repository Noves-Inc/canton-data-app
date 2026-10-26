# Upgrade to 4.2.4

4.2.4 includes the installation security requirements described below. Upgrade with the full 4.2.4 bundle, either the Docker Compose bundle or the Helm chart. Changing only the image tag is not supported: the bundle carries the configuration the new backend requires.

Upgrade directly from any published release 4.0.0 or later. Take a database backup first and keep it until the upgrade is verified.

## Requirements

- Installation KEK file: the backend requires the installation KEK. Compose installations get `.state/installation-kek` when you rerun `scripts/install-compose.sh --directory <same directory>` from the 4.2.4 bundle; back it up together with the database. Helm installations that manage Secrets themselves must create the KEK and canary Secrets first, as described in [Manage the installation Secrets yourself](helm.md#manage-the-installation-secrets-yourself).
- Enrollment: the installation must be enrolled so that per-installation credentials are active. Rerunning the installer enrolls it; changing image pins alone leaves credentials disabled.
- Declare `DATABASE_VOLUME_CAPACITY` (Compose) or `backend.performance.readModel.databaseVolumeCapacity` (Helm). See [Environment variables](environment-variables.md).

## Docker Compose

Rerun `scripts/install-compose.sh --directory <same directory>` from the 4.2.4 bundle. See the [Compose upgrade procedure](docker-compose.md#operations-and-upgrades).

The upgrade recreates the three containers, so their addresses on the Docker network change. If a reverse proxy in front of the Data App reaches the containers by name (for example nginx `proxy_pass http://noves-canton-frontend-v4:3000`), reload it after the upgrade (`nginx -s reload`); otherwise it keeps the previous addresses and answers 502.

## Helm

Upgrade with a values file containing only your overrides, as described in [Helm installation](helm.md#4-create-application-secrets). Never use `--reuse-values`.

## Pruned participants

If your participant has pruned its ledger history, do a fresh install of 4.2.4 and run the owned-party scan backfill to recover history. An in-place upgrade cannot rebuild history the participant no longer holds.
