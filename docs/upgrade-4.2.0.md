# Upgrade to 4.2.0

Upgrade directly from 4.1.3 or any later 4.1.x release. Installing 4.1.6 first is not required.

Before upgrading:

1. Take a database backup and keep it until the upgrade is verified. Startup migrations change the schema, and there is no downgrade below 4.2.0 once they have run.
2. Declare `DATABASE_VOLUME_CAPACITY` for the database volume. Without it the volume brake is not evaluated and index reclaim does not run. Helm installations that use an existing claim or migration mode must set `backend.performance.readModel.databaseVolumeCapacity`; Compose installations set `DATABASE_VOLUME_CAPACITY` in `.env`. See [Environment variables](environment-variables.md).

On first start the backend rebuilds the transaction history in the background, one party at a time. The app keeps serving the previous history for each party until its rebuilt copy replaces it, and the database is temporarily larger while both copies exist.

Follow the usual upgrade procedure for your installation: [Helm](helm.md) or [Docker Compose](docker-compose.md#operations-and-upgrades).
