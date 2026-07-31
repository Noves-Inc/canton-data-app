# Helm installation

Use this guide to install v4 of the Noves App in the same namespace as a validator deployed with the standard Canton Helm chart. The example uses Auth0, NGINX Ingress, and the default Canton Service names. It references private prerelease images, which Noves will replace with public images when v4 ships.

## 1. Check the cluster

Set the context and namespace once:

```bash
export KUBE_CONTEXT=canton-mainnet
export NAMESPACE=validator

kubectl --context "$KUBE_CONTEXT" config current-context
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  get service participant validator-app
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  get service participant -o jsonpath='{.spec.ports[*].port}{"\n"}'
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  get service validator-app -o jsonpath='{.spec.ports[*].port}{"\n"}'
```

The standard services expose `participant:5001` and `validator-app:5003`. Change `canton.participantAddress` or `canton.validatorUrl` only when your validator uses different names.

Check storage and routing:

```bash
kubectl --context "$KUBE_CONTEXT" get storageclass
kubectl --context "$KUBE_CONTEXT" get ingressclass
kubectl --context "$KUBE_CONTEXT" api-resources \
  --api-group=networking.istio.io | grep -i virtualservice || true
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" get pvc
```

Use `routing.provider: ingress` for NGINX or another Kubernetes Ingress controller. Set `routing.ingress.className` to the exact IngressClass name. Use `routing.provider: istio` only when the cluster has the Istio VirtualService CRD and you know the gateway name. `routing.provider: none` creates no public route.

Public routing creates two hostnames by default:

```text
data.example.com      -> frontend/BFF
api.data.example.com  -> backend API and /docs
```

Create DNS records for both names and point them to the same Ingress or Istio gateway address.
The chart derives the backend name by adding `api.` to `routing.host`. Set
`routing.backend.host` when you need another name, or set `routing.backend.enabled: false` for a
frontend-only route.

Production database storage needs encrypted SSD-backed `ReadWriteOnce` block storage. Typical classes are AKS `managed-csi-premium`, encrypted EKS `gp3`, and GKE `premium-rwo`. Set `database.persistence.storageClass` for a new database. The empty default suits local clusters where the default StorageClass is known.

## 2. Arrange private registry access

The prerelease chart uses:

```text
noves.azurecr.io/cda-backend:prod-3e1a1fde-1785439104
noves.azurecr.io/cda-frontend:prod-c78cdd33-1785419965
ghcr.io/noves-inc/noves-canton-database-v4:candidate-30160846627-1
```

The chart pins all three images by tag and digest. An AKS cluster attached to the Noves ACR can pull the first two images through its kubelet identity. Other clusters need registry pull credentials.

Create one or more `kubernetes.io/dockerconfigjson` Secrets through your secret manager, then list them:

```yaml
imagePullSecrets:
  - name: noves-acr-pull
  - name: noves-ghcr-pull
```

Confirm access before debugging the application:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  get secret noves-acr-pull noves-ghcr-pull
```

## 3. Configure Auth0 and the capture user

Create the browser and capture applications described in [Auth0 configuration](authentication/auth0.md). Request a token for the capture application and copy its exact `sub` claim. That subject becomes the Canton capture user ID and the `ledger-api-user` Secret value.

The standard validator stores an administrator client in `splice-app-validator-ledger-api-auth`. Use it only to create and inspect the dedicated capture user. The following commands keep the administrator access token in shell memory.

```bash
ADMIN_SECRET=splice-app-validator-ledger-api-auth

ADMIN_DISCOVERY_URL="$(
  kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
    get secret "$ADMIN_SECRET" -o jsonpath='{.data.url}' | base64 -d
)"
ADMIN_TOKEN_URL="$(
  curl -fsS "$ADMIN_DISCOVERY_URL" | jq -er '.token_endpoint'
)"
ADMIN_CLIENT_ID="$(
  kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
    get secret "$ADMIN_SECRET" -o jsonpath='{.data.client-id}' | base64 -d
)"
ADMIN_CLIENT_SECRET="$(
  kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
    get secret "$ADMIN_SECRET" -o jsonpath='{.data.client-secret}' | base64 -d
)"
ADMIN_AUDIENCE="$(
  kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
    get secret "$ADMIN_SECRET" -o jsonpath='{.data.audience}' | base64 -d
)"
ADMIN_SCOPE="$(
  kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
    get secret "$ADMIN_SECRET" -o jsonpath='{.data.scope}' | base64 -d
)"

export PARTICIPANT_ADMIN_TOKEN="$(
  curl -fsS --request POST "$ADMIN_TOKEN_URL" \
    --header 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=client_credentials \
    --data-urlencode client_id="$ADMIN_CLIENT_ID" \
    --data-urlencode client_secret="$ADMIN_CLIENT_SECRET" \
    --data-urlencode audience="$ADMIN_AUDIENCE" \
    --data-urlencode scope="$ADMIN_SCOPE" |
    jq -er '.access_token'
)"
unset ADMIN_CLIENT_SECRET
```

Forward the Ledger API in a second terminal:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  port-forward service/participant 5001:5001
```

Read the full participant ID:

```bash
grpcurl -plaintext -expand-headers \
  -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
  -d '{}' \
  localhost:5001 \
  com.daml.ledger.api.v2.admin.PartyManagementService/GetParticipantId
```

Set the capture subject, then create the user:

```bash
export CAPTURE_USER_ID='replace-with-the-exact-capture-token-subject'

grpcurl -plaintext -expand-headers \
  -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
  -d "{\"user\":{\"id\":\"${CAPTURE_USER_ID}\"},\"rights\":[{\"canReadAsAnyParty\":{}}]}" \
  localhost:5001 \
  com.daml.ledger.api.v2.admin.UserManagementService/CreateUser
```

If the user exists without the required right, grant it:

```bash
grpcurl -plaintext -expand-headers \
  -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
  -d "{\"userId\":\"${CAPTURE_USER_ID}\",\"rights\":[{\"canReadAsAnyParty\":{}}]}" \
  localhost:5001 \
  com.daml.ledger.api.v2.admin.UserManagementService/GrantUserRights
```

Confirm that `CanReadAsAnyParty` is the only right:

```bash
grpcurl -plaintext -expand-headers \
  -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
  -d "{\"userId\":\"${CAPTURE_USER_ID}\"}" \
  localhost:5001 \
  com.daml.ledger.api.v2.admin.UserManagementService/ListUserRights

unset PARTICIPANT_ADMIN_TOKEN ADMIN_CLIENT_ID ADMIN_DISCOVERY_URL ADMIN_TOKEN_URL \
  ADMIN_AUDIENCE ADMIN_SCOPE
```

The Secret's `url` field points to the OpenID Connect discovery document, not
the token endpoint. Resolve `token_endpoint` from that document as shown above.
Do not place the administrator client or token in a Noves App Secret.

## 4. Create application Secrets

Create the database password:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  create secret generic noves-canton-data-app-database \
  --from-literal=postgres-password='replace-with-a-long-random-value'
```

Create the capture Secret with the dedicated Auth0 application:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  create secret generic noves-canton-data-app-capture-auth \
  --from-literal=ledger-api-user="$CAPTURE_USER_ID" \
  --from-literal=token-endpoint='https://TENANT.auth0.com/oauth/token' \
  --from-literal=client-id='replace-with-capture-client-id' \
  --from-literal=client-secret='replace-with-capture-client-secret' \
  --from-literal=audience='https://canton.network.global' \
  --from-literal=scope=''
```

Noves supplies a separate per-installation gateway credential during the prerelease:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  create secret generic noves-canton-data-app-gateway \
  --from-literal=token='replace-with-the-Noves-installation-credential'
```

The chart generates `ACCOUNTING_TOKEN_ENCRYPTION_KEY` in a retained Secret named `<release>-accounting-token-encryption`. Back up that Secret with the database. Losing it makes stored accounting provider credentials unreadable. GitOps operators who need deterministic client-side rendering can create their own 32-byte base64 key and set:

```yaml
accounting:
  tokenEncryption:
    existingSecret: cda-accounting-token-encryption
    key: accounting-token-encryption-key
```

## 5. Write the values file

Start with:

```yaml
imagePullSecrets:
  - name: noves-acr-pull
  - name: noves-ghcr-pull

database:
  existingSecret: noves-canton-data-app-database
  persistence:
    storageClass: managed-csi-premium

capture:
  existingSecret: noves-canton-data-app-capture-auth

novesGateway:
  existingSecret: noves-canton-data-app-gateway
  tokenKey: token

canton:
  expectedParticipantId: 'participant::replace-with-the-full-id'
  participantAddress: participant:5001
  validatorUrl: http://validator-app:5003
  network: mainnet

oidc:
  provider: auth0
  appUrl: https://data.example.com
  auth0:
    domain: TENANT.auth0.com
    clientId: replace-with-browser-client-id
    audience: https://canton.network.global

routing:
  provider: ingress
  host: data.example.com
  tlsSecret: data-example-com-tls
  backend:
    enabled: true
    host: ""
    tlsSecret: ""
  ingress:
    className: nginx
```

An empty backend host produces `api.data.example.com`. An empty backend TLS Secret reuses
`routing.tlsSecret`; that certificate must include both hostnames. Set
`routing.backend.tlsSecret` when the backend uses a separate certificate. With Istio, the
Gateway terminates TLS, so its certificate must cover both names.

The backend stores exports on the retained `/exports` PVC by default. Set `exports.storage: s3` only when you have configured the typed `exports.s3` block and bucket access. Transaction-history backups use the independent `backup.s3` block. See [`values.yaml`](../chart/noves-canton-data-app/values.yaml) for the Secret key names and optional endpoint and region fields.

## 6. Render and install

Render before changing the cluster:

```bash
helm lint ./chart/noves-canton-data-app --values enterprise-values.yaml
helm template noves-canton-data-app ./chart/noves-canton-data-app \
  --namespace "$NAMESPACE" \
  --values enterprise-values.yaml |
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  apply --dry-run=server -f -
```

Install from this checkout:

```bash
helm upgrade --install noves-canton-data-app \
  ./chart/noves-canton-data-app \
  --kube-context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE" \
  --values enterprise-values.yaml \
  --wait \
  --timeout 20m
```

## 7. Verify startup and capture

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" get pods
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  rollout status deployment/noves-canton-data-app-backend --timeout=20m
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  rollout status deployment/noves-canton-data-app-frontend --timeout=10m
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  port-forward service/noves-canton-data-app-backend 8090:8090
```

From another terminal:

```bash
curl -fsS http://127.0.0.1:8090/health
curl -fsS http://127.0.0.1:8090/startupStatus | jq
curl -fsS http://127.0.0.1:8090/ready
curl -fsS http://127.0.0.1:8090/api/v2/capture/status | jq
```

After DNS and TLS are ready, verify the public backend route:

```bash
export BACKEND_URL=https://api.data.example.com

curl -fsS "$BACKEND_URL/health"
curl -fsS "$BACKEND_URL/ready"
curl -fsS "$BACKEND_URL/docs/v1/openapi.json" | jq '.info'
```

Open `https://api.data.example.com/docs` for Swagger UI. Requests to `/docs` on
`data.example.com` still go to the frontend SPA because that hostname routes to the frontend
Service.

`/ready` proves that startup and database preparation finished. It does not prove that participant capture is running. The capture response should report `captureEnabled: true`; after initial loading, the node should report `initialCaptureComplete: true` and `caughtUp: true`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `ImagePullBackOff` | `kubectl describe pod`; fix ACR or GHCR access and `imagePullSecrets` |
| Database pod pending | `kubectl get pvc` and `kubectl describe pvc`; check the StorageClass and zone constraints |
| Ingress has no address | `kubectl get ingressclass` and `kubectl describe ingress`; confirm `routing.ingress.className` |
| Backend hostname does not resolve | Check the `api.` DNS record or the explicit `routing.backend.host` value |
| Backend TLS certificate mismatch | Add both names to the shared certificate or set `routing.backend.tlsSecret` |
| Istio render fails server dry-run | Install the VirtualService CRD or select `routing.provider: ingress` |
| Backend stays unready | Read `/startupStatus`, then backend logs |
| Capture disabled or stale | Read `/api/v2/capture/status`; verify the capture Secret, token subject, Canton user, and its exact rights |
| Browser login loops | Compare the Auth0 callback, logout, origin, audience, and `oidc.appUrl` values |

## Uninstall

```bash
helm uninstall noves-canton-data-app \
  --kube-context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE"
```

Helm retains the database PVC, exports PVC, and generated accounting-key Secret. Remove them only after satisfying backup and retention requirements.
