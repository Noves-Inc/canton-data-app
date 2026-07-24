# Participant-admin-assisted setup

**Date:** 2026-07-24  
**Status:** Approved design  
**Repositories:** `canton-data-app`, `cda-frontend`, `cda-backend`

## Objective

The guided Helm and Docker Compose installers will use the validator's existing participant
administrator machine credential for one task: creating the Data App capture user with
`CanReadAsAnyParty`.

The setup process will keep the administrator credential in memory. It will not place that
credential in the browser, Data App database, capture Secret, setup result, chart values, Compose
files, logs, or final containers. The production Data App will use a new capture client with one
Canton right.

Operators can use the existing manual setup when discovery or automatic provisioning cannot meet
these rules. The enterprise Helm and Compose paths remain independent of the wizard.

## Supported installation paths

### Guided Helm

The installer expects a validator in the target namespace and uses these defaults:

- namespace: `validator`
- participant service: `participant:5001`
- validator administrator Secret: `splice-app-validator-ledger-api-auth`

The standard validator Secret contains:

- `ledger-api-user`
- `url`
- `client-id`
- `client-secret`
- `audience`
- optional `scope`

The installer accepts a non-default administrator Secret name. A Secret with different key names
uses the manual path. The chart does not grant the setup service account access to this Secret.

### Guided Docker Compose

The installer searches the configured Canton Docker network for a running container with the
Compose label `com.docker.compose.service=validator`. It accepts one match. If it finds more than
one, the operator must pass `--validator-container NAME`.

The installer reads these rendered validator environment values:

- `SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_URL`
- `SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_CLIENT_ID`
- `SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_CLIENT_SECRET`
- `SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_AUDIENCE`
- `SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_SCOPE`
- `SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_USER_NAME`

The Data App containers do not receive the Docker socket. The browser and setup service cannot run
Docker commands.

### Standard operator installation

`setupWizard.enabled=false` remains the chart default. Flux, Argo CD, Terraform, and direct Helm
users continue to create and reference their own capture Secret. The standard Compose path
continues to read operator-managed files. Neither path reads the validator administrator
credential.

## Components

### Installer discovery adapter

The host installer owns validator discovery.

For Helm, it reads the named Kubernetes Secret with the operator's current `kubectl` identity. For
Compose, it selects and inspects the running validator container. The installer filters the source
data before sending anything to the setup service.

The installer streams the filtered credential bundle through stdin and pipes. It does not put
credential values in command arguments or temporary files.

### Setup bootstrap endpoint

The setup service adds an installer-only endpoint:

`POST /internal/setup/admin-credential`

The installer authenticates with the setup bootstrap token through
`x-noves-setup-bootstrap`. The browser session token cannot authorize this endpoint. The endpoint
accepts:

- source mode, `helm` or `compose`
- OIDC discovery URL
- expected administrator user ID
- administrator client ID and secret
- Ledger API audience
- optional scope

The first valid request sets the in-memory credential. An identical retry succeeds. A request with
different credential material receives `409 Conflict`. Completed setup also receives `409
Conflict`.

The setup service clears the credential after two hours, on completion, or during process
shutdown. A restarted setup process starts without it. Rerunning the installer reloads the
persisted setup state and bootstraps the credential again.

### Safe discovery defaults

The setup service fetches the configured OIDC discovery document with the existing endpoint and
issuer validation. It returns only these safe defaults to the browser:

- detected provider
- Auth0 domain, or Keycloak base URL and realm
- Ledger API audience
- Ledger API scope
- whether administrator-assisted provisioning is available

The service recognizes Keycloak from its realm and protocol endpoints. It recognizes Auth0 from
its issuer and token endpoint. If the metadata does not identify either provider, the operator
chooses one and reviews the prefilled issuer information.

The service does not return the validator administrator client ID, client secret, access token, or
user ID. It does not reuse the validator client as the Data App browser or capture client.

### In-memory administrator credential holder

One setup-scoped component owns the credential. It supports:

- set once, with identical retry
- read for a token exchange
- clear
- sanitized status

The component does not support serialization. Setup state stores only the sanitized provider
defaults and completion data.

### Canton capture-user provisioner

The backend adds a setup-only endpoint:

`POST /internal/setup/provision-capture-user`

The setup bootstrap token protects this endpoint. The setup service sends a fresh administrator
access token in the `Authorization` header and sends the node ID, expected administrator user ID,
and capture user ID in the request body.

The production `NodeRegistry` performs every participant call. The implementation adds the
required canonical User Management Service messages and RPCs to the shared Canton client. It does
not create a second gRPC channel or a parallel participant client.

The backend performs these checks in order:

1. The participant accepts the administrator token.
2. The token subject matches the expected administrator user ID.
3. `ListUserRights` reports `ParticipantAdmin`.
4. The selected node matches the setup node.
5. The target capture user belongs to the administrator's identity-provider scope.

The endpoint is absent when setup mode is disabled.

## Automatic provisioning flow

1. The installer starts the temporary database, backend, and setup service.
2. The installer discovers the validator credential and bootstraps it into setup-service memory.
3. The wizard loads sanitized provider defaults.
4. The operator creates separate browser and capture clients in Auth0 or Keycloak.
5. The operator enters the new client details.
6. The setup service exchanges the capture credentials and records the exact token subject in
   memory.
7. The UI displays the target subject and `CanReadAsAnyParty`, then asks the operator to confirm the
   participant mutation.
8. The setup service exchanges the administrator credential for a fresh access token.
9. The backend validates the administrator and provisions the capture user.
10. The normal setup verification path uses the capture token to check subject, rights,
    participant identity, network, and database readiness.
11. The setup store writes the dedicated capture credential and non-secret deployment values.
12. The setup service clears the administrator credential.
13. The installer activates the standard application and removes the temporary setup resources.

The operator must confirm step 7. Discovery alone cannot mutate the participant.

## Capture-user state rules

The provisioner treats these states as follows:

| Existing state | Automatic action |
|---|---|
| User absent | Create the user with `CanReadAsAnyParty` in one `CreateUser` request |
| User active with no rights | Grant `CanReadAsAnyParty` |
| User active with only `CanReadAsAnyParty` | Return success without mutation |
| User has any other right | Refuse and require manual review |
| User deactivated | Refuse and require manual review |
| User belongs to an incompatible identity provider | Refuse and require manual review |

The allowed set contains one right. Party-specific read rights, participant or identity-provider
administration, act-as rights, and execute-as rights all cause refusal.

The provisioner does not revoke rights, reactivate users, move users between identity providers, or
delete users. If automatic creation succeeds and the operator abandons installation, the user
remains. A later run reuses it through the idempotent path.

## Auth0 and Keycloak assistance

The wizard uses the validator discovery URL to prefill the provider location. It also pre-fills the
Ledger API audience and scope for the new capture client.

The operator still creates:

- a Data App browser client with the final application callback and logout URLs
- a Data App capture client with client-credentials access to the Ledger API audience

The wizard shows the Auth0 or Keycloak guide for the detected provider. Each guide includes the
exact callback URL and provider fields from the form. The browser client ID remains an operator
input because the validator's wallet client has different callback URLs.

Changing a detected issuer, audience, or scope shows a warning. The operator can continue, but
automatic provisioning must still prove that both tokens work against the selected participant.

## Manual recovery

The wizard switches to manual mode for these conditions:

- missing or incomplete default validator credential
- no matching Compose validator, or ambiguous validator selection
- unsupported or disabled authentication
- OIDC discovery or administrator token exchange failure
- administrator subject mismatch
- missing `ParticipantAdmin`
- incompatible existing capture user
- participant rejection of the provisioning request

Manual mode keeps the entered capture settings and shows:

- the exact capture subject
- participant address and node
- the required `CanReadAsAnyParty` right
- Kubernetes port-forward or Compose-network instructions
- `grpcurl` commands for `CreateUser`, `GrantUserRights`, and `ListUserRights`
- a Recheck action

Canton exposes gRPC reflection on the Ledger API, so the commands do not require downloaded proto
files. Commands use `grpcurl -expand-headers` and the literal header
`authorization: Bearer ${PARTICIPANT_ADMIN_TOKEN}`. `grpcurl` expands the environment variable
after process startup, so the token value does not appear in the command arguments.

The Helm instructions connect through:

```bash
kubectl --namespace validator port-forward service/participant 5001:5001
```

The Compose instructions use the validator network and a release-pinned `grpcurl` 1.9.1 image.
The temporary container receives `PARTICIPANT_ADMIN_TOKEN` from the operator's environment and uses
`--rm`.

The wizard does not mark setup complete after displaying commands. The operator runs the commands
and selects Recheck. The production capture verification must pass before Save and activate becomes
available.

## Security boundaries

### Credential exposure

The installer and setup process must meet these rules:

- The browser cannot access the administrator credential or token.
- The setup service never returns credential material.
- Helm values and manifests contain no administrator credential values.
- Compose files and Data App container definitions contain no administrator credential values.
- The setup store, capture Secret, database, and setup result contain no administrator credential
  values.
- Application logs, HTTP error bodies, traces, analytics, and diagnostics redact credential
  material.
- The final Data App pods and containers have no administrator credential reference.

The Compose installer may read the existing validator container configuration because the operator
already granted it Docker access. It filters that output in a pipe. No Data App container receives
Docker access.

### Network and endpoint access

The Kubernetes setup service remains reachable through a direct localhost port-forward. It has no
Service and no public route. Its NetworkPolicy denies pod-to-pod ingress.

The browser uses the session token from the localhost URL fragment. The installer uses the
bootstrap token. Neither token can authorize the other's endpoint set.

The setup service sends only a short-lived administrator access token to the backend. The backend
accepts it on the setup-only endpoint, verifies it with the participant, and drops it after the
request. Request logging and diagnostics treat `Authorization` and setup headers as secrets.

### Least privilege

The automatic request builder can encode only `CanReadAsAnyParty`. Tests inspect the outgoing gRPC
message. The backend rejects a response that reports additional rights before setup completion.

The capture credential remains separate from the validator credential. The final backend reads
only the capture Secret.

## Persistence and resume

The setup store preserves non-secret form values and the dedicated capture credential through the
existing completion protocol. It does not persist administrator-assisted provisioning state.

A successful Canton mutation can precede setup completion. Repeated provisioning checks the
existing user and returns the same safe result. A setup restart requires the installer to
bootstrap the administrator credential again. A completed installation rejects all setup
mutations after restart.

Helm removes the setup Deployment, setup role, setup tokens, and result ConfigMap during final
activation. It retains the dedicated capture Secret.

Compose removes the temporary setup containers before starting the standard stack. It retains
`.state/capture.env` and the non-secret values required by the existing installer.

## Errors shown to operators

Operator messages identify the failed boundary without including tokens or secrets:

- validator credential not found
- validator credential incomplete
- identity provider unavailable
- validator administrator token rejected
- validator administrator lacks `ParticipantAdmin`
- capture subject conflicts with an existing Canton user
- participant unavailable
- capture user still lacks the required right

Transport failures offer Retry. Permission and user-state conflicts open manual recovery. The
installer exits with a nonzero status if the operator closes the wizard before completion or final
activation fails.

## Configuration surface

The change adds no production runtime environment variables.

Guided Helm adds:

- `--participant-admin-secret NAME`

Guided Compose adds:

- `--validator-container NAME`

The installer keeps the default Secret keys and Compose environment names as implementation
conventions. Operators with a different credential schema use standard installation or manual
recovery instead of a larger public mapping surface.

## Testing

### Shared Canton client and backend

Tests must drive the production composition root and `NodeRegistry`. A real gRPC fixture covers:

- administrator rights lookup
- authenticated user and identity-provider lookup
- user creation with the initial right
- existing user lookup
- granting the missing right
- final rights verification

Backend tests cover subject mismatch, absent administrator rights, extra capture rights,
deactivated users, incompatible identity providers, cancellation, retry, and disabled setup mode.
One test inspects the encoded create and grant requests and proves that they contain only
`CanReadAsAnyParty`.

### Setup service and frontend

Tests cover:

- separate bootstrap and browser authorization
- identical bootstrap retry and conflicting bootstrap rejection
- sanitized state responses
- credential clearing on completion, expiry, and shutdown
- Auth0 and Keycloak discovery defaults
- automatic provisioning confirmation
- retryable failures
- manual recovery rendering
- Recheck after manual provisioning
- secret redaction in logs and error bodies

### Installers and deployments

Installer tests use fake `kubectl` and Docker commands to cover:

- default Helm Secret discovery
- non-default Helm Secret selection
- one, zero, and multiple Compose validator matches
- explicit Compose container selection
- filtered pipe transport with no secret command arguments or files
- resume after setup restart
- manual-mode fallback

Helm tests confirm that the chart does not grant access to the validator administrator Secret and
does not retain administrator references after setup.

The release gate runs one Helm and one Compose production-path test:

`installer -> setup bootstrap -> administrator token exchange -> participant verification -> user
creation -> capture verification -> credential persistence -> final application readiness`

## Repository changes

### Shared Ledger API client

- Add the canonical User Management Service messages and RPCs required by provisioning.
- Add `CantonNodeClient` methods for authenticated-user lookup, user creation, user lookup, rights
  grant, and rights listing.
- Keep internal dependency identity private and release-pinned through the existing process.

### `cda-backend`

- Add the setup-only capture-user provisioner and endpoint.
- Reuse `NodeRegistry`, setup composition-root registration, cancellation, and secret redaction.
- Tighten capture verification to accept only `CanReadAsAnyParty`.

### `cda-frontend`

- Add the in-memory administrator credential holder and bootstrap endpoint.
- Add safe provider discovery defaults and automatic provisioning calls.
- Add the confirmation and manual recovery UI.

### `canton-data-app`

- Add Helm and Compose discovery to the host installers.
- Keep validator credential values out of chart and Compose resources.
- Add operator documentation, recovery commands, chart tests, and installer tests.
- Update repository guidance with the setup credential boundary.

`cda-db` needs no change.

## Acceptance criteria

The feature is complete when:

1. A validator installed with the default Helm chart can run the Data App Helm one-liner, create
   the new Auth0 or Keycloak clients, confirm provisioning, and reach a ready Data App without
   running a Canton console command.
2. A validator running the default Compose bundle can complete the same flow.
3. The resulting capture user has one right: `CanReadAsAnyParty`.
4. The final Data App deployment contains no validator administrator credential or reference.
5. Automatic discovery failure produces usable manual commands and Recheck completes setup after
   the operator runs them.
6. The standard enterprise installation paths behave as they did before this feature.
7. Tests find no administrator credential in browser responses, persisted setup state, logs,
   manifests, Compose definitions, or final container environments.
