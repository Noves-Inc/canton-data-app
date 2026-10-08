# Helm installation

Use this guide to install the Noves Data App on Kubernetes. The examples place the app in the validator namespace and use Auth0, NGINX Ingress, and Canton's default Service names. You can change the namespace, participant address, scan API URL, identity provider, and routing settings to match your cluster.

## 1. Check the cluster

Set the context and namespace where you want to run the app:

```bash
export KUBE_CONTEXT=
export NAMESPACE=validator

kubectl --context "$KUBE_CONTEXT" config current-context
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" get pods
```

The chart defaults to the first `canton.nodes` entry at `participant:5001` and to `http://validator-app:5003/api/validator` for the scan API. `canton.scanApiUrl` must be the validator application's scan-proxy base path (including `/api/validator`), not the bare service origin. Set each node's `addr` and `canton.scanApiUrl` to addresses that the app pods can reach. The services may run in another namespace or outside the cluster. Array order matters: the first node is the backend's default node.

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

Create DNS records for both names and point them to the same Ingress or Istio gateway address. The chart derives the backend name by adding `api.` to `routing.host`. Set `routing.backend.host` when you need another name, or set `routing.backend.enabled: false` for a frontend-only route.

Production database storage needs encrypted SSD-backed `ReadWriteOnce` block storage. Typical classes are AKS `managed-csi-premium`, encrypted EKS `gp3`, and GKE `premium-rwo`. Set `database.persistence.storageClass` for a new database. The empty default suits local clusters where the default StorageClass is known.

## 2. Arrange registry access

The chart pins the frontend, backend, and database images by tag and digest. Use the chart from the release you are installing. If Noves supplied registry credentials for your release, create one or more `kubernetes.io/dockerconfigjson` Secrets through your secret manager and list them in the values file:

```yaml
imagePullSecrets:
  - name: noves-acr-pull
  - name: noves-ghcr-pull
```

Confirm the Secrets exist before debugging an image-pull failure:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  get secret noves-acr-pull noves-ghcr-pull
```

## 3. Configure browser authentication and the M2M indexing user

Create separate browser and M2M indexing applications using the guide for your provider:

- [Auth0 configuration](authentication/auth0.md)
- [Keycloak configuration](authentication/keycloak.md)

Request a token for the M2M indexing application and copy its exact `sub` claim. That subject becomes the Canton M2M indexing user ID and the `ledger-api-user` Secret value. Human users continue to sign in through the public browser client; their own token subjects and Canton rights remain independent from the M2M user.

The standard validator stores an administrator client in `splice-app-validator-ledger-api-auth`. Use it only to create and inspect the dedicated M2M indexing user. The following commands keep the administrator access token in shell memory.

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

If the Ledger API requires TLS or mTLS, replace `-plaintext` in each `grpcurl` command below with `-cacert /secure/path/ca.crt -cert /secure/path/client.crt -key /secure/path/client.key -authority ledger.example.com`. Omit `-cert` and `-key` for server-only TLS, and omit `-cacert` when the server certificate uses normal system trust. Set `-authority` to a DNS name in the participant certificate SAN.

Set the M2M indexing subject, then create the user:

```bash
export M2M_INDEXING_USER_ID='replace-with-the-exact-m2m-indexing-token-subject'

grpcurl -plaintext -expand-headers \
  -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
  -d "{\"user\":{\"id\":\"${M2M_INDEXING_USER_ID}\"},\"rights\":[{\"canReadAsAnyParty\":{}}]}" \
  localhost:5001 \
  com.daml.ledger.api.v2.admin.UserManagementService/CreateUser
```

If the user exists without the required right, grant it:

```bash
grpcurl -plaintext -expand-headers \
  -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
  -d "{\"userId\":\"${M2M_INDEXING_USER_ID}\",\"rights\":[{\"canReadAsAnyParty\":{}}]}" \
  localhost:5001 \
  com.daml.ledger.api.v2.admin.UserManagementService/GrantUserRights
```

Confirm that `CanReadAsAnyParty` is the only right:

```bash
grpcurl -plaintext -expand-headers \
  -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
  -d "{\"userId\":\"${M2M_INDEXING_USER_ID}\"}" \
  localhost:5001 \
  com.daml.ledger.api.v2.admin.UserManagementService/ListUserRights

unset PARTICIPANT_ADMIN_TOKEN ADMIN_CLIENT_ID ADMIN_DISCOVERY_URL ADMIN_TOKEN_URL \
  ADMIN_AUDIENCE ADMIN_SCOPE
```

The Secret's `url` field points to the OpenID Connect discovery document, not the token endpoint. Resolve `token_endpoint` from that document as shown above. Do not place the administrator client or token in a Noves Data App Secret.

## 4. Create application Secrets

Create the database password:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  create secret generic noves-canton-data-app-database \
  --from-literal=postgres-password='replace-with-a-long-random-value'
```

Create the M2M indexing Secret with the dedicated machine application. This example uses Auth0, where `scope` is normally empty:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  create secret generic noves-canton-data-app-m2m-indexing-auth \
  --from-literal=ledger-api-user="$M2M_INDEXING_USER_ID" \
  --from-literal=token-endpoint='https://TENANT.auth0.com/oauth/token' \
  --from-literal=client-id='replace-with-m2m-indexing-client-id' \
  --from-literal=client-secret='replace-with-m2m-indexing-client-secret' \
  --from-literal=audience='https://canton.network.global' \
  --from-literal=scope=''
```

For Keycloak, use its realm token endpoint and normally set `scope` to `daml_ledger_api`. The `audience` value is still the participant Ledger API audience; Keycloak emits it through the client scope or audience mapper configured in the [Keycloak guide](authentication/keycloak.md#add-the-ledger-api-audience).

The Helm values under `m2mIndexing` identify the Secret and its data keys:

| Helm value | Default | Meaning |
|---|---|---|
| `existingSecret` | `noves-canton-data-app-m2m-indexing-auth` | Name of the Kubernetes Secret. |
| `ledgerApiUserKey` | `ledger-api-user` | Key that records the exact M2M token `sub` used to provision the matching Canton user. Canton authorizes the subject in the JWT; this entry is not a second credential. |
| `tokenEndpointKey` | `token-endpoint` | Key containing the OAuth token endpoint. |
| `clientIdKey` | `client-id` | Key containing the confidential M2M Client ID. |
| `clientSecretKey` | `client-secret` | Key containing the M2M Client Secret. |
| `audienceKey` | `audience` | Key containing the participant Ledger API audience. |
| `scopeKey` | `scope` | Key containing the optional OAuth scope. Keycloak commonly uses `daml_ledger_api`; Auth0 commonly leaves it empty. |

The `*Key` values are key names, not credential values. Keep their defaults when creating the Secret exactly as shown above. The browser client ID and M2M client ID are different values and must not be interchanged.

If the participant Ledger API requires mTLS, create a separate Secret from the unencrypted PEM files. `ca.crt` verifies the participant server; `client.crt` and `client.key` are the Data App's client identity:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  create secret generic noves-canton-ledger-mtls \
  --from-file=ca.crt=/secure/path/ca.crt \
  --from-file=client.crt=/secure/path/client.crt \
  --from-file=client.key=/secure/path/client.key
```

The CA Secret key may contain either one DER certificate or a PEM bundle with multiple trust anchors. The chart projects configured certificate keys with mode `0440`; the backend pod's `fsGroup` supplies read access. Do not put the private key in a ConfigMap or values file.

Certificates are loaded into long-lived channels when a backend pod starts. Updating an existing Secret does not reload those channels. For rotation, first make the participant trust both old and new client issuers or identities, then atomically apply all replacement Secret keys and restart the backend deployment:

```bash
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  create secret generic noves-canton-ledger-mtls \
  --from-file=ca.crt=/secure/path/ca.crt \
  --from-file=client.crt=/secure/path/client.crt \
  --from-file=client.key=/secure/path/client.key \
  --dry-run=client -o yaml | \
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" apply -f -

kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  rollout restart deployment/<release-name>-noves-canton-data-app-backend
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  rollout status deployment/<release-name>-noves-canton-data-app-backend
```

For an unrelated server-CA rollover, first update `ca.crt` to a PEM bundle containing the old and new roots and restart the deployment. Verify connectivity to the participant's old certificate, switch the participant to its new certificate, and verify again. Then replace `ca.crt` with the new root only and restart once more. If a trust-overlap bundle or cross-signed participant certificate is not available, schedule a maintenance window instead. Remove old client trust only after every backend pod is healthy with the new identity.

The chart generates `ACCOUNTING_TOKEN_ENCRYPTION_KEY` in a retained Secret named `<release>-accounting-token-encryption`. Back up that Secret with the database. Losing it makes stored accounting provider credentials unreadable. GitOps operators who need deterministic client-side rendering can create their own 32-byte base64 key and set:

```yaml
accounting:
  tokenEncryption:
    existingSecret: noves-canton-data-app-accounting-token-encryption
    key: accounting-token-encryption-key
```

The chart also generates the two secrets behind the installation credential (see [Security model](security.md#installation-credential-secrets)); no values are required:

| Secret | Mounted into | Lifecycle |
|---|---|---|
| `<release>-installation-kek` | backend only | Immutable, retained during uninstall, reused on every upgrade and reinstall, never regenerated |
| `<release>-installation-canary` | backend and frontend | Reused on upgrade, deleted on uninstall, new on every reinstall |

Upgrade from 4.1.3 using the new chart defaults plus a values file containing only your deployment overrides:

```bash
helm upgrade <release> ./noves-canton-data-app-<version>.tgz \
  --namespace <namespace> --values deployment-values.yaml
```

Keep node access, storage, ingress and operator-managed Secret settings in that file. Remove old
`backend.image`, `frontend.image` and `database.image` blocks unless you deliberately supply the new
release's matching digest pins. Do not use `--reuse-values`: it retains the old image digests even
when the new chart is installed. `helm get values --all` also includes the old image pins and must not
be reused without removing them. A missing or partial `installation` block uses the new defaults.
After upgrading, verify all three Deployment/StatefulSet images match the new release manifest.

The generated Secret names use the release's full name. When a new KEK is generated, the install and upgrade notes print its Secret name; `kubectl get secret -l app.kubernetes.io/instance=<release>` lists the generated Secrets.

Each pod receives its installation secrets as read-only files at startup; a `helm upgrade` that changes a secret value rolls the pods holding the old one. Values must be the base64 encoding of 32 bytes (44 characters, no newline), or the pod cannot start.

Keep the KEK with your database backup; see the [KEK backup and restore rule](security.md#installation-credential-secrets). Helm refuses to replace a KEK that the live backend depends on. If the release name or `fullnameOverride` changes, set `installation.kek.existingSecret` to the retained KEK Secret, for example `<old-fullname>-installation-kek`. If the notes warn that a new KEK was generated for a database you reused, follow [Recover from a KEK generated by mistake](#recover-from-a-kek-generated-by-mistake).

If the immutable generated KEK Secret contains the wrong value, delete and recreate that Secret from the original backup; never generate a new key for a database you keep.

### Recover from a KEK generated by mistake

Use this when the notes warned about a new KEK on a release whose database was reused, and the backend does not start. Delete only the failed backend Deployment as shown below so Helm can restart it with the original KEK.

1. Identify the retained Secret that holds the original KEK, for example `<old-fullname>-installation-kek`, or recreate it from the backup taken with the database.
2. Set `installation.kek.existingSecret` to that Secret name (and `installation.kek.key` if its key is not `installation-kek`) in the values file.
3. Delete the failed backend Deployment. Use the same kubectl context and namespace as the `helm` command; the command stops unless `KUBE_CONTEXT` and `NAMESPACE` are set, because an empty context would make kubectl use its current one, possibly another cluster. The release namespace is also printed in the warning. The backend is not serving while it refuses to start, so this adds no downtime:

   ```bash
   kubectl --context "${KUBE_CONTEXT:?set KUBE_CONTEXT to the exact context the helm command used}" \
     --namespace "${NAMESPACE:?set NAMESPACE to the exact namespace the helm command used}" \
     delete deployment <fullname>-backend
   ```

4. Run the same `helm upgrade` as before. The chart recreates the backend with the original KEK.
5. Verify that the backend starts and decrypts its credential:

   ```bash
   kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
     rollout status deployment/<fullname>-backend --timeout=20m
   kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
     port-forward service/<fullname>-backend 8090:8090
   curl -fsS http://127.0.0.1:8090/ready
   curl -fsS http://127.0.0.1:8090/startupStatus | jq
   ```

   The backend refuses to start when it cannot decrypt its stored installation credential, so a ready backend has opened it with the original KEK. The **Installation Identity** section of the Backend Status page shows the installation status it had before.
6. The mistakenly generated `<fullname>-installation-kek` Secret is kept by its retention policy but no longer used. Delete it once the backend is healthy, so that it is never mistaken for the original.

### Manage the installation Secrets yourself

For `helm template` or Argo CD installations, create both Secrets yourself and set the values below. Use the original KEK when keeping an existing database. For a new installation, generate each value with `openssl rand -base64 32 | tr -d '\n'`.

```yaml
installation:
  kek:
    existingSecret: noves-canton-data-app-installation-kek
    key: installation-kek
  canary:
    existingSecret: noves-canton-data-app-installation-canary
    key: installation-canary-capability
```

For a new installation, write each value to a private temporary file so it never appears in a command line:

```bash
umask 077
value_file="$(mktemp)"
openssl rand -base64 32 | tr -d '\n' > "$value_file"
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  create secret generic noves-canton-data-app-installation-kek \
  --from-file=installation-kek="$value_file"
openssl rand -base64 32 | tr -d '\n' > "$value_file"
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  create secret generic noves-canton-data-app-installation-canary \
  --from-file=installation-canary-capability="$value_file"
rm -f "$value_file"
```

After changing the canary Secret, run `helm upgrade` to roll both deployments. If you update it without a Helm upgrade, restart both deployments so they read the new value. Keep the original KEK when retaining the database; see the [Security model](security.md#installation-credential-secrets).

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

m2mIndexing:
  existingSecret: noves-canton-data-app-m2m-indexing-auth

canton:
  scanApiUrl: http://validator-app:5003/api/validator
  nodes:
    - id: main-node
      addr: participant:5001
      validatorParty: ""
      synchronizerAlias: global
      tls:
        existingSecret: noves-canton-ledger-mtls
        certificateKey: ca.crt
        clientCertificateKey: client.crt
        clientPrivateKeyKey: client.key
        serverName: ledger.example.com
      m2mIndexing:
        mode: global

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

An empty backend host produces `api.data.example.com`. An empty backend TLS Secret reuses `routing.tlsSecret`; that certificate must include both hostnames. Set `routing.backend.tlsSecret` when the backend uses a separate certificate. With Istio, the Gateway terminates TLS, so its certificate must cover both names.

Each node's `tls.certificateKey` is the participant server CA, not the client certificate. When the participant uses a publicly or otherwise system-trusted server certificate, keep the client pair and set `certificateKey: ""`; the chart then omits `cert_file` and the backend performs normal system hostname validation. The client keys must be set together and require `tls.existingSecret`.

`tls.serverName` is optional and should match the participant certificate SAN when `addr` uses a different internal host name.

For embedded mode, add the exact origins allowed to host the iframe:

```yaml
embedded:
  allowedOrigins:
    - https://host.example.com
```

Leave `embedded.allowedOrigins` empty for a standalone deployment. See the [embedded mode guide](../embedded_mode.md).

The backend stores exports on the retained `/exports` PVC by default. Set `exports.storage: s3` only when you have configured the typed `exports.s3` block and bucket access. Transaction-history backups use the independent `backup.s3` block. See [`values.yaml`](../chart/noves-canton-data-app/values.yaml) for the Secret key names and optional endpoint and region fields, and see [Container environment variables](environment-variables.md) for the variables injected into each container.

The defaults under `backend.performance` and `backend.streaming` suit a standard deployment. Change one value at a time while observing database load, backend memory, M2M indexing lag, and stream delivery.

Each `canton.nodes` entry is connected and indexed independently. Array order selects only the default node used by requests that omit `nodeId`; it does not establish a leader/follower or replication relationship.

For example, two participants that accept the same global M2M credentials can use:

```yaml
m2mIndexing:
  existingSecret: noves-canton-data-app-m2m-indexing-auth

canton:
  nodes:
    - id: validator-a
      addr: participant-a:5001
      validatorParty: "ValidatorA::..."
      synchronizerAlias: global
      tls: {}
      m2mIndexing:
        mode: global

    - id: validator-b
      addr: participant-b:5001
      validatorParty: "ValidatorB::..."
      synchronizerAlias: global
      tls: {}
      m2mIndexing:
        mode: global
```

`id`, `addr`, `tls`, and `m2mIndexing.mode` are required for every entry. `validatorParty` is an optional override for automatic discovery. `synchronizerAlias` is optional and defaults to `global`. An empty `tls: {}` selects plaintext and is valid only when the internal Ledger API connection does not require TLS.

`m2mIndexing.mode: global` uses the top-level `m2mIndexing.existingSecret` for every node that selects it. The same M2M token is presented to each participant, so its exact `sub` must exist as a Canton user with only `CanReadAsAnyParty` on every distinct participant. This is one shared user ID provisioned independently on each participant, not multiple users per validator.

To use a node-specific identity, create a separate
Secret and select `clientCredentials` or `staticToken`. The chart projects only that node's chosen
secret file into the backend pod under `/m2m-indexing-secrets/<node-id>`; the ConfigMap contains metadata
and a file path, never a secret value, and the frontend receives no mount.

```yaml
canton:
  nodes:
    - id: validator-a
      addr: participant-a:5001
      tls: {}
      m2mIndexing:
        mode: clientCredentials
        tokenEndpoint: https://TENANT.auth0.com/oauth/token
        clientId: noves-canton-data-app-m2m-indexing
        audience: "" # optional
        scope: "" # optional
        existingSecret: noves-canton-data-app-node-m2m-indexing
        clientSecretKey: client-secret
```

Create that Secret with `client-secret` from your secret manager. For a static token, use
`mode: staticToken`, set `existingSecret` and `staticTokenKey`, and leave the client-credentials
fields empty. Missing fields or mixed modes fail chart rendering; an explicit invalid file leaves
that node unready without using the global fallback. Restart the backend deployment after changing
the selected Secret because M2M indexing clients read the file at startup. The chart keeps
`M2M_INDEXER_ENABLED=true` in every mode; global token-source environment variables are rendered if
any node uses global mode. The top-level `m2mIndexing.existingSecret` is required only in that case.

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

Install the exact published OCI chart with the checked-out helper. `--version` selects the OCI chart
version; the checkout supplies its default but the helper never installs the local chart directory:

```bash
scripts/install-helm.sh \
  --kube-context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE" \
  --version 4.1.3 \
  --values /secure/path/values.yaml
```

The equivalent direct command is context- and version-explicit:

```bash
helm upgrade --install noves-canton-data-app \
  oci://ghcr.io/noves-inc/charts/noves-canton-app \
  --version 4.1.3 \
  --kube-context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE" \
  --values enterprise-values.yaml \
  --wait \
  --timeout 20m
```

## 7. Verify startup and M2M indexing

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

Open `https://api.data.example.com/docs` for Swagger UI. Requests to `/docs` on `data.example.com` still go to the frontend SPA because that hostname routes to the frontend Service.

`/ready` proves that startup and database preparation finished. It does not prove that participant M2M indexing is running. The M2M indexing response should report `captureEnabled: true`; after initial loading, the node should report `initialCaptureComplete: true` and `caughtUp: true`.

## Troubleshooting

### Existing runtime ServiceAccounts and component placement

`backend`, `frontend` and `database` each accept `serviceAccountName` and
`automountServiceAccountToken`. An empty or absent name uses the namespace default
ServiceAccount; token mounting is `false` by default. A supplied name must identify
an existing ServiceAccount in the release namespace. The chart creates no
ServiceAccount, Role or RoleBinding and grants no Kubernetes API permissions, so
review the permissions of the ServiceAccount you name. Keep token mounting disabled
for ordinary application runtimes.

Each component also accepts `nodeSelector` and `tolerations`. Missing or `null` values
inherit the existing global setting. Explicit `{}` and `[]` clear that component's
setting; nonempty values replace it. Global `affinity` remains unchanged. Setting
only backend/frontend placement leaves the database workload and volume claims
unchanged. To move the database, plan a maintenance window, stop database writers
and confirm that its storage can attach to the destination nodes and zones.

Changing placement or a ServiceAccount does not change the database/export PVCs or
the accounting and installation Secret names. Keep using the original installation
KEK; see the [Security model](security.md#installation-credential-secrets).

| Symptom | Check |
|---|---|
| `ImagePullBackOff` | `kubectl describe pod`; fix ACR or GHCR access and `imagePullSecrets` |
| Database pod pending | `kubectl get pvc` and `kubectl describe pvc`; check the StorageClass and zone constraints |
| Ingress has no address | `kubectl get ingressclass` and `kubectl describe ingress`; confirm `routing.ingress.className` |
| Backend hostname does not resolve | Check the `api.` DNS record or the explicit `routing.backend.host` value |
| Backend TLS certificate mismatch | Add both names to the shared certificate or set `routing.backend.tlsSecret` |
| Istio render fails server dry-run | Install the VirtualService CRD or select `routing.provider: ingress` |
| Backend stays unready | Read `/startupStatus`, then backend logs |
| Ledger API TLS handshake fails | Check the node's client certificate/key pair, server CA or system trust, server-auth EKU, and that `canton.nodes[].tls.serverName` or `canton.nodes[].addr` matches a certificate SAN |
| Ledger API rejects the client | Confirm the participant trusts the client issuer and that `client.crt` includes any required intermediate certificates |
| Init container `installation-secrets` fails | Read its log; the named Secret key must hold the base64 encoding of 32 bytes (44 characters, no newline) |
| `helm upgrade` reports a missing installation KEK | Re-apply the backed-up `<release>-installation-kek` Secret; never let the chart generate a replacement for a database you keep |
| M2M indexing disabled or stale | Read `/api/v2/capture/status`; verify the M2M indexing Secret, token subject, Canton user, and its exact rights |
| Browser login loops | Compare the Auth0 callback, logout, origin, audience, and `oidc.appUrl` values |
| Browser sign-in succeeds but Ledger API calls return `401` | Inspect a newly issued browser token; confirm its issuer, Ledger API audience, provider-required scope, and exact `sub`, then confirm the matching Canton user exists on the selected participant |
| Startup fails while reading connected synchronizers | Inspect the M2M token and confirm its issuer, Ledger API audience, exact `sub`, matching Canton user, and `CanReadAsAnyParty` right for the affected node |

## Uninstall

```bash
helm uninstall noves-canton-data-app \
  --kube-context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE"
```

Helm retains the database PVC, exports PVC, generated accounting-key Secret, and generated installation KEK Secret. Remove them only after satisfying backup and retention requirements; see the [Security model](security.md#installation-credential-secrets). Helm deletes the canary capability Secret, and the next installation gets a new one.
