# Encryption at Rest (v4)

We recommend encryption at rest for indexed ledger data. The Helm chart and Docker Compose bundle mount storage but do not configure encryption in the underlying storage system. Operators must provide encrypted storage and verify it using evidence from that system.

## Scope

Encryption must cover:

- the Postgres data volume;
- the `/exports` volume when exports are stored locally;
- object storage used for exports or transaction-history backups;
- database dumps, volume snapshots, and other copies of this data.

Volume encryption protects data when storage is accessed outside the running system. It does not protect against access through a running host, cluster, or database. Restrict database credentials, network access, and administrative access separately.

## Docker Compose

`DATABASE_DATA_PATH` selects the database storage location:

- when unset, Compose uses the volume named by `DATABASE_VOLUME`, which defaults to `noves-canton-data-app-v4-data` and inherits the encryption properties of the Docker host's storage;
- when set to an absolute path, Compose bind-mounts that path into the database container.

For an encrypted host path, set the value in `.env`:

```dotenv
DATABASE_DATA_PATH=/path/to/encrypted-storage/database
```

Verify that the path is on encrypted storage before starting Compose. Ensure the deployment cannot start against the same path on unencrypted storage if the expected mount is unavailable.

To move an existing database, stop all writers, copy the database data while preserving ownership and permissions, update `DATABASE_DATA_PATH`, and restart the deployment. Keep the original volume until the migrated database has been verified, then handle it according to your data-retention and secure-disposal policy.

## Kubernetes

For a new database PVC, set `database.persistence.storageClass` to a class that your cluster or storage administrator has verified provisions encrypted storage:

```yaml
database:
  persistence:
    storageClass: <verified-storage-class>
```

If local exports use a PVC, apply the same requirement to `exports.persistence.storageClass`.

A StorageClass name or manifest is not proof that the backing volume is encrypted. Verify the provisioned volume in the storage system. Encryption settings, key selection, and migration capabilities depend on the cluster's storage implementation; follow its supported procedures.

For existing data, do not assume that changing a PVC or StorageClass changes the backing volume. Use a migration supported by the storage implementation. If migration creates a new PVC, stop all writers before copying or restoring the database and select it with:

```yaml
database:
  persistence:
    existingClaim: <encrypted-database-pvc>
```

Account for any controller that could restart the database during migration. Keep the original PVC until the migrated database has been verified, then handle it according to your data-retention and secure-disposal policy.

## Backups and Exports

- Configure encryption and access controls for object storage used by `BACKUP_S3_*` or `EXPORTS_S3_*`.
- Place local `/exports` storage on an encrypted persistent volume.
- Write manual database dumps only to encrypted destinations.
- Apply the same encryption requirements to snapshots and backup copies.

## Key Management

Manage encryption keys through the storage system's supported key-management process. Limit access, retain any recovery material required by that system, and document rotation and recovery procedures. Loss or revocation of a required key can make stored data unavailable.

## Verification

- Confirm the actual database volume is encrypted using the storage system's supported inspection method.
- Confirm local export storage, object storage, snapshots, backups, and manual dumps are encrypted.
- Confirm the deployment starts and indexing continues after any migration.
- Confirm superseded plaintext copies are handled according to the organization's retention and secure-disposal policy.
- Record the evidence required by the organization's security or compliance process.

Questions or issues? Contact us through your Noves support channel.
