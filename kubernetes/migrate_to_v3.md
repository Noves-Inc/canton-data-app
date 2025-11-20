# Kubernetes Migration Guide – v2.x → v3.0.0

Use this guide if you already run the Canton Data App in Kubernetes using the previous two-deployment layout (frontend + backend with individual PVCs). Version 3.0.0 introduces a dedicated Postgres database deployment as the only stateful component. Follow the steps below to upgrade with minimal effort.

---

## 1. Summary of Changes

| Area | v2.x | v3.0.0 | Migration Impact |
|------|------|--------|------------------|
| Storage | Backend/Frontend PVCs (`data-app-backend-pvc`, `data-app-frontend-pvc`, etc.) | Single PVC (`data-app-db-pvc`) mounted by Postgres | Create new PVC, retire the others |
| Deployments | Frontend, Backend | Frontend, Backend, **Database** | Add `data-app-db` deployment |
| Services | Frontend, Backend | Frontend, Backend, **Database** | Add ClusterIP service `data-app-db` |
| Secrets | None for DB | Secret for DB password (`data-app-db-secret`) | Create via manifest or external store |
| Backend env vars | `INDEX_DB_PATH` pointing to local storage | `INDEX_DB_*` env vars pointing to database service | Update ConfigMap |
| Ingress / Auth / Canton | Same | Same | No change needed |

---

## 2. Prerequisites

- `kubectl` configured for the namespace that currently hosts the data app (examples below use `validator`).
- Ability to edit and re-apply the manifests under `kubernetes/manifests/`.
- A database password ready (store it securely; do not commit real secrets to Git).

---

## 3. Update the Manifests

### Step 3.1 – Persistent Volume Claim

Open `kubernetes/manifests/persistentvolumeclaims.yaml` and ensure it contains only the `data-app-db-pvc` definition:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-app-db-pvc
  namespace: validator
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi  # adjust for your ledger volume
```

Update `namespace`, `storage`, and `storageClassName` to match your cluster.

### Step 3.2 – Database Secret

Edit `kubernetes/manifests/secrets.yaml` and replace the placeholder password:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: data-app-db-secret
  namespace: validator
type: Opaque
stringData:
  postgres-password: "replace-with-strong-pass"
```

> If you manage secrets elsewhere (e.g., sealed-secrets, Vault), adapt the manifest accordingly.

### Step 3.3 – ConfigMaps

In `kubernetes/manifests/configmaps.yaml`, confirm the backend ConfigMap has the new database env vars:

```yaml
  INDEX_DB_HOST: "data-app-db"
  INDEX_DB_PORT: "5432"
  INDEX_DB_NAME: "canton_index"
  INDEX_DB_USER: "appuser"
```

Remove any `INDEX_DB_PATH` or file-path references. Frontend ConfigMap remains unchanged (Auth0/Keycloak settings stay the same).

### Step 3.4 – Services

Add the database service at the top of `kubernetes/manifests/services.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: data-app-db
  namespace: validator
spec:
  ports:
    - port: 5432
      targetPort: 5432
      name: postgres
  selector:
    app: data-app-db
```

Backend (`data-app-backend`) and frontend (`data-app-frontend`) services do not change.

### Step 3.5 – Deployments

1. **Database Deployment**: Insert the new block from `kubernetes/manifests/deployments.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: data-app-db
  namespace: validator
spec:
  strategy:
    type: Recreate
  template:
    spec:
      containers:
        - name: postgres
          image: ghcr.io/noves-inc/canton-translate-db:v3.0.0
          env:
            - name: POSTGRES_USER
              value: "appuser"
            - name: POSTGRES_DB
              value: "canton_index"
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: data-app-db-secret
                  key: postgres-password
            - name: PGDATA
              value: /home/postgres/pgdata/data
          volumeMounts:
            - name: data-app-db-storage
              mountPath: /home/postgres/pgdata
          readinessProbe:
            exec:
              command: ["/bin/sh","-c","pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            initialDelaySeconds: 10
            periodSeconds: 30
            timeoutSeconds: 15
          livenessProbe:
            exec:
              command: ["/bin/sh","-c","pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            initialDelaySeconds: 30
            periodSeconds: 30
            timeoutSeconds: 15
      volumes:
        - name: data-app-db-storage
          persistentVolumeClaim:
            claimName: data-app-db-pvc
```

2. **Backend Deployment**: Remove any PVC volume mounts and ensure the container references the secret for the password:

```yaml
          envFrom:
            - configMapRef:
                name: data-app-backend-config
          env:
            - name: INDEX_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: data-app-db-secret
                  key: postgres-password
```

No other changes are needed—keep `CANTON_NODE_ADDR`, TLS settings, resources, etc.

3. **Frontend Deployment**: Remove any PVC sections if they existed. Image tag should be `ghcr.io/noves-inc/canton-translate-ui:v3.0.0` (or `:latest`).

---

## 4. Apply the Changes

Run the following commands in order (adjust namespace flag if needed):

```bash
kubectl apply -f kubernetes/manifests/persistentvolumeclaims.yaml
kubectl apply -f kubernetes/manifests/secrets.yaml
kubectl apply -f kubernetes/manifests/configmaps.yaml
kubectl apply -f kubernetes/manifests/services.yaml
kubectl apply -f kubernetes/manifests/deployments.yaml
```

Ingress manifests for v3 are identical to v2, so no re-apply is necessary unless you changed hostnames.

Watch the rollout:

```bash
kubectl get pods -n validator
kubectl logs -f deployment/data-app-db -n validator
kubectl logs -f deployment/data-app-backend -n validator
```

You should see `data-app-db` enter `Running`, followed by backend logs stating it connected to Postgres and began indexing.

---

## 5. Validate and Clean Up

1. **Frontend check**: Access the same ingress URL, log in with Auth0/Keycloak—no changes should be required.
2. **Backend health**: `kubectl port-forward service/data-app-backend -n validator 8090:8090` and call `/health` to ensure it responds.
3. **Database pod**: Confirm PVC binding:  
   ```bash
   kubectl get pvc data-app-db-pvc -n validator
   ```
4. **Retire old PVCs** (after successful verification):
   ```bash
   kubectl delete pvc data-app-backend-pvc -n validator --ignore-not-found
   kubectl delete pvc data-app-frontend-pvc -n validator --ignore-not-found
   kubectl delete pvc data-app-frontend-exports-pvc -n validator --ignore-not-found
   ```

---

## 6. Rollback Plan

If you need to revert quickly:

1. `kubectl rollout undo deployment/data-app-backend -n validator`
2. Delete the database deployment/service/PVC if they cause issues.
3. Re-apply your previous manifests which mounted the local PVCs.

Because v3 stores state centrally, rolling back means the backend will look for the old on-disk data again. Keep old PVC definitions or backups until you are confident in the new setup.

---

## 7. Post-Migration Recommendations

- Schedule regular database backups (`pg_dump`, Kasten, etc.) now that the data is centralized.
- Configure monitoring/alerts for the `data-app-db` pod to track disk usage and availability.
- Document the new Secret management workflow for your operations team.

Once these steps are complete, your Kubernetes deployment matches the v3.0.0 architecture while preserving ingress, authentication, and Canton connectivity exactly as before.  

