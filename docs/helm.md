# Helm installation

The chart is a conventional application chart. `setupWizard.enabled` is `false` by default, so
Flux, Argo CD, Terraform, or a direct `helm upgrade --install` works without the guided flow.

## Prerequisites

- Helm 3 and Kubernetes 1.27 or newer
- a validator in the target namespace, normally `validator`
- a default participant Service reachable at `participant:5001`
- a default validator app Service reachable at `validator-app:5003`
- durable storage and either the standard Canton Istio gateway or an Ingress controller

Create the database Secret:

```bash
kubectl --namespace validator create secret generic noves-canton-data-app-database \
  --from-literal=POSTGRES_PASSWORD='replace-with-a-long-random-value'
```

Create the dedicated capture Secret:

```bash
kubectl --namespace validator create secret generic noves-canton-data-app-capture-auth \
  --from-literal=M2M_INDEXER_ENABLED=true \
  --from-literal=M2M_TOKEN_ENDPOINT='https://issuer.example.com/oauth/token' \
  --from-literal=M2M_CLIENT_ID='replace-me' \
  --from-literal=M2M_CLIENT_SECRET='replace-me' \
  --from-literal=M2M_AUDIENCE='https://canton.network.global' \
  --from-literal=M2M_SCOPE=''
```

Use your normal secret manager instead of imperative commands in production. The Secret must
contain a new least-privilege capture identity; it must not contain a validator credential.

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

## Routing

Only one routing provider may be enabled. The chart routes only
`noves-canton-data-app-frontend`; the backend and database have cluster-internal Services.

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
