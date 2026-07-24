# Optional localhost setup wizard

The wizard is a launch aid, not a different deployment model. It collects the values that a
normal Helm or Compose installation needs, verifies them live, and activates the standard
three-container application.

## What it verifies

- HTTPS OIDC discovery pinned to the configured issuer
- a non-interactive browser-client callback check and a client-credentials token exchange
- the token's exact `sub` against the Canton user ID you entered
- `CanReadAsAnyParty`
- absence of participant administration, identity-provider administration, act-as, and
  execute-as rights
- participant ID and selected Canton network
- database readiness

TLS, DNS, the optional validator API, and optional public scan connectivity can be acknowledged
as warnings. Rights, identity, participant, and database failures block activation.

## Kubernetes safety boundary

The installer creates fixed names for:

- the result ConfigMap;
- the dedicated capture Secret;
- the temporary setup token Secret.

The temporary Secret contains separate `token` and `session-token` keys. The latter authenticates
every browser-to-wizard request and is delivered only in the localhost URL fragment. The wizard
has no Kubernetes Service, and its NetworkPolicy denies pod-to-pod ingress.

The wizard service account can only `get`, `update`, or `patch` the first two resources by exact
name. It cannot list Secrets, access Canton Secrets, patch Deployments, or perform cluster
administration. Public routing is rejected while the wizard is enabled; access is through a
localhost port-forward only.

After completion, the installer upgrades the release with `setupWizard.enabled=false`. Helm
removes the wizard Deployment, Service, service account, Role, RoleBinding, and result
ConfigMap. The capture Secret remains.

Completion is stored in the result ConfigMap. A restarted wizard refuses verification or
credential changes once that durable marker is present.

## Compose safety boundary

The Compose wizard binds only to `127.0.0.1:8099`, has no Docker socket, and writes:

- non-secret deployment values to `.state/values.json`;
- capture credentials to `.state/capture.env` with mode `0600`.

The separate browser session token is generated into the mode-`0600` `.env` used only by the
temporary setup stack. Completed state in `.state/values.json` prevents later credential changes
after a process restart.

The installer maps the setup process to the invoking host user's UID and GID so the published
non-root image can write these files on Linux. Credentials are written before the completion
marker, and both installers validate them before activation. The installer turns off the setup
stack before starting the normal application.

## Resume or stop

Re-run the same installer if the terminal closes. Existing generated state is reused. Stopping
the wizard does not modify participant rights and does not delete database storage.

For automation, set `NOVES_GATEWAY_AUTH_TOKEN` or
`NOVES_GATEWAY_AUTH_TOKEN_FILE`. Direct values take precedence over file values. An explicitly
selected missing, unreadable, or blank file fails immediately. Without either variable, the
guided installer reads the credential from `/dev/tty`; if no TTY is available it exits with a
clear error rather than consuming piped installer input.

For a bare operator install, skip the wizard and use [Helm](helm.md) or
[Docker Compose](docker-compose.md).
