# Canton Data App 4.2.8

- Usage analytics send valid timestamps and respect account opt-out.
- Failed-export diagnostics include job and request correlation, failure phases, logs and available database evidence.
- Oldest-first history reads stay bounded on large installations. A delayed health probe retries once before interrupting an established healthy session.
- Database storage pressure is configurable with `DATABASE_VOLUME_USAGE_LIMIT`, default **0.85** of declared `DATABASE_VOLUME_CAPACITY`. Historical work pauses under pressure while live activity continues.
- Classified updates include missing historical Canton Coin prices when the account has pricing access.
- Enriched coupon conversions retain their classification. Issuer and venue reports support the November 5 composition guidance; large saved reports load without blocking the page, and PDFs wait for round evidence.
- The classifier diagnostic resolves the contextual classifier used by the app.
- Transaction counterparties remain visible without hovering. This maintenance release does not replay the previous feature tour.

Use the complete **4.2.8** Compose bundle or Helm chart with its pinned images.
Take a database backup first and allow startup preparation to finish. Startup adds
diagnostic metadata while preserving existing transaction history. Follow the
[upgrade guide](upgrade-4.2.2.md) and [Helm](helm.md) or [Docker Compose](docker-compose.md)
guide. For Helm, use the attached `noves-canton-app-4.2.8.tgz` chart and do not use `--reuse-values`.
