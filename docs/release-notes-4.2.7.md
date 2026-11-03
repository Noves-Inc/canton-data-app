# Canton Data App 4.2.7

## Database timeouts and diagnostics

- Helm exposes database pool size, connection timeout, and command timeout as individual values. The default maximum pool size is **40** and command timeout is **120 seconds**. Connection acquisition keeps its **15-second** default. Existing connection-string Secrets remain supported.
- Automatic diagnostic reports identify the database operation, validator node, failure phase, configured timeouts, and available connection-pool and database wait evidence. Evidence is retained when a request deadline expires while waiting for a connection and when a fatal database error is sanitized for reporting.
- Reports distinguish available evidence for connection acquisition, command execution, result reading, and bulk writes. Slow operations can include bounded database wait and blocking-session information. The new database evidence excludes SQL text, query parameters, returned rows, and credentials.
- Temporary diagnostic-delivery failures recover automatically. Database evidence remains subject to the installation's diagnostic consent settings.

The command timeout is separate from application request deadlines. Increasing it does not extend every history request or remove database resource limits. An explicit `INDEX_DB_CONNECTION_STRING` takes precedence over the standalone settings; update that string or remove the override while preserving any required TLS options. Docker Compose retains its existing defaults; see [database configuration](environment-variables.md).

## History and participant access

- Compatible pending-token-offer history corrections run in the background while new activity continues through history, dashboards, Flow, and exports. A failed scope remains visible without blocking unrelated repairs.
- Participant token refresh and authorization retries are bounded. Traffic indexing stays inactive when capture is disabled, and permission failures stop repeated uptime refresh attempts.

## Issuer reports and data sharing

- Issuer reports preserve payment evidence and calculation settings, distinguish verified zero emissions from missing evidence, and avoid deducting registry payments twice.
- Saved DA Utility reports open immediately and refresh in the background. Summary, round details, and downloads use consistent emission evidence and historical fallback calculations.
- Detailed issuer CSV downloads preserve the selected validator and stream without buffering the entire report in browser memory.
- Fixed-size data-sharing proposals require their saved file and send it automatically after acceptance.

## Upgrade

Use the complete **4.2.7** Compose bundle or Helm chart and its pinned backend,
frontend, and database images. The frontend displays **4.2.7**. Follow the
[upgrade guide](upgrade-4.2.2.md). This release adds database metadata for
background history repairs. The startup migrations preserve existing history
and do not change the database compatibility level. Take a database backup before
upgrading and allow startup preparation to finish.
