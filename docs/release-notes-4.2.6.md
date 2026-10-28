# Canton Data App 4.2.6

## Exports

- An export interrupted before it finishes, for example while the database is busy, uses bounded retries instead of incorrectly reporting that it exceeded its runtime. If retries are exhausted, the UI tells you to resubmit rather than promising another automatic retry.
- A short database outage no longer cancels an export that is still running. If the database is unavailable when an export failure is recorded, the worker waits and resumes once the database recovers without requiring an application restart.
- Failed self-hosted exports offer a **Report** button. The report includes the export's job ID, its recent backend log entries, and the database's load and settings.

## History initialization

- Pending cleanup from retired or superseded history no longer incorrectly pauses history initialization. Initialization still slows or pauses when current indexing work or database resources are overloaded.

## Asset issuer reports

- Reports now compare emitted and eligible marker weight, show the difference, and indicate when evidence is incomplete. This analysis is also included in PDF downloads.

## Support diagnostics

- Automatic backend diagnostic reports include database load and configuration: connection counts and states, what active queries are waiting on, cache and temporary-file counters, and memory and connection settings. No query text or credentials are collected.
- Backend reports for an export now include that export's own log entries.

## Upgrade

Use the complete 4.2.6 Compose bundle or Helm chart and its pinned images. Follow the [upgrade guide](upgrade-4.2.2.md). This patch adds no database migration beyond 4.2.4.
