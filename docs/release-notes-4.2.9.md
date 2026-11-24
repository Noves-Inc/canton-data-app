# Canton Data App 4.2.9

Self-hosted installations can configure PostgreSQL's temporary-file budget using
`backend.performance.database.tempFileLimitMb` in Helm or `DATABASE_TEMP_FILE_LIMIT_MB`
in Compose. When unset, the existing budget and earlier 2 GiB ceiling are preserved. For example, 8192
allows 8 GiB per process. Choose a finite budget that fits the available storage and concurrency.

The backend applies and validates the configured runtime-role setting during startup.
This adjustment does not change lock timeouts or guarantee completion of a slow export.
See [database tuning](https://github.com/Noves-Inc/canton-data-app/blob/v4.2.9/docs/helm.md#database-connection-limits-and-timeouts) for restricted-role,
validation-only startup and downgrade instructions.

Use the complete **4.2.9** Compose bundle or Helm chart and its pinned images.
Take a database backup first and allow startup preparation to finish.
For Helm, use the attached chart and your values file; do not use `--reuse-values`.
