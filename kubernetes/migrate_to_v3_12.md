# Kubernetes Migration Guide – Adding Multi-Validator Support (v3.12.0+)

This guide covers how to add a second (or more) Canton validator node to an existing single-node deployment after upgrading to v3.12.0 or later. If you are deploying for the first time, follow [kubernetes_deployment.md](kubernetes_deployment.md) and use the JSON config file from the start.

---

## 1. What Changes

| Area | Before | After | Action Required |
|------|--------|-------|-----------------|
| Node configuration | `CANTON_NODE_ADDR` + `CANTON_NODE_CERT_FILE_PATH` in ConfigMap | JSON config file in a dedicated ConfigMap | Create ConfigMap, mount it, set `NODES_CONFIG_FILE_PATH` |
| TLS certificates | Single cert in a Secret, referenced by `CANTON_NODE_CERT_FILE_PATH` | Per-node `cert_file` paths inside the JSON config | Move cert reference into JSON config |
| Database schema | No `validator_node_id` column | Column added and backfilled on first startup | Automatic — no manual action needed |
| Other env vars | Unchanged | Unchanged | No change |

> Legacy environment variables (`CANTON_NODE_ADDR`, `CANTON_NODE_CERT_FILE_PATH`, `CANTON_NODE_ID`) continue to work for single-node setups and do not need to be removed from existing ConfigMaps.

---

## 2. Determine Your Existing Node ID

The `primaryNodeId` you set in the JSON config must match the node ID already stored in the database. Identify it before proceeding.

```bash
# Check the current value in your backend ConfigMap
kubectl get configmap data-app-backend-config -n validator -o yaml | grep CANTON_NODE_ID
```

- **If `CANTON_NODE_ID` is set**: use that value.
- **If `CANTON_NODE_ID` is not set**: the default is `main-node`.

Write this value down — you will need it in the next step.

---

## 3. Create the Nodes ConfigMap

Create a new ConfigMap containing the JSON node configuration. Replace `main-node` with your actual existing node ID from Step 2.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: data-app-nodes-config
  namespace: validator  # your namespace
data:
  nodes-config.json: |
    {
      "primaryNodeId": "main-node",
      "nodes": {
        "main-node": {
          "addr": "participant-1.validator.svc.cluster.local:5001",
          "cert_file": "/certs/validator-1.crt"
        },
        "validator-2": {
          "addr": "participant-2.validator.svc.cluster.local:5001",
          "cert_file": "/certs/validator-2.crt"
        }
      }
    }
```

If your participants do not use TLS, omit the `cert_file` lines.

> **WARNING: `primaryNodeId` must exactly match the node ID already in your database.** An incorrect value will mis-label all existing historical data, which is not easily reversible.

Apply the ConfigMap:

```bash
kubectl apply -f manifests/nodes-configmap.yaml

# Verify
kubectl get configmap data-app-nodes-config -n validator
```

---

## 4. Add TLS Secrets for New Nodes (if needed)

If any new nodes require TLS, create a Secret with those certificate files:

```bash
kubectl create secret generic participant-2-tls-cert \
  --from-file=participant-2.crt=/path/to/participant-2.crt \
  -n validator
```

---

## 5. Update the Backend Deployment

Add the new volume and volume mount to your backend deployment manifest (`manifests/deployments.yaml`), and add `NODES_CONFIG_FILE_PATH` to the container's env:

```yaml
spec:
  containers:
    - name: canton-data-app-backend
      volumeMounts:
        - name: nodes-config
          mountPath: /app/config/nodes-config.json
          subPath: nodes-config.json
          readOnly: true
        # Keep any existing cert mounts for previously configured nodes
        - name: participant-cert
          mountPath: /certs/validator-1.crt
          subPath: participant.crt
          readOnly: true
        # Add mounts for new node certs as needed
        - name: participant-2-cert
          mountPath: /certs/validator-2.crt
          subPath: participant-2.crt
          readOnly: true
      env:
        - name: NODES_CONFIG_FILE_PATH
          value: "/app/config/nodes-config.json"
        # CANTON_NODE_ADDR and CANTON_NODE_CERT_FILE_PATH can remain but will be
        # ignored once NODES_CONFIG_FILE_PATH is set
  volumes:
    - name: nodes-config
      configMap:
        name: data-app-nodes-config
    - name: participant-cert
      secret:
        secretName: participant-tls-cert
    - name: participant-2-cert
      secret:
        secretName: participant-2-tls-cert
```

Apply the updated deployment:

```bash
kubectl apply -f manifests/deployments.yaml
```

---

## 6. Monitor the Rollout

```bash
# Watch the rollout
kubectl rollout status deployment/data-app-backend -n validator

# Follow backend logs
kubectl logs -f deployment/data-app-backend -n validator
```

Look for messages indicating:
- Node configuration loaded
- `validator_node_id` column migration complete (only appears on first startup with multiple nodes)
- Connection established to both participant nodes

---

## 7. Verify

```bash
# Port-forward and check registered nodes
kubectl port-forward service/data-app-backend -n validator 8090:8090 &

curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  http://localhost:8090/api/v2/nodes

# Expected: JSON listing both node IDs
```

The frontend node selector in the dashboard will also show all configured nodes once you reload the page.
