# Traffic Analyzer (Optional Addon)
<img width="1491" height="846" alt="image" src="https://github.com/user-attachments/assets/903add9e-3216-4a8d-b8d6-bbdcd9dedb7e" />


## Overview

This optional addon enables the Noves Data App to correlate Canton traffic costs with individual transactions. It uses Fluent Bit to collect participant logs and stream them to the Data App backend for processing.

**This is an optional feature.** The main Data App functions fully without it. Install this addon only if you need traffic cost visibility.

## How It Works

1. Fluent Bit collects logs from your Canton participant container
2. Logs are filtered to include only traffic-relevant entries
3. Filtered logs are sent via HTTP to the Data App backend (port 5124)
4. The backend correlates traffic costs with transaction IDs
5. Traffic cost data is available via the Traffic Cost API in the backend container (and visible in the UI)

## Requirements

- Noves Data App backend running with `TRAFFIC_ANALYSIS_ENABLED=true` environment variable set (default is `false`)
- Canton participant configured to emit JSON logs to stdout
- `LOG_LEVEL_CANTON=DEBUG` must be set on your Canton participant to capture traffic-related log lines
- Fluent Bit 2.x

## Directory Structure

```
├── kubernetes/          # Kubernetes deployment (Helm values)
│   ├── README.md
│   └── values-fluentbit.yaml
└── docker-compose/      # Docker Compose deployment
    ├── README.md
    ├── fluent-bit.conf
    ├── parsers.conf
    └── compose.yaml
```

## Quick Start

### Docker Compose

```bash
cd docker-compose
docker compose up -d
```

See [docker-compose/README.md](docker-compose/README.md) for detailed instructions.

### Kubernetes

```bash
cd kubernetes
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update
helm upgrade -i fluent-bit fluent/fluent-bit \
  -n logging --create-namespace \
  -f traffic-analyzer/kubernetes/values-fluentbit.yaml
```

See [kubernetes/README.md](kubernetes/README.md) for detailed instructions.


## Participant Configuration

Ensure your Canton participant emits the necessary DEBUG logs. Set in your participant environment:

```yaml
environment:
  LOG_LEVEL_CANTON: DEBUG
```
