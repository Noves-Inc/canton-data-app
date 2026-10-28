# Canton Data App 4.2.5

## Balances and indexing

- Canton Coin balance requests fetch only Canton Coin contracts, reducing work for parties that hold many other contracts.
- History activation waits briefly for indexing work and retries when busy. Switching nodes or signing out cancels stale frontend requests.
- Indexing and export workers recover from additional transient authentication and database contention failures. A pooled database transaction lifetime issue is fixed.
- Support diagnostics preserve indexing state needed to investigate incomplete history.

## Partner reports

- Monthly issuer reports retain complete partner totals and load round attribution on demand.
- Detailed report CSV downloads stream through the browser download manager to reduce memory use for large reports.
- Full-range settlement calculations no longer use the previous report-size limits.

## Upgrade

Use the complete 4.2.5 Compose bundle or Helm chart and its pinned images. Follow the [upgrade guide](upgrade-4.2.2.md). This patch adds no database migration beyond 4.2.4.

These fixes do not repair reverse-proxy TLS configuration or guarantee that an existing indexing backlog has finished. Check readiness and account access after upgrading.
