# Canton Data App 4.2.4

## Account access

Existing members can initialize their account when their identity provider omits an email address or display name. Previously saved profile information is preserved. Account permissions still apply.

## Frontend fixes

- Cloud logout completes the identity-provider sign-out before returning to login, including recovery after a lost response.
- Large asset issuer report PDFs render one page at a time, without capturing unrelated page content.
- Public dashboard transaction counts follow the selected date range and show when a count is unavailable.
- Public summaries retry a transient connection reset once. Report retries preserve the submission identity to avoid duplicate jobs.

## Upgrade

Use the complete 4.2.4 Compose bundle or Helm chart and its pinned images. Follow the [upgrade guide](upgrade-4.2.2.md). This patch adds no database migration beyond 4.2.3.
