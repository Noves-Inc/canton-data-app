# CLAUDE.md: Public Canton Data App Deployment

This public repository owns the v4 Helm chart, Docker Compose bundle, guided installers, migration
guide, and operator documentation.

## Release and configuration rules

- Helm defaults and examples pin one plain v4 semantic version. Semantic tags and chart versions are
  immutable; never reuse or force-move them.
- `latest` is allowed only in the three `-v4` image repositories and can never cross a major version.
  Helm upgrades remain constrained to `>=4.0.0 <5.0.0`.
- A chart release resolves and records the exact backend, frontend, and database image digests in
  `release-manifest.json`. Do not expose internal component identities in images, charts, manifests,
  runtime configuration, or customer documentation.
- Standard Helm and Compose operation must remain fully supported without the optional localhost
  wizard.
- Do not add `CDA_*` environment variables. Use direct domain names in project-scoped Compose files,
  `CANTON_*` for Canton integration, `NOVES_*` for Noves services, and `NOVES_DATA_APP_*` only for
  bootstrap-script overrides that need host-shell namespacing.
- Preserve all supported database/read-model tuning controls with typed Helm values and documented
  Compose variables. Defaults must remain usable without tuning.
- Streaming stays inside the backend image and uses the existing `/api/v2` frontend/BFF route,
  including WebSocket upgrades. Do not add a stream workload, port, service URL, database, or
  `CANTON_STREAM_URL`. Keep the typed `backend.streaming` values and matching `STREAM_*` Compose
  controls aligned.
- Configuration, secret names, ports, storage, probes, and version changes require matching chart,
  Compose, installer, schema, tests, and operator documentation.

Run `tests/all.sh` and `git diff --check` before handoff. Do not publish, push, deploy, or mutate an
operator's cluster unless explicitly requested.
