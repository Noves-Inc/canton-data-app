# Optional localhost setup wizard

The wizard is a launch aid, not a different deployment model. It collects the values that a
normal Helm or Compose installation needs, verifies them live, and activates the standard
three-container application.

## What it verifies

- OIDC discovery and a client-credentials token exchange
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

The wizard service account can only `get`, `update`, or `patch` the first two resources by exact
name. It cannot list Secrets, access Canton Secrets, patch Deployments, or perform cluster
administration. Public routing is rejected while the wizard is enabled; access is through a
localhost port-forward only.

After completion, the installer upgrades the release with `setupWizard.enabled=false`. Helm
removes the wizard Deployment, Service, service account, Role, RoleBinding, and result
ConfigMap. The capture Secret remains.

## Compose safety boundary

The Compose wizard binds only to `127.0.0.1:8099`, has no Docker socket, and writes:

- non-secret deployment values to `.state/values.json`;
- capture credentials to `.state/capture.env` with mode `0600`.

The installer turns off the setup stack before starting the normal application.

## Resume or stop

Re-run the same installer if the terminal closes. Existing generated state is reused. Stopping
the wizard does not modify participant rights and does not delete database storage.

For a bare operator install, skip the wizard and use [Helm](helm.md) or
[Docker Compose](docker-compose.md).
