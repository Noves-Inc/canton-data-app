# Canton Data App 4.2.11

Improves history indexing on large databases with bounded discovery queries,
progress logging and clearer retry diagnostics. Existing history semantics and
completed indexes are preserved.

Use the complete **4.2.11** Compose bundle or Helm chart and its pinned images.
Take a database backup first and allow startup preparation and history indexing
to finish. For Helm, use the attached chart and your values file; do not use
`--reuse-values`. Keep any database tuning values you configured previously,
including `backend.performance.database.tempFileLimitMb`.
