# Canton Data App 4.2.6

## Exports

- An export interrupted before it finishes, for example while the database is busy, now retries and shows "interrupted before it finished" instead of failing as "exceeds processing limits". The "narrow the date range" message is shown only when an export actually reaches its maximum runtime or size.
- A short database outage no longer cancels an export that is still running.
- Failed exports offer **Send diagnostic report**. The report includes the export's job ID, its backend log entries, and the database's load and settings.

## Support diagnostics

- Automatic backend diagnostic reports include database load and configuration: connection counts and states, what active queries are waiting on, cache and temporary-file counters, and memory and connection settings. No query text or credentials are collected.
- Backend reports for an export now include that export's own log entries.

## Upgrade

Use the complete 4.2.6 Compose bundle or Helm chart and its pinned images. Follow the [upgrade guide](upgrade-4.2.2.md). This patch adds no database migration beyond 4.2.4.
