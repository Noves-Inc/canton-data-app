# Fluent Bit for Docker Compose

Collect Canton participant logs from Docker containers and send to the Data App backend for traffic cost analysis.

## Prerequisites

- Docker and Docker Compose installed
- Canton participant running as a Docker container
- Participant emitting JSON logs with `LOG_LEVEL_CANTON=DEBUG`
- Noves Data App backend running with `TRAFFIC_ANALYSIS_ENABLED=true` environment variable set
- Know the network name of your validator stack (default: `splice-validator_splice_validator`)

## Setup

### 1. Configure the network

If your validator compose uses a different network name, update `compose.yaml`:

```yaml
networks:
  splice_validator:
    external: true
    name: YOUR_NETWORK_NAME
```

To find your network name:

```bash
docker network ls | grep validator
```

### 2. Configure the backend host

If your Data App backend container has a different name, update `fluent-bit.conf`:

```ini
[OUTPUT]
    Name              http
    Match             docker.*
    Host              YOUR_BACKEND_CONTAINER_NAME
    Port              5124
    URI               /ingest
    ...
```

The default assumes the backend container is named `canton-data-app-backend` and is on the same Docker network.

### 3. Start Fluent Bit

```bash
docker compose up -d
```

## Configuration

### Backend Endpoint

Logs are sent to the Data App backend at `http://canton-data-app-backend:5124/ingest`. The backend exposes a Traffic Cost API that:

- Accepts JSONL (newline-delimited JSON) log entries
- Queues entries for processing
- Correlates traffic costs with transaction IDs

### Filtering

The configuration filters logs to only include traffic-relevant lines. To capture all logs temporarily (for debugging), comment out the grep filter in `fluent-bit.conf`.

## Verify

```bash
# Check container status
docker compose ps

# Check Fluent Bit logs
docker compose logs fluent-bit

# Verify backend is receiving data (from the Data App)
curl http://localhost:5124/queue-stats
```

## Uninstall

```bash
docker compose down
```

## Troubleshooting

### No data appearing in the Traffic Cost API

1. Verify participant is running:
   ```bash
   docker ps | grep participant
   ```

2. Check participant has DEBUG logging enabled

3. Verify network connectivity:
   ```bash
   docker network inspect splice-validator_splice_validator
   ```

4. Check Fluent Bit can reach the backend:
   ```bash
   docker compose exec fluent-bit wget -q -O- http://canton-data-app-backend:5124/health
   ```

5. Temporarily remove grep filter to verify log ingestion

### Connection refused errors

Ensure the Data App backend is running and the container name matches the `Host` in `fluent-bit.conf`.

### Container log path

Docker stores container logs at `/var/lib/docker/containers/`. If this path differs on your system, update `fluent-bit.conf`:

```ini
[INPUT]
    Name              tail
    Path              /your/docker/path/*/*.log
```
