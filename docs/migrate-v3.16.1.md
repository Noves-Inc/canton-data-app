# Migrate from v3.16.1 to v4 of the Noves App

V4 of the Noves App upgrades databases from v3.16.1. If you run an older v3 release, upgrade it to v3.16.1 and confirm that it works before starting this procedure.

The v3 and v4 database workloads must never mount the same PVC at the same time. Keep a tested pre-upgrade backup until you finish application and capture verification.

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
curl -fsS http://127.0.0.1:8090/startupStatus | jq
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

## Rollback

Stop v4. Restore the verified pre-upgrade backup into a clean PVC, then start the recorded v3.16.1 workloads against the restored claim. Do not point v3 at the converted volume. The Noves App does not run automatic down migrations.
