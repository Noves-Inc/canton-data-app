# Migrate from v3.16.1 to v4 of the Noves Data App

v4 of the Noves Data App upgrades databases from v3.16.1. If you run an older v3 release, upgrade it to v3.16.1 and confirm that it works before starting this procedure.

The v3 and v4 database workloads must never mount the same PVC at the same time. Keep a tested pre-upgrade backup until you finish application and capture verification.

Choose the section for your current deployment:

- [Helm migration](#helm-migration)
- [Docker Compose migration](#docker-compose-migration)

## Helm migration

## 1. Record the current installation

Set the cluster values:

```bash
export KUBE_CONTEXT=canton-mainnet
export NAMESPACE=validator
```

Record the v3 release, workloads, images, and claims:

```bash
helm --kube-context "$KUBE_CONTEXT" --namespace "$NAMESPACE" list
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  get deployment,statefulset,pod,pvc -o wide
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{" "}{end}{"\n"}{end}'
```

Identify the PVC mounted at the v3 PostgreSQL data path. Record:

- the exact PVC and namespace;
- the v3 Helm release and replica counts;
- the v3 application and database images;
- the existing `appuser` database password;
- participant ID, Canton service addresses, OIDC values, and Secrets.

PVCs are namespace-scoped. Install v4 in the same namespace as the v3 database claim.

Confirm PostgreSQL 18 from the running v3 database pod before stopping it:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  exec replace-with-v3-database-pod -- \
  cat /home/postgres/pgdata/data/PG_VERSION
```

The result must be `18`. The v4 database init container refuses another major version.

## 2. Back up and stop v3

Create a database backup or storage snapshot and test a restore to a separate volume. Record the backup ID, completion time, and restore result.

Stop every v3 writer. Use the workload names recorded in the previous step:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  scale deployment/replace-with-v3-backend --replicas=0
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  scale statefulset/replace-with-v3-database --replicas=0
```

Wait for the old pods to disappear:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  get pods --watch
```

Prove that no remaining pod references the database claim:

```bash
export V3_DATABASE_PVC=replace-with-v3-database-pvc

kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  get pods -o json |
  jq -er --arg claim "$V3_DATABASE_PVC" '
    [.items[]
      | select(any(.spec.volumes[]?;
          .persistentVolumeClaim.claimName == $claim))
      | .metadata.name] |
    if length == 0 then
      "No pods mount \($claim)"
    else
      error("PVC is still mounted by: \(join(\", \"))")
    end
  '
```

Do not continue unless the command prints `No pods mount <claim>`.

## 3. Prepare v4 values

Create the v4 database Secret with the existing `appuser` password:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  create secret generic noves-canton-data-app-database \
  --from-literal=postgres-password='replace-with-the-existing-appuser-password'
```

Do not generate a new password for an initialized database.

Complete the normal values from [Helm installation](helm.md), then add:

```yaml
migration:
  enabled: true
  sourceVersion: 3.16.1
  backupConfirmed: true
  oldWorkloadStopped: true
  existingClaim: replace-with-v3-database-pvc
```

Helm mounts `migration.existingClaim` and sets `DATABASE_EXPECTED_SOURCE=v3`. Before the backend provisions extensions or runs a migration, it checks for a supported v3 database or a v3 lineage already being resumed. An empty database, fresh v4 database, unrelated PVC, or unsupported schema stops startup with a migration error.

Render and ask the Kubernetes API to validate the resources:

```bash
helm template noves-canton-data-app ./chart/noves-canton-data-app \
  --namespace "$NAMESPACE" \
  --values migration-values.yaml |
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  apply --dry-run=server -f -
```

Confirm that the rendered StatefulSet names the recorded claim:

```bash
helm template noves-canton-data-app ./chart/noves-canton-data-app \
  --namespace "$NAMESPACE" \
  --values migration-values.yaml |
grep -A2 'persistentVolumeClaim:'
```

## 4. Start v4 and monitor the upgrade

Install without `--wait` so you can inspect long database preparation and participant replay:

```bash
helm upgrade --install noves-canton-data-app \
  ./chart/noves-canton-data-app \
  --kube-context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE" \
  --values migration-values.yaml
```

Watch pods and backend logs:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" get pods --watch
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  logs deployment/noves-canton-data-app-backend --follow
```

Forward the backend in another terminal:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  port-forward service/noves-canton-data-app-backend 8090:8090
```

Check progress:

```bash
curl -fsS http://127.0.0.1:8090/health
curl -fsS http://127.0.0.1:8090/startup-status | jq
curl -fsS http://127.0.0.1:8090/ready
curl -fsS http://127.0.0.1:8090/api/v2/capture/status | jq
```

Health remains available during preparation. Readiness stays unavailable until schema validation and required replay work finish. A restart resumes from durable progress.

## 5. Verify the cutover

Confirm:

1. `/ready` succeeds.
2. `/api/v2/capture/status` reports `captureEnabled: true`.
3. Each node finishes initial capture and catches up.
4. Browser sign-in works.
5. Participant identity matches the recorded value.
6. A representative private transaction query returns expected data.
7. Preserved streams, connectors, alerts, delivery history, and WebSocket buffers remain available.

Keep `migration.enabled: true`, `migration.existingClaim`, and the other migration acknowledgements in the release values after cutover. They continue to select the converted PVC and assert its v3 lineage on restart. Removing them can make Helm select a new claim.

Keep v3 stopped. Do not attach the converted claim to a v3 workload.

### Helm rollback

Stop v4. Restore the verified pre-upgrade backup into a clean PVC, then start the recorded v3.16.1 workloads against the restored claim. Do not point v3 at the converted volume. The Noves Data App does not run automatic down migrations.

## Docker Compose migration

The Compose migration reuses the stopped v3.16.1 database volume. The shipped `compose.migrate-v3.yaml` override marks that volume as external and sets `DATABASE_EXPECTED_SOURCE=v3`, so the backend rejects an empty, unrelated, or already-fresh-v4 database before it migrates anything.

### 1. Record and back up v3

Run these commands from the existing v3 Compose directory:

```bash
docker compose ps
docker compose images
docker compose config --volumes
docker volume ls
```

Record the v3 directory, database volume name, image versions, public URL, Canton settings, OIDC settings, and the existing `appuser` database password. Confirm that the running database uses PostgreSQL 18:

```bash
docker compose exec database \
  cat /home/postgres/pgdata/data/PG_VERSION
```

The result must be `18`. Create a database backup or snapshot and restore it to a separate test volume. Keep the backup until the v4 application and capture checks pass.

### 2. Stop v3

Stop the old deployment without deleting its volumes:

```bash
docker compose down
```

Do not use `down --volumes`. Confirm that no container mounts the recorded database volume:

```bash
export V3_DATABASE_VOLUME=replace-with-v3-database-volume

docker ps --filter volume="$V3_DATABASE_VOLUME"
```

The command must return no containers.

### 3. Prepare the v4 files

Follow steps 2 through 5 in the [Docker Compose installation guide](docker-compose.md) to create the v4 `.env` and `.state` files. Use the existing v3 `appuser` password as `DATABASE_PASSWORD`; do not generate a new password for the initialized database.

Set the installation directory and render the migration configuration before starting it:

```bash
export REPO_DIR=/path/to/canton-data-app-v4-checkout
export APP_INSTALL_DIR=/opt/noves-canton-data-app-v4

cp "$REPO_DIR/docker-compose/compose.yaml" \
  "$APP_INSTALL_DIR/docker-compose/compose.yaml"
cp "$REPO_DIR/docker-compose/compose.migrate-v3.yaml" \
  "$APP_INSTALL_DIR/docker-compose/compose.migrate-v3.yaml"

cd "$APP_INSTALL_DIR/docker-compose"
DATABASE_VOLUME="$V3_DATABASE_VOLUME" \
docker compose --env-file .env \
  -f compose.yaml \
  -f compose.migrate-v3.yaml config > /tmp/noves-data-app-v4-migration.yaml

grep -A1 'DATABASE_EXPECTED_SOURCE' /tmp/noves-data-app-v4-migration.yaml
grep -A3 'database:' /tmp/noves-data-app-v4-migration.yaml
```

Confirm that the first command shows `v3` and the volume section names the recorded v3 volume.

### 4. Start v4 and monitor the migration

Run the migration wrapper from the v4 repository checkout:

```bash
"$REPO_DIR/scripts/migrate-v3.sh" \
  --source-version 3.16.1 \
  --backup-confirmed \
  --old-workload-stopped \
  --volume "$V3_DATABASE_VOLUME" \
  --directory "$APP_INSTALL_DIR/docker-compose"
```

Monitor the backend and startup endpoints:

```bash
cd "$APP_INSTALL_DIR/docker-compose"
docker compose --env-file .env \
  -f compose.yaml \
  -f compose.migrate-v3.yaml logs -f backend

curl -fsS http://127.0.0.1:8090/health
curl -fsS http://127.0.0.1:8090/startup-status | jq
curl -fsS http://127.0.0.1:8090/ready
curl -fsS http://127.0.0.1:8090/api/v2/capture/status | jq
```

Startup can take time while v4 prepares the schema and rebuilds derived data. A restart resumes from stored progress.

### 5. Verify the cutover

Confirm that `/ready` succeeds, capture is enabled and current, browser sign-in works, and representative private transactions match the v3 installation. Check alerts, connectors, accounting integrations, and exports that you used before the migration.

Keep using both Compose files for this converted database:

```bash
docker compose --env-file .env \
  -f compose.yaml \
  -f compose.migrate-v3.yaml up -d
```

The migration override preserves the external volume selection and lineage check on every restart.

### Compose rollback

Stop v4 without deleting volumes:

```bash
docker compose --env-file .env \
  -f compose.yaml \
  -f compose.migrate-v3.yaml down
```

Restore the tested pre-upgrade backup into a clean volume, then restart the recorded v3.16.1 deployment against that restored volume. Do not start v3 against the volume converted by v4.
