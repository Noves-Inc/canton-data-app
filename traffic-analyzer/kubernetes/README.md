# Fluent Bit for Kubernetes

Collect Canton participant logs from Kubernetes pods and send to the Data App backend for traffic cost analysis.

## Prerequisites

- kubectl configured for your cluster
- Helm v3 installed
- Canton participant pods in a known namespace (default: `validator`)
- Participant emitting JSON logs with `LOG_LEVEL_CANTON=DEBUG`
- Noves Data App backend deployed with `TRAFFIC_ANALYSIS_ENABLED=true` environment variable set

## Install Fluent Bit

```bash
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

helm upgrade -i fluent-bit fluent/fluent-bit \
  -n logging --create-namespace \
  -f traffic-analyzer/kubernetes/values-fluentbit.yaml
```

## Configuration

### Backend Service Name

Update the backend service hostname in `values-fluentbit.yaml` to match your deployment:

```ini
[OUTPUT]
    Name              http
    Match             kube.*
    Host              data-app-backend.YOUR_NAMESPACE.svc.cluster.local
    Port              5124
    ...
```

The default assumes the backend service is named `data-app-backend` in the `validator` namespace.

### Namespace

If your participant runs in a namespace other than `validator`, update the `Path` in `values-fluentbit.yaml`:

```ini
Path              /var/log/containers/*_YOUR_NAMESPACE_*.log
```

### Container Runtime

The default parser is `cri` (containerd). If your cluster uses Docker runtime, change:

```ini
Parser            docker
```

## Verify Installation

```bash
# Check pods
kubectl -n logging get pods -l app.kubernetes.io/name=fluent-bit

# Check logs
kubectl -n logging logs daemonset/fluent-bit --tail=50

# Verify backend is receiving data
kubectl exec -it deploy/data-app-backend -n validator -- curl localhost:5124/queue-stats
```

## Log Filtering

The configuration filters logs to only include traffic-relevant lines:

- `TrafficReceipt(`
- `EventCostDetails(`
- `Processing event`
- `messageId=`
- `updateId`
- `workflowId`
- `commandId`
- Transaction sequencing events

To temporarily disable filtering for debugging, comment out the grep filter section in `values-fluentbit.yaml`.

## Uninstall

```bash
helm uninstall fluent-bit -n logging
```

## Troubleshooting

### No data appearing in the Traffic Cost API

1. Verify participant is running and emitting logs:
   ```bash
   kubectl logs -n validator <participant-pod> | head
   ```

2. Check participant has DEBUG logging enabled

3. Verify Fluent Bit can reach the backend:
   ```bash
   kubectl -n logging exec -it daemonset/fluent-bit -- \
     wget -q -O- http://data-app-backend.validator.svc.cluster.local:5124/health
   ```

4. Temporarily remove the grep filter to verify ingestion

### Connection refused errors

Ensure the Data App backend service is running and the service name in `values-fluentbit.yaml` is correct.

### Permission errors

Ensure Fluent Bit has read access to `/var/log/containers/`. The RBAC configuration in the values file should handle this.

### Wrong parser

If logs appear garbled, check your container runtime and switch between `cri` and `docker` parsers.
