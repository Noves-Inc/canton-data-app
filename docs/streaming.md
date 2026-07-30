# Streams, alerts, and connectors

In v4, the Noves App runs streaming inside the backend. You do not need another container, port,
database, token-signing setting, or service URL. REST calls use `/api/v2/streams`,
`/api/v2/alerts`, and `/api/v2/connectors` through the normal application origin.

## WebSockets

When a stream has WebSocket delivery enabled, its create response includes a relative URL such as:

```text
/api/v2/streams/10000000-0000-0000-0000-000000000001/ws?secret=...
```

Use the application's existing origin and change only the scheme:

- `https://data.example.com` becomes `wss://data.example.com`;
- `http://127.0.0.1:8091` becomes `ws://127.0.0.1:8091`.

The frontend builds this URL automatically. Ingress and Istio routes use the existing frontend/BFF
route, so there is no streaming port to expose. Treat the stream secret as a credential. It is bound
to the subscription and selected validator node.

## Webhooks and private networks

Webhook targets must use HTTPS and resolve to a public address by default. This protects the
operator's internal network from requests caused by an untrusted callback URL.

Set `backend.streaming.allowPrivateWebhookTargets: true` in Helm, or
`ALLOW_PRIVATE_WEBHOOK_TARGETS=true` in Compose, only when an intentional callback receiver is on a
private network. Keep network policy and receiver authentication in place.

## Throughput controls

The defaults suit a typical validator and require no changes. Higher-volume operators can tune:

| Helm value under `backend.streaming` | Compose variable | Purpose |
|---|---|---|
| `pollIntervalMs` | `STREAM_POLL_INTERVAL_MS` | Idle polling interval |
| `pageSize` | `STREAM_PAGE_SIZE` | Source records considered per page |
| `retryDelayMs` | `STREAM_RETRY_DELAY_MS` | Delay before delivery retries |
| `websocketBufferLimit` | `STREAM_WEBSOCKET_BUFFER_LIMIT` | Buffered messages per subscription |
| `databaseTimeoutSeconds` | `STREAM_DATABASE_TIMEOUT_SECONDS` | Database command timeout |
| `deduplicationWindowRecords` | `STREAM_DEDUPLICATION_WINDOW_RECORDS` | Duplicate-suppression window |
| `deliveryRecencyMinutes` | `STREAM_DELIVERY_RECENCY_MINUTES` | Maximum event age for new delivery; `0` disables the age check |

Increase page and buffer sizes only with matching backend and database memory. Reduce the polling
interval only after checking database load. The chart schema and backend reject values outside their
supported ranges.

## Migration from v3

The supported v3.16.1 upgrade preserves subscriptions, connectors, alert rules, delivery secrets,
delivery history, and WebSocket buffers. After the historical v4 replay completes, streaming starts
from that completed replay boundary so preserved rules do not resend the migrated history.

Follow [Migrate from v3.16.1 to v4 of the Noves App](migrate-v3.16.1.md). Keep v3 stopped throughout the upgrade.
