# Helm installation

The chart is a conventional application chart. `setupWizard.enabled` is `false` by default, so
Flux, Argo CD, Terraform, or a direct `helm upgrade --install` works without the guided flow.

## Prerequisites

- Helm 3 and Kubernetes 1.27 or newer
- a validator in the target namespace, normally `validator`
- a default participant Service reachable at `participant:5001`
- a default validator app Service reachable at `validator-app:5003`
- durable storage and either the standard Canton Istio gateway or an Ingress controller

Set `database.persistence.storageClass` to an encrypted StorageClass for fresh storage, or set
`database.persistence.existingClaim` to an operator-managed encrypted PVC. See
[Encryption at rest](../encryption_at_rest.md).

Create the database Secret:

```bash
kubectl --namespace validator create secret generic noves-canton-data-app-database \
  --from-literal=postgres-password='replace-with-a-long-random-value'
```

Create the dedicated capture Secret:

```bash
kubectl --namespace validator create secret generic noves-canton-data-app-capture-auth \
  --from-literal=ledger-api-user='exact-token-subject' \
  --from-literal=token-endpoint='https://issuer.example.com/oauth/token' \
  --from-literal=client-id='replace-me' \
  --from-literal=client-secret='replace-me' \
  --from-literal=audience='https://canton.network.global' \
  --from-literal=scope=''
```

Use your normal secret manager instead of imperative commands in production. The Secret must
contain a new least-privilege capture identity; it must not contain a validator credential.

Create a separate installation credential for the Noves gateway:

```bash
kubectl --namespace validator create secret generic noves-canton-data-app-gateway \
  --from-literal=token='replace-with-this-installation-credential'
```

Set `novesGateway.existingSecret` to that Secret and `novesGateway.tokenKey` to `token`.
The chart injects the same installation credential into the backend and BFF without placing
its value in Helm values. Rotate it by updating the Secret and restarting both Deployments.

## Install

Copy the [enterprise example](../chart/noves-canton-data-app/examples/enterprise-values.yaml),
set the participant ID, OIDC values, route, and existing Secret names, then run:

```bash
helm upgrade --install noves-canton-data-app \
  oci://ghcr.io/noves-inc/charts/noves-canton-data-app \
  --version '>=4.0.0 <5.0.0' \
  --namespace validator \
  --create-namespace \
  --values enterprise-values.yaml
```

The version constraint admits compatible v4 chart releases and refuses v5. For fully
reproducible environments, replace it with an exact chart version.

## Performance tuning

The chart exposes database and read-model controls under `backend.performance`. Defaults are
safe for a typical single-node installation. Higher-volume operators can increase database
resources and then tune:

```yaml
backend:
  performance:
    database:
      writeBatchSize: 250
      maxParallelWorkersPerGather: 2
      synchronousCommit: "off"
      maxWalSize: 16GB
    readModel:
      totalCapacity: 8
      reservedLiveCapacity: 2
      bootstrapBatchSize: 50
  streaming:
    pageSize: 250
    websocketBufferLimit: 25000
```

Increase one dimension at a time while observing database CPU, memory, connection utilization,
write latency, capture lag, and `/startup-status`. The complete typed set is in
[`values.yaml`](../chart/noves-canton-data-app/values.yaml).
See [Streams, alerts, and connectors](streaming.md) for every streaming control and the private
webhook policy.

## Routing

Only one routing provider may be enabled. The chart routes only
`noves-canton-data-app-frontend`; the backend and database have cluster-internal Services. Streaming
REST and WebSocket traffic uses that same route.

For the standard Canton Istio gateway:

```yaml
routing:
  enabled: true
  host: data.example.com
  istio:
    enabled: true
    gateway: cluster-ingress/cn-http-gateway
```

For a standard Ingress:

```yaml
routing:
  enabled: true
  host: data.example.com
  tlsSecret: data-example-com-tls
  ingress:
    enabled: true
    className: nginx
```

Set the browser callback URL to `https://data.example.com/callback` and the logout URL to
`https://data.example.com`.

## Certificates and non-default Canton services

The defaults work with an unencrypted in-cluster Ledger API. To use TLS, create a Secret
containing the participant CA and set:

```yaml
canton:
  participantAddress: participant.example.com:443
  certificateSecret: participant-ledger-api-ca
  certificateKey: ca.crt
```

Change `canton.participantAddress` or `canton.validatorUrl` only when the validator does not use
the default Canton names.

## Observe startup

```bash
kubectl --namespace validator get pods
kubectl --namespace validator port-forward service/noves-canton-data-app-backend 8090:8090
curl http://127.0.0.1:8090/startup-status
```

Readiness stays false while database preparation or a migration is running. Health remains
available so operators can distinguish progress from a crash.

## Uninstall

```bash
helm uninstall noves-canton-data-app --namespace validator
```

The database and exports claims, and Secrets created outside Helm, are retained. Delete them
only after confirming backups and retention requirements.
