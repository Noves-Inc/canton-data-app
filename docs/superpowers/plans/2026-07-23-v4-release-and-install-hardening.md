# Data App v4 Release and Installation Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the seven approved release and installation findings without changing the v4 product boundary or exposing customer secrets.

**Architecture:** The public deployment supplies one installation-specific Noves gateway Secret to both application processes, while the Canton capture identity remains separate. Release workflows pin the classifier, gate publication on tests, build one SHA candidate, and promote its digest to immutable semantic tags. The localhost wizard gains a durable operator session boundary, and backend tests drive the production setup registration path through a real node registry client.

**Tech Stack:** .NET 10, ASP.NET Core, xUnit, Node.js 20, React, Express, Vitest, Docker Buildx, Helm 3, Kubernetes RBAC and NetworkPolicy, Bash, GitHub Actions.

## Global Constraints

- Backend, frontend, and database changes finish on local `master`; public deployment changes finish on local `v4`.
- Public image repositories remain `noves-canton-backend-v4`, `noves-canton-frontend-v4`, and `noves-canton-database-v4`.
- Plain semantic tags remain immutable. `latest` may move only inside a v4 image repository.
- Backend builds pin classifier SHA `ddfe8429ffd6727146a43812ae651fa3c3611217` and prove that it belongs to `origin/release`.
- The backend chart replica count equals `1`.
- Standard operators may skip the wizard and provide existing Secrets and values.
- Guided prompts read from `/dev/tty`; `curl | bash` stdin remains untouched.
- Direct credential variables take precedence over `_FILE` variables. Explicit missing, unreadable, or blank files fail.
- Helm stores the browser session in the setup-token Secret key `session-token`.
- Compose stores `CDA_SETUP_SESSION_TOKEN` in its mode-`0600` `.env`.
- Completed setup state blocks later mutation across process and pod restarts.
- Customer-facing material must not expose internal migration implementation details.
- Screenshot assets remain pending; customer-visible UI links call them setup guides.
- Local verification must not push images, charts, tags, or branches.

---

### Task 1: Create isolated worktrees and confirm the baseline

**Files:**
- Inspect: each repository's `.gitignore`, package manifest, workflow directory, and status
- Create backend, frontend, and database worktrees under: `/Users/j/crypto/noves/cda-backend/.worktrees/v4-release-install-hardening/`
- Reuse public linked worktree: `/private/tmp/canton-data-app-v4`

**Interfaces:**
- Consumes: local `master` for backend, frontend, and database; local `v4` for public deployment
- Produces: clean branch `feature/v4-release-install-hardening` in each repository

- [ ] **Step 1: Verify worktree isolation and ignore rules**

Run in each repository:

```bash
git rev-parse --git-dir
git rev-parse --git-common-dir
git status --short
git check-ignore -q .worktrees
```

Expected: the existing user files remain untouched and `.worktrees` is ignored.

- [ ] **Step 2: Create four linked worktrees**

```bash
git -C /Users/j/crypto/noves/cda-backend worktree add \
  /Users/j/crypto/noves/cda-backend/.worktrees/v4-release-install-hardening/backend \
  -b feature/v4-release-install-hardening master
git -C /Users/j/crypto/noves/cda-frontend worktree add \
  /Users/j/crypto/noves/cda-backend/.worktrees/v4-release-install-hardening/frontend \
  -b feature/v4-release-install-hardening master
git -C /Users/j/crypto/noves/cda-db worktree add \
  /Users/j/crypto/noves/cda-backend/.worktrees/v4-release-install-hardening/database \
  -b feature/v4-release-install-hardening master
git -C /private/tmp/canton-data-app-v4 switch \
  -c feature/v4-release-install-hardening
```

Expected: each worktree reports the feature branch and a clean status.

- [ ] **Step 3: Run baseline tests**

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj
pnpm exec vitest run --reporter=dot
tests/all.sh
docker build -t cda-db:v4-hardening-baseline .
scripts/smoke-test.sh cda-db:v4-hardening-baseline
```

Expected: backend may require a Docker-based .NET 10 test runner on this workstation; the other suites pass.

---

### Task 2: Add runtime gateway-secret file support

**Files:**
- Modify: `cda-backend/CantonDataApp/Configuration/DataAppOptions.cs`
- Create: `cda-backend/CantonDataApp.Tests/DataAppOptionsTests.cs`
- Create: `cda-frontend/server/lib/secret-env.js`
- Modify: `cda-frontend/server.js`
- Test: `cda-frontend/tests/integration/secret-env.test.ts`

**Interfaces:**
- Consumes: `NOVES_GATEWAY_AUTH_TOKEN` and `NOVES_GATEWAY_AUTH_TOKEN_FILE`
- Produces: `ReadSecretEnvironment(env, directName, fileName)` in .NET and `readSecretEnvironment(...)` in Node

- [ ] **Step 1: Write failing backend precedence and file-validation tests**

Add tests equivalent to:

```csharp
[Fact]
public void Direct_gateway_token_wins_over_file()
{
    using var env = new TemporaryEnvironment(
        ("NOVES_GATEWAY_AUTH_TOKEN", "direct-token"),
        ("NOVES_GATEWAY_AUTH_TOKEN_FILE", MissingPath()));
    Assert.Equal("direct-token", DataAppOptions.FromConfiguration(Config()).NovesGatewayAuthToken);
}

[Theory]
[InlineData("missing")]
[InlineData("blank")]
public void Explicit_gateway_token_file_must_be_readable_and_non_blank(string condition)
{
    using var env = GatewayFileEnvironment(condition);
    Assert.Throws<InvalidOperationException>(
        () => DataAppOptions.FromConfiguration(Config()));
}
```

- [ ] **Step 2: Run the backend tests and confirm RED**

Run:

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj --filter FullyQualifiedName~DataAppOptionsTests
```

Expected: the file-source tests fail because `DataAppOptions` ignores `_FILE`.

- [ ] **Step 3: Implement the backend reader**

Add one helper and route the gateway token through it:

```csharp
private static string? SecretEnvironment(string directName, string fileName)
{
    var direct = Environment.GetEnvironmentVariable(directName);
    if (!string.IsNullOrWhiteSpace(direct))
        return direct;

    var path = Environment.GetEnvironmentVariable(fileName);
    if (string.IsNullOrWhiteSpace(path))
        return null;
    if (!File.Exists(path))
        throw new InvalidOperationException($"{fileName} points to a missing file.");

    string value;
    try
    {
        value = File.ReadAllText(path).Trim();
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
    {
        throw new InvalidOperationException($"{fileName} could not be read.", exception);
    }
    if (string.IsNullOrWhiteSpace(value))
        throw new InvalidOperationException($"{fileName} points to a blank file.");
    return value;
}
```

Use:

```csharp
NovesGatewayAuthToken = SecretEnvironment(
    "NOVES_GATEWAY_AUTH_TOKEN",
    "NOVES_GATEWAY_AUTH_TOKEN_FILE"),
```

- [ ] **Step 4: Write failing frontend secret-reader tests**

Create tests for direct precedence, valid file content, missing file, and blank file:

```ts
expect(readSecretEnvironment({
  env: {
    NOVES_GATEWAY_AUTH_TOKEN: 'direct',
    NOVES_GATEWAY_AUTH_TOKEN_FILE: '/missing',
  },
})).toBe('direct')
```

- [ ] **Step 5: Run the frontend test and confirm RED**

Run:

```bash
pnpm exec vitest run tests/integration/secret-env.test.ts
```

Expected: import fails because `server/lib/secret-env.js` does not exist.

- [ ] **Step 6: Implement and wire the frontend reader**

Create:

```js
import fs from 'node:fs'

export function readSecretEnvironment({
  env = process.env,
  directName = 'NOVES_GATEWAY_AUTH_TOKEN',
  fileName = 'NOVES_GATEWAY_AUTH_TOKEN_FILE',
} = {}) {
  const direct = env[directName]
  if (direct && direct.trim()) return direct
  const path = env[fileName]
  if (!path) return ''
  let value
  try {
    value = fs.readFileSync(path, 'utf8').trim()
  } catch (error) {
    throw new Error(`${fileName} could not be read: ${error.message}`)
  }
  if (!value) throw new Error(`${fileName} points to a blank file.`)
  return value
}
```

Replace the direct environment read in `server.js` with this function.

- [ ] **Step 7: Run focused tests and commit**

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj --filter FullyQualifiedName~DataAppOptionsTests
pnpm exec vitest run tests/integration/secret-env.test.ts
git add CantonDataApp/Configuration/DataAppOptions.cs \
  CantonDataApp.Tests/DataAppOptionsTests.cs
git add server/lib/secret-env.js server.js \
  tests/integration/secret-env.test.ts
git commit -m "feat: load gateway credentials from secret files"
```

Expected: focused tests pass.

---

### Task 3: Harden the setup server and wizard

**Files:**
- Modify: `cda-frontend/server/setup/app.js`
- Modify: `cda-frontend/server/setup/main.js`
- Modify: `cda-frontend/server/setup/file-store.js`
- Modify: `cda-frontend/server/setup/kubernetes-store.js`
- Modify: `cda-frontend/server/setup/config.js`
- Modify: `cda-frontend/src/setup/api.ts`
- Modify: `cda-frontend/src/setup/SetupWizard.tsx`
- Test: `cda-frontend/tests/integration/setup-server.test.ts`
- Test: `cda-frontend/tests/integration/setup-wizard.test.tsx`

**Interfaces:**
- Consumes: `CDA_SETUP_SESSION_TOKEN`, the `session` URL fragment, and persisted `completed`
- Produces: `x-cda-setup-session` authentication, durable HTTP 409 mutation rejection, and `routingHost`

- [ ] **Step 1: Write failing server authentication and durability tests**

Add a test helper that listens on loopback with `app.listen(0, "127.0.0.1")`,
calls the app with `fetch`, and closes the server after each case. Create
`createSetupApp` with `sessionToken: "browser-secret"` and assert:

```ts
expect((await fetch(`${origin}/api/setup/state`)).status).toBe(401)
expect((await fetch(`${origin}/api/setup/state`, {
  headers: { 'x-cda-setup-session': 'browser-secret' },
})).status).toBe(200)
expect((await completedAppRequest('/api/setup/verify')).status).toBe(409)
expect((await completedAppRequest('/api/setup/complete')).status).toBe(409)
```

Create a new app instance over the same completed store before the second 409 assertion.

- [ ] **Step 2: Write failing persistence tests**

For `FileSetupStore` and `KubernetesSetupStore`, save completed state once and assert that a second save rejects before any capture Secret update.

- [ ] **Step 3: Write failing route-host tests**

Assert:

```ts
expect(publicConfig({
  provider: 'auth0',
  appUrl: 'https://data.example.com:8443',
}, 'https://issuer.example/token')).toMatchObject({
  appUrl: 'https://data.example.com:8443',
  routingHost: 'data.example.com',
})
```

- [ ] **Step 4: Run focused server tests and confirm RED**

```bash
pnpm exec vitest run tests/integration/setup-server.test.ts
```

Expected: unauthenticated state returns 200, completed stores allow a second mutation, and `routingHost` is absent.

- [ ] **Step 5: Implement session authentication and durable completion**

In `createSetupApp`, require `sessionToken`, hash the expected and presented values with SHA-256, and compare with `timingSafeEqual`. Apply the middleware only to `/api/setup/*`.

Before `/verify` or `/complete` calls `verifyInput`, load the store:

```js
const state = await store.load()
if (state.completed) {
  return res.status(409).json({
    error: 'Setup already completed',
    detail: 'Completed setup cannot be modified. Start a new guided installation to change it.',
  })
}
```

Both store implementations must reject `save` when their current persisted state has `completed: true`.

- [ ] **Step 6: Implement browser session handling**

In `src/setup/api.ts`, read `session` from the URL fragment once, store it under
`cda.setup.session`, remove the fragment with `history.replaceState`, and attach:

```ts
'x-cda-setup-session': sessionToken()
```

to every setup API request.

- [ ] **Step 7: Persist the parsed route hostname**

In `publicConfig`, parse the application URL once:

```js
const appUrl = new URL(String(input.appUrl))
return {
  ...publicFields,
  appUrl: appUrl.origin,
  routingHost: appUrl.hostname,
}
```

Keep the non-default port in `appUrl`.

- [ ] **Step 8: Fix public wizard links and wording**

Use `blob/v4` links and render:

```tsx
Open {provider} setup guide <ExternalLink size={14} />
```

Update tests to reject `blob/main` and `screenshot slot`.

- [ ] **Step 9: Run focused tests and commit**

```bash
pnpm exec vitest run tests/integration/setup-server.test.ts tests/integration/setup-wizard.test.tsx
git add server/setup/app.js server/setup/main.js \
  server/setup/file-store.js server/setup/kubernetes-store.js \
  server/setup/config.js src/setup/api.ts src/setup/SetupWizard.tsx \
  tests/integration/setup-server.test.ts \
  tests/integration/setup-wizard.test.tsx
git commit -m "fix: protect and finalize guided setup"
```

Expected: focused tests pass.

---

### Task 4: Propagate cancellation and test the production setup path

**Files:**
- Create: `cda-backend/CantonDataApp/Setup/SetupServiceCollectionExtensions.cs`
- Modify: `cda-backend/CantonDataApp/Program.cs`
- Modify: `cda-backend/CantonDataApp/Setup/SetupVerificationService.cs`
- Create: `cda-backend/CantonDataApp.Tests/Setup/LedgerApiSetupFixture.cs`
- Modify: `cda-backend/CantonDataApp.Tests/Setup/SetupEndpointsHttpTests.cs`
- Modify: `cda-backend/CantonDataApp.Tests/Setup/SetupVerificationServiceTests.cs`

**Interfaces:**
- Consumes: `IServiceCollection`, setup-enabled flag, real `NodeRegistry`, and request cancellation
- Produces: `AddSetupWizardServices(bool enabled)` and a wired HTTP test

- [ ] **Step 1: Write a failing cancellation test**

Use a probe that waits on the supplied token:

```csharp
await Assert.ThrowsAnyAsync<OperationCanceledException>(
    () => service.VerifyAsync(Request(), canceledToken));
```

- [ ] **Step 2: Run the cancellation test and confirm RED**

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj \
  --filter FullyQualifiedName~SetupVerificationServiceTests.Cancellation
```

Expected: the service returns a failed participant check instead of throwing.

- [ ] **Step 3: Propagate cancellation**

Change the participant catch block to:

```csharp
catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
{
    throw;
}
catch
{
    checks.Add(ParticipantConnectionFailure());
}
```

- [ ] **Step 4: Write the failing composition-root contract test**

Call:

```csharp
builder.Services.AddSetupWizardServices(enabled: true);
```

and assert that the resolved implementation types are
`NodeRegistrySetupCantonProbe` and `SetupVerificationService`. Do not register
either setup interface in the test.

- [ ] **Step 5: Extract and wire the production registration**

Implement:

```csharp
public static IServiceCollection AddSetupWizardServices(
    this IServiceCollection services,
    bool enabled)
{
    if (!enabled) return services;
    services.AddSingleton<ISetupCantonProbe, NodeRegistrySetupCantonProbe>();
    services.AddSingleton<ISetupVerificationService, SetupVerificationService>();
    return services;
}
```

Replace the corresponding `Program.cs` block with:

```csharp
builder.Services.AddSetupWizardServices(options.SetupWizardEnabled);
```

- [ ] **Step 6: Add a loopback Ledger API fixture**

Start Kestrel on loopback with HTTP/2 and map the exact unary gRPC paths for:

```text
com.daml.ledger.api.v2.admin.UserManagementService/ListUserRights
com.daml.ledger.api.v2.admin.PartyManagementService/GetParticipantId
com.daml.ledger.api.v2.StateService/GetConnectedSynchronizers
```

The fixture must read and write the five-byte gRPC frame header and serialize the existing generated response messages. It returns `CanReadAsAnyParty`, `participant::expected`, and the mainnet synchronizer.

- [ ] **Step 7: Drive the real endpoint path**

Build the HTTP app with a real `NodeRegistry`, ready `StartupState`,
`AddSetupWizardServices(true)`, and `MapSetupEndpoints`. Post an authorized
request and assert the camel-case response reports success.

- [ ] **Step 8: Run focused tests and commit**

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj \
  --filter FullyQualifiedName~Setup
git add CantonDataApp/Setup/SetupServiceCollectionExtensions.cs \
  CantonDataApp/Program.cs \
  CantonDataApp/Setup/SetupVerificationService.cs \
  CantonDataApp.Tests/Setup/LedgerApiSetupFixture.cs \
  CantonDataApp.Tests/Setup/SetupEndpointsHttpTests.cs \
  CantonDataApp.Tests/Setup/SetupVerificationServiceTests.cs
git commit -m "test: drive production setup verification path"
```

Expected: setup tests pass on .NET 10.

---

### Task 5: Pin the classifier and make backend releases immutable

**Files:**
- Create: `cda-backend/.release/canton-classifier.ref`
- Modify: `cda-backend/.github/workflows/build-and-publish.yaml`
- Modify: `cda-backend/.github/workflows/publish-v4.yaml`
- Create: `cda-backend/CantonDataApp.Tests/ReleaseWorkflowContractTests.cs`

**Interfaces:**
- Consumes: full classifier SHA from `.release/canton-classifier.ref`
- Produces: tested `sha-<backend-sha>` candidate and digest promotion to semver and `latest`

- [ ] **Step 1: Write failing workflow contract tests**

Read the workflow text and assert:

```csharp
Assert.DoesNotContain("ref: master", workflow);
Assert.Contains(".release/canton-classifier.ref", workflow);
Assert.Contains("merge-base --is-ancestor", workflow);
Assert.Contains("needs: test", workflow);
Assert.Contains("imagetools create", workflow);
Assert.Contains("already exists", workflow);
```

Also assert the lock contains one 40-character lowercase hexadecimal SHA.

- [ ] **Step 2: Run the contract tests and confirm RED**

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj \
  --filter FullyQualifiedName~ReleaseWorkflowContractTests
```

Expected: both workflows still mention `master` and the public workflow has no test dependency.

- [ ] **Step 3: Add the classifier lock**

Write exactly:

```text
ddfe8429ffd6727146a43812ae651fa3c3611217
```

- [ ] **Step 4: Update normal backend CI**

Both test and build jobs read the lock and check out the exact SHA. A manual
override must match `^[0-9a-f]{40}$`. Fetch `origin/release` and run:

```bash
git merge-base --is-ancestor "$CLASSIFIER_REF" origin/release
```

before tests or builds.

- [ ] **Step 5: Replace the public tag workflow**

The release workflow must:

```yaml
jobs:
  test:
    # checkout locked classifier, validate release ancestry, run full .NET tests
  publish:
    needs: test
```

After GHCR login, reject an existing semantic tag:

```bash
if docker buildx imagetools inspect "$IMAGE:$CDA_VERSION" >/dev/null 2>&1; then
  echo "Refusing to replace existing semantic image tag $IMAGE:$CDA_VERSION" >&2
  exit 1
fi
```

Build only `"$IMAGE:sha-$GITHUB_SHA"` and capture the build action digest. Add
the classifier SHA as an OCI index annotation. Promote:

```bash
docker buildx imagetools create \
  --tag "$IMAGE:$CDA_VERSION" \
  --tag "$IMAGE:latest" \
  "$IMAGE@$CANDIDATE_DIGEST"
```

- [ ] **Step 6: Run workflow contract tests and commit**

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj \
  --filter FullyQualifiedName~ReleaseWorkflowContractTests
git add .release/canton-classifier.ref .github/workflows/*.yaml \
  CantonDataApp.Tests/ReleaseWorkflowContractTests.cs
git commit -m "ci: pin and gate public backend releases"
```

Expected: workflow contract tests pass.

---

### Task 6: Make frontend releases immutable

**Files:**
- Modify: `cda-frontend/.github/workflows/publish-v4.yml`
- Modify: `cda-frontend/scripts/publish_images.sh`
- Create: `cda-frontend/tests/integration/release-workflow.test.ts`

**Interfaces:**
- Consumes: v4 Git tag and tested frontend source
- Produces: one SHA candidate digest promoted to immutable semver and `latest`

- [ ] **Step 1: Write failing workflow and publisher tests**

Assert the workflow contains quality gates, a `needs` dependency, candidate SHA
tag, existing-semver rejection, and digest promotion. Assert the script contains
no `git tag -f` or `git push --force`.

- [ ] **Step 2: Run the test and confirm RED**

```bash
pnpm exec vitest run tests/integration/release-workflow.test.ts
```

Expected: the workflow has one publish-only job and the script force-moves tags.

- [ ] **Step 3: Add the release quality job**

The tag workflow checks out source, installs with the lockfile, and runs:

```bash
pnpm lint
pnpm exec vitest run
pnpm build
```

The publish job declares `needs: quality`.

- [ ] **Step 4: Build and promote one candidate digest**

Reject existing `IMAGE:CDA_VERSION`, build `IMAGE:sha-$GITHUB_SHA`, capture its
digest, and use `imagetools create` for semver and `latest`.

- [ ] **Step 5: Remove force-moving behavior from the manual publisher**

The build path rejects an existing remote semantic image tag before `buildx`.
The Git tag path exits with an error if the tag exists at another commit. The
`--promote` path remains allowed because it moves only `latest`.

- [ ] **Step 6: Run focused tests and commit**

```bash
pnpm exec vitest run tests/integration/release-workflow.test.ts
bash -n scripts/publish_images.sh
git add .github/workflows/publish-v4.yml scripts/publish_images.sh \
  tests/integration/release-workflow.test.ts
git commit -m "ci: test and promote frontend release digests"
```

Expected: tests and shell syntax pass.

---

### Task 7: Make database releases promote the tested candidate

**Files:**
- Modify: `cda-db/.github/workflows/build-and-publish.yml`
- Create: `cda-db/scripts/test-release-workflow.sh`

**Interfaces:**
- Consumes: v4 Git tag and existing database smoke test
- Produces: smoke-tested SHA candidate promoted to semver and `latest`

- [ ] **Step 1: Write a failing shell contract test**

Require the workflow to contain:

```text
sha-${GITHUB_SHA}
imagetools inspect
scripts/smoke-test.sh
imagetools create
Refusing to replace existing semantic image tag
```

- [ ] **Step 2: Run the contract test and confirm RED**

```bash
scripts/test-release-workflow.sh
```

Expected: candidate promotion strings are absent.

- [ ] **Step 3: Split branch and tag publication behavior**

Keep the existing branch SHA publication. For a v4 tag, reject existing semver,
build and push the SHA candidate, pull the candidate digest on the runner, run:

```bash
scripts/smoke-test.sh "$IMAGE@$CANDIDATE_DIGEST"
```

and promote that digest to semver and `latest`.

- [ ] **Step 4: Run checks and commit**

```bash
scripts/test-release-workflow.sh
docker build -t cda-db:v4-hardening .
scripts/smoke-test.sh cda-db:v4-hardening
git add .github/workflows/build-and-publish.yml scripts/test-release-workflow.sh
git commit -m "ci: promote smoke-tested database digests"
```

Expected: workflow contract and database smoke tests pass.

---

### Task 8: Add public chart and Compose credential contracts

**Files:**
- Modify: `canton-data-app/chart/noves-canton-data-app/values.yaml`
- Modify: `canton-data-app/chart/noves-canton-data-app/values.schema.json`
- Modify: `canton-data-app/chart/noves-canton-data-app/templates/_helpers.tpl`
- Modify: `canton-data-app/chart/noves-canton-data-app/templates/backend.yaml`
- Modify: `canton-data-app/chart/noves-canton-data-app/templates/frontend.yaml`
- Modify: `canton-data-app/chart/noves-canton-data-app/templates/setup-wizard.yaml`
- Modify: `canton-data-app/chart/noves-canton-data-app/examples/enterprise-values.yaml`
- Modify: `canton-data-app/docker-compose/compose.yaml`
- Modify: `canton-data-app/docker-compose/compose.setup.yaml`
- Modify: `canton-data-app/docker-compose/.env.example`
- Modify: `canton-data-app/tests/helm-chart.sh`
- Modify: `canton-data-app/tests/docker-compose.sh`

**Interfaces:**
- Consumes: `novesGateway.existingSecret`, `novesGateway.tokenKey`, and Compose secret file
- Produces: gateway credentials in both application processes and a hard one-replica chart contract

- [ ] **Step 1: Add failing chart assertions**

Require enterprise output to contain two `NOVES_GATEWAY_AUTH_TOKEN` entries from
the configured Secret. Render `backend.replicaCount=2` and require failure:

```bash
if helm template cda "$chart" --values "$fixtures/enterprise-values.yaml" \
  --set backend.replicaCount=2 >"$scratch/replicas.out" 2>&1; then
  fail 'chart accepted more than one backend replica'
fi
```

- [ ] **Step 2: Add failing Compose assertions**

Require both backend and frontend to mount `noves-gateway-auth-token` and set:

```text
NOVES_GATEWAY_AUTH_TOKEN_FILE=/run/secrets/noves-gateway-auth-token
```

- [ ] **Step 3: Run deployment tests and confirm RED**

```bash
tests/helm-chart.sh
tests/docker-compose.sh
```

Expected: the gateway and replica assertions fail.

- [ ] **Step 4: Implement Helm values and validation**

Add:

```yaml
novesGateway:
  existingSecret: noves-canton-data-app-gateway
  tokenKey: token
```

Use a backend-specific schema with `replicaCount: { "const": 1 }`. Add template
validation that emits `backend.replicaCount must be 1`. Require the gateway
Secret when `setupWizard.enabled=false`.

- [ ] **Step 5: Inject the Helm Secret**

Add a `secretKeyRef` environment variable to backend and frontend. Keep the
reference absent from the setup-wizard container.

- [ ] **Step 6: Add the Compose Secret**

Define:

```yaml
secrets:
  noves-gateway-auth-token:
    file: ./.secrets/noves-gateway-auth-token
```

Mount it into backend and frontend and set `_FILE`. Add the standard file path
to `.env.example` comments without placing secret contents in `.env`.

- [ ] **Step 7: Run deployment tests and commit**

```bash
tests/helm-chart.sh
tests/docker-compose.sh
git add chart/noves-canton-data-app/values.yaml \
  chart/noves-canton-data-app/values.schema.json \
  chart/noves-canton-data-app/templates/_helpers.tpl \
  chart/noves-canton-data-app/templates/backend.yaml \
  chart/noves-canton-data-app/templates/frontend.yaml \
  chart/noves-canton-data-app/templates/setup-wizard.yaml \
  chart/noves-canton-data-app/examples/enterprise-values.yaml \
  docker-compose/compose.yaml docker-compose/compose.setup.yaml \
  docker-compose/.env.example tests/helm-chart.sh tests/docker-compose.sh
git commit -m "feat: wire installation gateway credentials"
```

Expected: focused deployment tests pass.

---

### Task 9: Secure guided installers and route generation

**Files:**
- Modify: `canton-data-app/scripts/lib/common.sh`
- Modify: `canton-data-app/scripts/install-helm.sh`
- Modify: `canton-data-app/scripts/install-compose.sh`
- Modify: `canton-data-app/docker-compose/compose.setup.yaml`
- Modify: `canton-data-app/docker-compose/.env.example`
- Modify: `canton-data-app/chart/noves-canton-data-app/values.yaml`
- Modify: `canton-data-app/chart/noves-canton-data-app/values.schema.json`
- Modify: `canton-data-app/chart/noves-canton-data-app/templates/setup-wizard.yaml`
- Modify: `canton-data-app/tests/installers.sh`
- Modify: `canton-data-app/tests/helm-chart.sh`

**Interfaces:**
- Consumes: gateway environment/file/TTY input, setup Secret keys, `.routingHost`
- Produces: localhost-only direct pod access and durable session-token storage

- [ ] **Step 1: Write failing installer source-precedence tests**

Run installers with fake tools and assert direct value wins over a missing file.
Assert an explicit missing or blank file fails. Run with stdin redirected and no
TTY or variables; require an error that names both automation variables.

- [ ] **Step 2: Write failing session and route tests**

Require Helm Secret creation to include `token` and `session-token`, the opened
URL to contain `#session=`, the port-forward target to be
`deployment/cda-setup-wizard`, and final values to use `.routingHost`.

- [ ] **Step 3: Run installer tests and confirm RED**

```bash
tests/installers.sh
```

Expected: current installers use stdin assumptions, one token, a Service, and shell URL parsing.

- [ ] **Step 4: Implement `/dev/tty` gateway input**

Add `resolve_noves_gateway_token`:

```bash
if [[ -n "${CDA_NOVES_GATEWAY_AUTH_TOKEN:-}" ]]; then
  token="$CDA_NOVES_GATEWAY_AUTH_TOKEN"
elif [[ -n "${CDA_NOVES_GATEWAY_AUTH_TOKEN_FILE:-}" ]]; then
  [[ -r "$CDA_NOVES_GATEWAY_AUTH_TOKEN_FILE" ]] ||
    die "CDA_NOVES_GATEWAY_AUTH_TOKEN_FILE is not readable."
  token="$(<"$CDA_NOVES_GATEWAY_AUTH_TOKEN_FILE")"
elif [[ -r /dev/tty && -w /dev/tty ]]; then
  IFS= read -r -s -p "Noves gateway credential: " token </dev/tty
  printf '\n' >/dev/tty
else
  die "Set CDA_NOVES_GATEWAY_AUTH_TOKEN or CDA_NOVES_GATEWAY_AUTH_TOKEN_FILE."
fi
[[ "$token" =~ [^[:space:]] ]] || die "The Noves gateway credential is blank."
```

- [ ] **Step 5: Store both setup credentials**

Helm creates or reuses `token` and `session-token` in the setup Secret. Compose
creates or reuses `CDA_SETUP_TOKEN` and `CDA_SETUP_SESSION_TOKEN` in `.env`.
Pass the session value to the setup container as `CDA_SETUP_SESSION_TOKEN`.

- [ ] **Step 6: Remove the setup Service and add NetworkPolicy**

Render a default-deny ingress policy selecting only the setup-wizard pod. Change
probes to `/health`. Change port-forward to:

```bash
kubectl --namespace "$namespace" port-forward \
  "deployment/${release}-setup-wizard" "$local_port:3000"
```

- [ ] **Step 7: Use parsed route host and gateway Secret in final values**

Read:

```bash
route_host="$(jq -er '.routingHost' <<<"$result_json")"
```

Create or reuse the gateway Secret, and include its name in
`novesGateway.existingSecret`.

- [ ] **Step 8: Run installer and chart tests and commit**

```bash
tests/installers.sh
tests/helm-chart.sh
git add scripts/lib/common.sh scripts/install-helm.sh \
  scripts/install-compose.sh docker-compose/compose.setup.yaml \
  docker-compose/.env.example \
  chart/noves-canton-data-app/values.yaml \
  chart/noves-canton-data-app/values.schema.json \
  chart/noves-canton-data-app/templates/setup-wizard.yaml \
  tests/installers.sh tests/helm-chart.sh
git commit -m "fix: secure guided setup access"
```

Expected: tests pass.

---

### Task 10: Verify image digests before chart publication

**Files:**
- Modify: `canton-data-app/.github/workflows/test.yml`
- Modify: `canton-data-app/chart/noves-canton-data-app/Chart.yaml`
- Create: `canton-data-app/tests/release-workflow.sh`
- Modify: `canton-data-app/tests/all.sh`

**Interfaces:**
- Consumes: three semantic image tags and backend classifier OCI annotation
- Produces: `dist/release-manifest.json` before chart publication

- [ ] **Step 1: Write a failing workflow contract test**

Require the public workflow to contain all three image repositories,
`imagetools inspect`, `release-manifest.json`, classifier annotation extraction,
existing-chart rejection, and artifact upload.

- [ ] **Step 2: Run the test and confirm RED**

```bash
tests/release-workflow.sh
```

Expected: the workflow packages the chart without resolving images.

- [ ] **Step 3: Add release preflight**

After chart/version validation and GHCR login, set up Buildx. For each image:

```bash
ref="$repository:$version"
digest="$(docker buildx imagetools inspect "$ref" |
  awk '/^Digest:/ { print $2; exit }')"
test -n "$digest"
```

Record the expected classifier SHA in
`chart/noves-canton-data-app/Chart.yaml` as
`noves.com/canton-classifier-revision`. Read the backend raw index annotation
and require:

```text
io.noves.canton-classifier.revision
```

to equal the chart annotation.

- [ ] **Step 4: Write and upload the manifest**

Use `jq -n` to create:

```json
{
  "chart": { "version": "4.0.0", "gitSha": "0123456789abcdef0123456789abcdef01234567" },
  "classifierSha": "ddfe8429ffd6727146a43812ae651fa3c3611217",
  "images": {
    "backend": { "repository": "...", "tag": "4.0.0", "digest": "sha256:..." },
    "frontend": { "repository": "...", "tag": "4.0.0", "digest": "sha256:..." },
    "database": { "repository": "...", "tag": "4.0.0", "digest": "sha256:..." }
  }
}
```

Upload the JSON and packaged chart together. Before `helm push`, fail if:

```bash
helm show chart oci://ghcr.io/noves-inc/charts/noves-canton-data-app \
  --version "$version"
```

succeeds.

- [ ] **Step 5: Run workflow and full deployment tests and commit**

```bash
tests/release-workflow.sh
tests/all.sh
git add .github/workflows/test.yml \
  chart/noves-canton-data-app/Chart.yaml \
  tests/release-workflow.sh tests/all.sh
git commit -m "ci: verify v4 release image digests"
```

Expected: public tests pass without contacting GHCR.

---

### Task 11: Update operator documentation

**Files:**
- Modify: `canton-data-app/readme.md`
- Modify: `canton-data-app/docs/helm.md`
- Modify: `canton-data-app/docs/docker-compose.md`
- Modify: `canton-data-app/docs/setup-wizard.md`
- Modify: `canton-data-app/docs/security.md`
- Modify: `canton-data-app/docs/upgrades.md`
- Modify: `canton-data-app/chart/noves-canton-data-app/examples/enterprise-values.yaml`
- Modify: `canton-data-app/tests/docs.sh`

**Interfaces:**
- Consumes: final chart values, Compose secret path, and release manifest
- Produces: standard and guided instructions that match executable artifacts

- [ ] **Step 1: Add failing documentation assertions**

Require docs to name `novesGateway.existingSecret`,
`.secrets/noves-gateway-auth-token`, `_FILE` precedence, `/dev/tty` behavior,
session-token storage, immutable semantic tags, and release manifest.

- [ ] **Step 2: Run docs tests and confirm RED**

```bash
tests/docs.sh
```

Expected: the new required operator contracts are absent.

- [ ] **Step 3: Update standard Helm and Compose instructions**

Document exact Secret creation, file permissions, rotation, and a restart check.
Do not print tokens in verification commands.

- [ ] **Step 4: Update guided and upgrade instructions**

Document automation variables, TTY fallback, durable completion lock, v4 tag
immutability, classifier pin evidence, and digest manifest.

- [ ] **Step 5: Keep screenshot authoring slots out of customer UI**

Leave the screenshot manifest pending. Ensure wizard docs and links use setup
guide wording.

- [ ] **Step 6: Run docs tests and commit**

```bash
tests/docs.sh
git diff --check
git add readme.md docs/helm.md docs/docker-compose.md \
  docs/setup-wizard.md docs/security.md docs/upgrades.md \
  chart/noves-canton-data-app/examples/enterprise-values.yaml tests/docs.sh
git commit -m "docs: explain v4 credentials and release evidence"
```

Expected: documentation tests pass.

---

### Task 12: Run complete verification and merge locally

**Files:**
- Verify all changed files
- Merge feature branches into local target branches

**Interfaces:**
- Consumes: all task commits
- Produces: verified local `master` and `v4` merge commits

- [ ] **Step 1: Run backend verification**

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj
dotnet build CantonDataApp.sln
git diff --check
```

Expected: full suite and build pass in .NET 10. If the workstation still lacks
.NET 10, use the pinned SDK container with both backend and classifier worktrees
mounted as siblings.

- [ ] **Step 2: Run frontend verification**

```bash
pnpm exec vitest run --reporter=dot
pnpm build
pnpm lint
git diff --check
```

Expected: tests and build pass; lint has no errors.

- [ ] **Step 3: Run database verification**

```bash
scripts/test-release-workflow.sh
docker build -t cda-db:v4-hardening-final .
scripts/smoke-test.sh cda-db:v4-hardening-final
git diff --check
```

Expected: workflow contract and smoke test pass.

- [ ] **Step 4: Run public deployment verification**

```bash
tests/all.sh
git diff --check
```

Expected: chart, Compose, installer, release-workflow, and docs tests pass.

- [ ] **Step 5: Review final history and status**

```bash
git status --short
git log --oneline master..HEAD
git log --oneline v4..HEAD
```

Expected: only intended task commits appear and each worktree is clean.

- [ ] **Step 6: Merge and clean up**

Merge backend, frontend, and database into local `master`. Merge public changes
into local `v4`. Re-run the target-branch verification commands, remove the four
feature worktrees, and delete the merged feature branches.

Expected: target branches contain merge commits, feature worktrees are gone,
and no push or deployment occurred.
