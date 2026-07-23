# Migrate Data App v3.16.1 to v4

Migration is supported only from Data App v3.16.1. Upgrade an older v3 installation to 3.16.1
and confirm it is healthy before proceeding.

## Required checks

1. Confirm the running Data App reports version 3.16.1.
2. Take a database backup and verify that it can be restored.
3. Record the old image versions, volume name or PVC, participant ID, and OIDC configuration.
4. Stop the complete v3 workload. Do not allow v3 and v4 to write the same database.
5. Confirm the existing database runs PostgreSQL 18. The v4 database container refuses a
   different major version.
6. Create the dedicated least-privilege M2M identity described in
   [Security](security.md). Do not carry forward a validator credential.

## Helm

Use a normal enterprise values file and add:

```yaml
migration:
  enabled: true
  sourceVersion: 3.16.1
  backupConfirmed: true
  oldWorkloadStopped: true
  existingClaim: replace-with-v3-database-pvc
```

Install the v4 release with the same commands in [Helm installation](helm.md). The normal backend
web host performs the upgrade; there is no one-off migration Job. Readiness remains false while
work is in progress.

## Docker Compose

Use the guarded launcher with the stopped v3 volume name:

```bash
./scripts/migrate-v3.sh \
  --source-version 3.16.1 \
  --backup-confirmed \
  --old-workload-stopped \
  --volume replace-with-v3-database-volume
```

Use the shipped v4 database container. Do not copy the database into another runtime.

## Monitor and resume

```bash
curl http://127.0.0.1:8090/startup-status
```

The response reports preparation and replay progress in Data App terms. If the backend restarts,
start the same v4 configuration again; work resumes from durable progress. Do not reattach the
volume to v3 while v4 is running.

## Rollback

Stop v4 and restore the verified pre-migration backup into a clean v3.16.1 database volume.
Start the recorded v3.16.1 workload against that restored volume. There is no automatic down
migration.
