# Data App v4 Release and Installation Hardening

## Scope

This change closes seven review findings across `cda-backend`, `cda-frontend`,
`cda-db`, and the public `canton-data-app` v4 branch. It covers deployment
credentials, release immutability, chart constraints, guided setup security,
route generation, customer-facing help, cancellation, and production-path
tests.

The Auth0 and Keycloak screenshot files remain outside this change. The public
guides keep their named screenshot slots and manifest so the release team can
add redacted images later. The setup UI must call them setup guides rather than
showing draft authoring labels to operators.

## Review Findings

All seven findings describe current defects or release risks:

1. Public deployments omit `NOVES_GATEWAY_AUTH_TOKEN` from the frontend and
   backend.
2. Backend and frontend tag workflows publish without their test suites. The
   backend also checks out a mutable classifier branch, and the frontend's
   manual publisher can move a semantic tag.
3. The chart accepts more than one backend replica even though one process owns
   database coordination and hosted workers.
4. The Helm installer copies an application URL port into `routing.host`.
5. Wizard help points to a nonexistent `main` branch and displays screenshot
   authoring language.
6. The setup server accepts requests from any in-cluster caller even though it
   can update fixed Kubernetes Secrets.
7. `SetupVerificationService` converts request cancellation into a failed
   participant check, and no HTTP test exercises the real endpoint, verification
   service, node registry adapter, and Canton client together.

The backend setup endpoint already checks `x-cda-setup-token`. Finding 6 applies
to the frontend setup server, which holds that backend token and exposes its own
unprotected API.

## Gateway Credential

Each installation uses a Noves-issued gateway credential. Operators must not
reuse the Canton capture identity for this purpose.

### Helm

The chart adds a required `novesGateway` block:

```yaml
novesGateway:
  existingSecret: noves-canton-data-app-gateway
  tokenKey: token
```

The backend and frontend read `NOVES_GATEWAY_AUTH_TOKEN` from the same fixed
Secret key. The setup release may start without the credential because it does
not activate billing-backed features. The final guided upgrade and every
standard install require the Secret reference.

The guided installer accepts `CDA_NOVES_GATEWAY_AUTH_TOKEN` for automation. If
the variable is absent, it reads the credential from the terminal without
echoing it. The installer creates or reuses the installation-specific Secret
before activating the release.

### Docker Compose

Compose mounts a dedicated secret file into both application containers:

```text
docker-compose/.secrets/noves-gateway-auth-token
```

The backend and frontend support `NOVES_GATEWAY_AUTH_TOKEN_FILE` and read the
credential at process startup. The guided installer writes the prompted value
with mode `0600`. Standard installs require operators to create the file.

The public docs explain how operators obtain, store, rotate, and verify this
credential without printing it.

## Release Inputs and Image Promotion

### Classifier pin

The backend repository records one full classifier commit SHA in
`.release/canton-classifier.ref`. The initial value is:

```text
ddfe8429ffd6727146a43812ae651fa3c3611217
```

That commit is the fetched head of `canton-classifier` `release` on
2026-07-23. Backend test and image jobs check out that exact SHA. The release
workflow fetches `origin/release` and refuses publication unless the locked SHA
is an ancestor of that branch. A moving branch name never becomes a compiler
input.

The normal backend `master` workflow uses the same lock by default. A manual
workflow may accept another full SHA only when the workflow confirms that SHA
belongs to `origin/release`.

### Tag workflows

Backend, frontend, and database tag workflows follow the same sequence:

1. Validate the `v4.x.y` Git tag and derive the plain semantic version.
2. Authenticate to GHCR and refuse the release if the semantic image tag
   exists.
3. Run the repository's release test and build gates.
4. Build one multi-platform candidate at `sha-<full-git-sha>`.
5. Resolve and record the candidate manifest digest.
6. Promote that digest to the semantic tag and the major-specific `latest`
   tag with `docker buildx imagetools create`.

The workflows never rebuild between candidate publication and promotion.
`latest` remains movable within the v4 image repository. Plain semantic tags
remain immutable.

The frontend manual publisher refuses existing semantic image and Git tags. It
may promote an existing semantic digest to `latest`, but it must not force-push
or move the semantic Git tag.

### Chart publication

The public chart workflow waits for its deployment tests, then resolves the
backend, frontend, and database semantic image tags. It fails if any tag is
missing. It writes `dist/release-manifest.json` with:

- chart version and Git SHA;
- each image repository, semantic tag, and manifest digest;
- the classifier SHA recorded on the backend image.

The workflow uploads the manifest as a build artifact before it pushes the
chart. It refuses an existing chart version. The backend image carries the
classifier SHA as an OCI index annotation so the chart workflow can compare it
with the release manifest.

## Backend Replica Constraint

The values schema gives the backend its own workload definition with
`replicaCount` fixed at `1`. Template validation also rejects any other value,
which protects operators who bypass JSON-schema validation. Chart tests render
`backend.replicaCount=2` and require Helm to fail with a direct explanation.

## Route Host Generation

The setup server validates `appUrl` with the platform URL parser and persists
`routingHost` from `URL.hostname`. The Helm installer consumes that field
instead of parsing the origin with shell string removal.

For `https://data.example.com:8443`, the saved values contain:

```json
{
  "appUrl": "https://data.example.com:8443",
  "routingHost": "data.example.com"
}
```

The callback retains the port. The Ingress or VirtualService host does not.
The chart schema and template validation accept DNS hostnames and reject a host
that contains a scheme, path, or port.

## Setup Session Security

The backend setup token remains an internal credential shared by the setup
server and backend. A second random credential protects the browser-facing
setup API.

The installer creates `CDA_SETUP_SESSION_TOKEN`, reads the same value from an
existing guided installation, and opens:

```text
http://127.0.0.1:8099/#session=<token>
```

The browser moves the fragment value into `sessionStorage`, removes it from the
visible URL, and sends it in `x-cda-setup-session` for `/api/setup/state`,
`/api/setup/verify`, and `/api/setup/complete`. The setup server compares the
value in constant time. It invalidates the session after a successful complete
request. Health checks use `/health` and require no credential.

The Helm chart removes the setup wizard Service. The installer runs:

```text
kubectl port-forward deployment/<release>-setup-wizard 8099:3000
```

A namespaced NetworkPolicy denies pod-network ingress to the setup wizard. The
API server's direct port-forward path remains the supported access path. The
chart still grants the setup service account access to the two fixed objects
needed for completion: the capture Secret and setup-result ConfigMap.

Compose keeps its loopback-only port binding and uses the same browser session
token.

## Wizard Help

The wizard links to the public `v4` branch:

```text
https://github.com/Noves-Inc/canton-data-app/blob/v4/...
```

The UI labels the links `Open Auth0 setup guide` and `Open Keycloak setup
guide`. Public authentication guides retain the screenshot-slot headings and
manifest for later image insertion.

## Cancellation and Production-Path Test

`SetupVerificationService` rethrows `OperationCanceledException` when the
request token has been canceled. It continues to translate participant
connection failures into a failed setup check.

The HTTP setup test uses the production registrations for:

```text
MapSetupEndpoints
  -> SetupVerificationService
  -> NodeRegistrySetupCantonProbe
  -> NodeRegistry
  -> CantonNodeClient
```

A loopback HTTP/2 fixture implements the three Ledger API calls used by the
probe and returns protobuf responses for user rights, participant identity, and
connected synchronizers. The test sends an authorized HTTP request and asserts
the final JSON checks. A separate test cancels a request during the participant
probe and asserts that cancellation reaches the caller.

The focused tests run before the complete backend suite. CI runs backend tests
with .NET 10 because the local workstation currently has .NET 9.

## Verification

The implementation must pass:

- backend focused setup, configuration, and workflow-contract tests;
- the complete backend test project in a .NET 10 environment;
- frontend setup-server and setup-wizard tests, then the full frontend test,
  build, and lint commands;
- public Helm, Compose, installer, workflow, and documentation tests;
- the database image build and smoke test;
- YAML parsing and `git diff --check` in every changed repository.

No workflow in this change pushes an image, chart, Git tag, or branch during
local verification.
