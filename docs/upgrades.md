# v4 upgrades and future major versions

## Helm

The guided installer uses:

```text
>=4.0.0 <5.0.0
```

That range accepts v4 fixes and features but refuses a v5 chart. GitOps operators can use the
same range or an exact version. Review chart release notes and backups before changing the
pinned version.

Helm does not silently move a release between major versions. A future v5 requires a planned
chart upgrade and its migration guide.

## Images

The prerelease chart currently uses private images:

```text
noves.azurecr.io/cda-backend:prod-3e1a1fde-1785439104
noves.azurecr.io/cda-frontend:prod-c78cdd33-1785419965
ghcr.io/noves-inc/noves-canton-database-v4:candidate-30160846627-1
```

The chart defaults pin each image by tag and digest. Override both fields together when selecting another build:

```yaml
backend:
  image:
    repository: noves.azurecr.io/cda-backend
    tag: prod-3e1a1fde-1785439104
    digest: sha256:replace-with-a-64-character-digest
```

The public release will replace these defaults with immutable v4 release images. Each chart
release will publish `release-manifest.json` beside the packaged chart. It records the
chart commit and the public source repository, commit, and exact digest for each of the three
Data App images. It contains no internal dependency identity. Use those digests as release evidence
or pin them directly in environments that require digest-only deployment.

After publication, download and verify a release before promoting it:

```bash
gh release download v4.0.0 \
  --repo Noves-Inc/canton-data-app \
  --pattern 'release-manifest.json' \
  --pattern 'noves-canton-data-app-4.0.0.tgz' \
  --pattern 'SHA256SUMS'
sha256sum --check SHA256SUMS
gh attestation verify noves-canton-data-app-4.0.0.tgz \
  --repo Noves-Inc/canton-data-app
gh attestation verify release-manifest.json \
  --repo Noves-Inc/canton-data-app
```

Compose pins the same artifacts as complete per-service references in `.env`:

```dotenv
BACKEND_IMAGE=noves.azurecr.io/cda-backend:prod-3e1a1fde-1785439104@sha256:37cad1fe33871bf08ba1be9699c11e87c643931e51d295c9de7bfed8afe1c793
FRONTEND_IMAGE=noves.azurecr.io/cda-frontend:prod-c78cdd33-1785419965@sha256:3205d0193e1b493098f9d1704604206f173fb456aa6fb6dbcc8b8529f70266b1
DATABASE_IMAGE=ghcr.io/noves-inc/noves-canton-database-v4:candidate-30160846627-1@sha256:1482f1bbe6ca9039ebe4bdcdf7442d34acf9389b2799215b95e10ee8d01ba49b
```

Update one or more complete references only after verifying that the selected backend, frontend,
and database builds belong to the same Noves App release.

## Upgrade procedure

1. Read the release notes.
2. Back up the database and record the current chart/image versions.
3. Update the exact v4 chart or image version.
4. Watch `/startup-status` and readiness.
5. Verify sign-in, participant identity, capture, and a representative query.

For Compose, preserve the named database and export volumes and
`.state/accounting.env`. Run `docker compose down` without `--volumes`, update the three image
references, then rerun `install-compose.sh --standard`. The installer reuses the accounting key and
waits for backend readiness.

Database migrations are forward-only. Rollback means starting a compatible older v4 image when
the release allows it, or restoring the pre-upgrade backup. Never point a different PostgreSQL
major at an existing volume.

## Secret rotation

Create a new client secret, update only the dedicated capture Secret or `capture.env`, restart
the backend, and verify capture. Revoke the old identity-provider secret after the new one works.
