# Optional localhost setup wizard

The wizard is a launch aid, not a different deployment model. It collects the values that a
normal Helm or Compose installation needs, verifies them live, and activates the standard
three-container application.

## Assisted capture-user flow

For a validator installed with the standard conventions, the host installer finds its existing
participant-admin machine credential:

- Helm reads `splice-app-validator-ledger-api-auth` in the validator namespace.
- Compose finds one running container labelled
  `com.docker.compose.service=validator` and reads the documented validator authentication
  environment.

The installer filters the values and streams them directly to the localhost setup service. The
credential is held in memory only for up to two hours. It is never mounted into the wizard,
sent to the browser, written to a file or Kubernetes resource, stored in the database, or
included in the final deployment. The temporary administrator token is also server-side only.

The wizard uses the validator OIDC URL, audience, and scope to pre-fill safe suggestions. It does
not create Auth0 applications or Keycloak clients. Create a separate browser client and a
separate capture client using the linked provider guide, then enter the capture credentials.
Choose Kubernetes Ingress or Istio for the public route. Ingress also needs its class name and
can reference a TLS Secret in the Data App namespace. Istio needs the Gateway name, including
its namespace when the Gateway is elsewhere. Routing annotations are entered as a JSON object
with string values.
Before any participant mutation, the wizard shows the exact capture token subject and the one
right it will grant. You must explicitly confirm `CanReadAsAnyParty`.

Automatic setup then authenticates the administrator, confirms `ParticipantAdmin`, and creates
the capture user with exactly `CanReadAsAnyParty`. An existing active user with no rights receives
that one right; an exact existing user is unchanged. A deactivated user, identity-provider
mismatch, or any additional right is refused without broadening access. The capture credential
must pass the normal live token and rights verification before it is saved or activated.

If discovery or automatic provisioning does not work, installation continues in manual mode.
The wizard renders copyable commands for create, grant, and rights verification. It uses the
literal shell variable below and never prints an administrator access token:

```bash
read -rsp 'Participant admin access token: ' PARTICIPANT_ADMIN_TOKEN
export PARTICIPANT_ADMIN_TOKEN
printf '\n'
grpcurl -plaintext -expand-headers \
  -H 'authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}' \
  -d '{"userId":"exact-capture-token-subject"}' \
  localhost:5001 \
  com.daml.ledger.api.v2.admin.UserManagementService/ListUserRights
```

After running the generated commands, choose **Recheck**. Setup still requires the capture user
to have exactly `CanReadAsAnyParty`.

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

If you need to reopen the local page while the wizard is running, forward its Deployment port:

```bash
kubectl --namespace <data-app-namespace> \
  port-forward deployment/<release>-setup-wizard 8099:3000
```

The wizard service account can only `get`, `update`, or `patch` the first two resources by exact
name. It cannot list Secrets, access Canton Secrets, patch Deployments, or perform cluster
administration. Public routing is rejected while the wizard is enabled; access is through a
localhost port-forward only.

Pass `--values FILE` to the guided Helm installer when the cluster needs operator settings such
as `imagePullSecrets`, StorageClasses, resource limits, or scheduling rules. The installer applies
that file to both the temporary setup release and the activated release. Wizard results override
only the values the wizard owns, including OIDC, Canton addresses, and routing.

The validator administrator Secret is read by the host-side installer with the operator's
existing Kubernetes access. It is never granted to the setup service account.

After completion, the installer upgrades the release with `setupWizard.enabled=false`. Helm
removes the wizard Deployment, service account, Role, RoleBinding, and result
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
the wizard does not delete database storage. If capture-user provisioning already succeeded, the
dedicated user and its `CanReadAsAnyParty` right remain for a later retry.

For automation, set `NOVES_GATEWAY_AUTH_TOKEN` or
`NOVES_GATEWAY_AUTH_TOKEN_FILE`. Direct values take precedence over file values. An explicitly
selected missing, unreadable, or blank file fails immediately. Without either variable, the
guided installer reads the credential from `/dev/tty`; if no TTY is available it exits with a
clear error rather than consuming piped installer input.

For a bare operator install, skip the wizard and use [Helm](helm.md) or
[Docker Compose](docker-compose.md).
