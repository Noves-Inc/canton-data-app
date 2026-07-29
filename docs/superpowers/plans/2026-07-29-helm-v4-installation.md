# Helm v4 Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a chart and operator guide that support a fresh Auth0 installation on NGINX or Istio, fail closed for v3 upgrades, keep PVC export storage as the default, and repair the guided setup handoff.

**Architecture:** Helm values form one typed operator contract and templates translate it into backend environment variables, volumes, Secrets, routes, and policies. The backend enforces the v3 database-source expectation after classification and before mutation. The setup server returns all routing fields needed by the installer so the final Helm upgrade does not discard them.

**Tech Stack:** Helm 3, Kubernetes YAML and JSON Schema, Bash tests, .NET 10 and xUnit, React and TypeScript, Vitest.

## Global Constraints

- Use the private image references recorded in the approved design until Noves publishes v4.
- Keep `/exports` on a ReadWriteOnce PVC unless the operator selects S3.
- Generate a unique accounting encryption key and preserve it across upgrades.
- Use `routing.provider: none | ingress | istio`; do not infer the provider from cluster state.
- Set `DATABASE_EXPECTED_SOURCE=v3` only for the v3 migration path.
- Do not deploy or mutate `canton-mainnet`; use server-side dry-run only.
- Keep the setup wizard disabled by default and implement it after the manual path.
- Preserve the unrelated `docs/V4_FEATURE_TESTING_2026-07-28.md` change in the original backend checkout.

---

### Task 1: Base chart operator contract

**Files:**
- Modify: `tests/helm-chart.sh`
- Modify: `tests/fixtures/enterprise-values.yaml`
- Modify: `tests/fixtures/ingress-values.yaml`
- Modify: `tests/fixtures/invalid-routing-values.yaml`
- Create: `tests/fixtures/s3-values.yaml`
- Create: `tests/fixtures/existing-accounting-secret-values.yaml`
- Modify: `chart/noves-canton-data-app/values.yaml`
- Modify: `chart/noves-canton-data-app/values.schema.json`
- Modify: `chart/noves-canton-data-app/templates/_helpers.tpl`
- Modify: `chart/noves-canton-data-app/templates/backend.yaml`
- Modify: `chart/noves-canton-data-app/templates/frontend.yaml`
- Modify: `chart/noves-canton-data-app/templates/config.yaml`
- Modify: `chart/noves-canton-data-app/templates/database.yaml`
- Modify: `chart/noves-canton-data-app/templates/routing.yaml`
- Create: `chart/noves-canton-data-app/templates/accounting-secret.yaml`
- Create: `chart/noves-canton-data-app/templates/network-policy.yaml`

**Interfaces:**
- Consumes: existing backend variables `ACCOUNTING_TOKEN_ENCRYPTION_KEY`, `EXPORTS_S3_*`, and `BACKUP_S3_*`.
- Produces: `routing.provider`, image `digest`, `accounting.tokenEncryption`, `exports.storage`, typed S3 blocks, and `networkPolicy`.

- [ ] **Step 1: Add failing render assertions**

Add fixture renders and assertions to `tests/helm-chart.sh` for these contracts:

```bash
assert_contains "$scratch/enterprise.yaml" 'noves.azurecr.io/cda-backend:prod-19b8de69-1785353655'
assert_contains "$scratch/enterprise.yaml" 'noves.azurecr.io/cda-frontend:prod-6110f60d-1785354653'
assert_contains "$scratch/enterprise.yaml" 'candidate-30160846627-1@sha256:1482f1b'
assert_contains "$scratch/enterprise.yaml" 'name: ACCOUNTING_TOKEN_ENCRYPTION_KEY'
assert_contains "$scratch/enterprise.yaml" 'kind: Secret'
assert_not_contains "$scratch/enterprise.yaml" 'mountPath: /app/exports'
assert_contains "$scratch/enterprise.yaml" 'ingressClassName: "nginx"'
assert_contains "$scratch/migration.yaml" 'name: DATABASE_EXPECTED_SOURCE'
assert_contains "$scratch/migration.yaml" 'value: "v3"'
assert_contains "$scratch/s3.yaml" 'name: EXPORTS_S3_BUCKET'
assert_not_contains "$scratch/s3.yaml" 'mountPath: /exports'
assert_contains "$scratch/s3.yaml" 'name: BACKUP_S3_BUCKET'
assert_contains "$scratch/enterprise.yaml" 'kind: NetworkPolicy'
```

Add negative renders for an unknown routing provider, missing Ingress class, incomplete S3 credentials, setup plus migration, and a malformed digest.

- [ ] **Step 2: Run the chart test and confirm RED**

Run:

```bash
tests/helm-chart.sh
```

Expected: failure on the first new private-image or `routing.provider` assertion because the current values and templates lack the contract.

- [ ] **Step 3: Implement image rendering and routing**

Add a helper that renders either `repository:tag` or `repository:tag@digest`:

```gotemplate
{{- define "cda.image" -}}
{{- printf "%s:%s" .repository .tag -}}{{- with .digest -}}@{{ . }}{{- end -}}
{{- end -}}
```

Replace the three image expressions with `include "cda.image"`. Replace routing booleans with `provider`, update the route conditionals, and validate provider-specific fields in `_helpers.tpl`.

- [ ] **Step 4: Implement the retained accounting Secret**

Render no Secret when `accounting.tokenEncryption.existingSecret` has a value. Otherwise use `lookup` to preserve the existing generated Secret data and `randBytes 32 | b64enc` to store the base64 key text in Kubernetes Secret `data`.

Set the backend environment reference to the chosen Secret and key. Add `helm.sh/resource-policy: keep`.

- [ ] **Step 5: Implement PVC and S3 storage**

Keep the exports PVC and backend mount only when `exports.storage` equals `pvc`. Remove the frontend mount and volume. When S3 is selected, map bucket, endpoint, region, and credential Secret keys to `EXPORTS_S3_*`. Map the independent backup block to `BACKUP_S3_*`.

- [ ] **Step 6: Add security configuration and database policy**

Expose pod and container security contexts with current safe defaults. Set the backend non-root UID to 1654. Add a database ingress NetworkPolicy selected by `networkPolicy.database.enabled` that permits TCP 5432 from backend pods.

Keep the database UID configurable until the image-volume test in Task 4 passes.

- [ ] **Step 7: Run chart tests and confirm GREEN**

Run:

```bash
tests/helm-chart.sh
```

Expected: `helm chart tests passed`.

- [ ] **Step 8: Commit the base chart**

Stage only the chart, fixtures, and chart test:

```bash
git add chart/noves-canton-data-app tests/helm-chart.sh tests/fixtures
git commit -m "feat: make helm v4 install contract explicit"
```

### Task 2: Fresh Auth0 installation documentation

**Files:**
- Modify: `chart/noves-canton-data-app/examples/enterprise-values.yaml`
- Create: `chart/noves-canton-data-app/examples/istio-values.yaml`
- Modify: `docs/helm.md`
- Modify: `docs/authentication/auth0.md`
- Modify: `docs/authentication/keycloak.md`
- Modify: `docs/security.md`
- Modify: `docs/upgrades.md`
- Modify: `docs/screenshots/README.md`
- Modify: `tests/docs.sh`

**Interfaces:**
- Consumes: Task 1 values and Secret names.
- Produces: a copyable Auth0/NGINX install path and a separate Istio example.

- [ ] **Step 1: Add failing documentation assertions**

Require the new operator checks in `tests/docs.sh`:

```bash
for contract in \
  'routing.provider' \
  'ACCOUNTING_TOKEN_ENCRYPTION_KEY' \
  '/api/v2/capture/status' \
  'kubectl get ingressclass' \
  'kubectl get pvc' \
  'imagePullSecrets'
do
  rg -Fq -- "$contract" "$repo_root/readme.md" "$repo_root/docs" ||
    fail "operator documentation is missing: $contract"
done
```

Add a rejection for `Capture only`, `Redact`, and `Screenshot slot` in provider guides.

- [ ] **Step 2: Run documentation tests and confirm RED**

Run `tests/docs.sh`.

Expected: failure for the missing `routing.provider` contract.

- [ ] **Step 3: Rewrite the Helm guide around the operator sequence**

Document context and namespace checks, validator Service discovery, participant ID retrieval, storage and routing preflight, registry access, Secret creation, one values file, `helm upgrade --install`, rollout checks, and endpoint verification.

State that the chart generates the accounting key and that operators must back up the retained Secret with the database. Explain the existing-Secret override for GitOps.

- [ ] **Step 4: Tighten the provider and security guides**

Keep Auth0 and Keycloak instructions provider-specific. Remove screenshot-production notes and repeated generic install text. Document PVC as the default export store and S3 as an opt-in.

- [ ] **Step 5: Validate the NGINX manifest against canton-mainnet**

Render the chart with a temporary values file that uses:

```yaml
canton:
  participantAddress: participant:5001
  validatorUrl: http://validator-app:5003
routing:
  provider: ingress
  ingress:
    className: nginx
```

Run:

```bash
helm template cda chart/noves-canton-data-app --namespace validator \
  --values chart/noves-canton-data-app/examples/enterprise-values.yaml |
kubectl --context canton-mainnet --namespace validator apply --dry-run=server -f -
```

Expected: every rendered object reports `created (server dry run)` or `configured (server dry run)`.

- [ ] **Step 6: Run docs and deployment suites**

Run:

```bash
tests/docs.sh
tests/all.sh
```

Expected: both pass.

- [ ] **Step 7: Commit the manual installation path**

```bash
git add chart/noves-canton-data-app/examples docs tests/docs.sh
git commit -m "docs: add the helm v4 operator runbook"
```

### Task 3: Fail-closed v3 database expectation

**Files:**
- Modify: `../cda-backend/CantonDataApp.Database/MigrationOptions.cs`
- Modify: `../cda-backend/CantonDataApp.Database/DatabaseCoordinator.cs`
- Modify: `../cda-backend/CantonDataApp/Program.cs`
- Modify: `../cda-backend/CantonDataApp.Tests/Database/CoordinatorTests.cs`
- Modify: `chart/noves-canton-data-app/templates/backend.yaml`
- Modify: `tests/helm-chart.sh`
- Modify: `docs/migrate-v3.16.1.md`
- Modify: `docs/upgrades.md`

**Interfaces:**
- Consumes: `DATABASE_EXPECTED_SOURCE=v3`.
- Produces: `MigrationOptions.ExpectedSource` and a pre-mutation source check in `DatabaseCoordinator`.

- [ ] **Step 1: Add a failing real-database regression test**

Add a coordinator test that constructs:

```csharp
new MigrationOptions
{
    MigrationConnectionString = cs,
    RuntimeConnectionString = cs,
    ExpectedSource = DatabaseExpectedSource.V3
}
```

Call `PrepareDatabaseAsync`, assert `MigrationValidationException`, assert the message says the selected database is empty rather than a v3 upgrade source, and query `pg_extension` plus `__cda_schema_journal` to prove the coordinator made no changes.

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj \
  --filter 'FullyQualifiedName~CoordinatorTests.V3_expectation_refuses_empty_database_before_mutation'
```

Expected: compile failure because `DatabaseExpectedSource` and `ExpectedSource` do not exist.

- [ ] **Step 3: Implement the source expectation**

Add:

```csharp
public enum DatabaseExpectedSource
{
    Any,
    V3
}
```

Add `ExpectedSource` to `MigrationOptions`. In `DatabaseCoordinator`, check the classified state before adoption validation or extension provisioning. Accept `LatestV3`. For `MigrationManaged`, read the recorded bootstrap ID and accept only `BootstrapManifest.PythonId`. Reject all other classifications with `MigrationValidationException`.

Parse `DATABASE_EXPECTED_SOURCE`; accept an empty value or `v3`, and reject unknown values during startup.

- [ ] **Step 4: Verify the focused backend test**

Run the focused test again.

Expected: one passing test and no database writes in the refused case.

- [ ] **Step 5: Inject the expectation from Helm**

Add `DATABASE_EXPECTED_SOURCE=v3` only when `migration.enabled` is true. Update the chart test assertion added in Task 1.

- [ ] **Step 6: Rewrite the migration operator steps**

Add PVC discovery, backup or snapshot evidence, old workload shutdown, a query that proves no pod mounts the claim, namespace requirements, startup and capture monitoring, and instructions to keep migration values after cutover.

- [ ] **Step 7: Run focused and full phase checks**

Run:

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj \
  --filter 'FullyQualifiedName~CoordinatorTests|FullyQualifiedName~PythonBridgeTests'
tests/helm-chart.sh
tests/docs.sh
```

Expected: all pass.

- [ ] **Step 8: Commit each repository**

Backend:

```bash
git add CantonDataApp.Database/MigrationOptions.cs CantonDataApp.Database/DatabaseCoordinator.cs \
  CantonDataApp/Program.cs CantonDataApp.Tests/Database/CoordinatorTests.cs
git commit -m "fix: fail closed on the wrong v3 migration volume"
```

Deployment:

```bash
git add chart/noves-canton-data-app/templates/backend.yaml tests/helm-chart.sh \
  docs/migrate-v3.16.1.md docs/upgrades.md
git commit -m "fix: enforce the helm v3 migration source"
```

### Task 4: Database image security check

**Files:**
- Modify: `chart/noves-canton-data-app/values.yaml`
- Modify: `chart/noves-canton-data-app/values.schema.json`
- Modify: `chart/noves-canton-data-app/templates/database.yaml`
- Modify: `tests/helm-chart.sh`
- Modify: `docs/security.md`

**Interfaces:**
- Consumes: private database image and Kubernetes volume ownership behavior.
- Produces: tested database pod and container security defaults or a documented configurable exception.

- [ ] **Step 1: Inspect the image user and entrypoint**

Run `docker image inspect` against the pinned database image after pulling it with existing GHCR credentials. Record the configured user and entrypoint.

- [ ] **Step 2: Test an empty mounted directory**

Start the image with a temporary Docker volume, the candidate non-root UID and group, and the same `PGDATA`. Wait for `pg_isready`, then stop the container.

Expected: PostgreSQL initializes and reports ready.

- [ ] **Step 3: Test restart with existing data**

Start a second container against the same volume and security settings.

Expected: PostgreSQL reuses the data directory and reports ready without changing ownership through a root entrypoint.

- [ ] **Step 4: Apply the supported default**

If both tests pass, set `runAsNonRoot`, `runAsUser`, `runAsGroup`, `allowPrivilegeEscalation: false`, and dropped capabilities in database values. If the image requires root initialization, keep those values operator-configurable and document the exact Pod Security exception demonstrated by the test.

- [ ] **Step 5: Run chart and docs tests**

Run `tests/helm-chart.sh` and `tests/docs.sh`.

Expected: both pass and the rendered security settings match the measured image behavior.

- [ ] **Step 6: Commit**

```bash
git add chart/noves-canton-data-app docs/security.md tests/helm-chart.sh
git commit -m "fix: align helm database security with the runtime image"
```

### Task 5: Setup wizard handoff

**Files:**
- Modify: `../cda-frontend/src/setup/types.ts`
- Modify: `../cda-frontend/src/setup/SetupWizard.tsx`
- Modify: `../cda-frontend/server/setup/config.js`
- Modify: `../cda-frontend/server/setup/app.js`
- Modify: `../cda-frontend/tests/integration/setup-server.test.ts`
- Modify: `../cda-frontend/tests/integration/setup-wizard.test.tsx`
- Modify: `scripts/install-helm.sh`
- Modify: `tests/installers.sh`
- Modify: `chart/noves-canton-data-app/templates/NOTES.txt`
- Modify: `docs/setup-wizard.md`

**Interfaces:**
- Consumes: Task 1 `routing.provider` contract.
- Produces: setup result fields `routingProvider`, `routingHost`, `tlsSecret`, `ingressClassName`, `routingAnnotations`, and `istioGateway`.

- [ ] **Step 1: Add failing frontend persistence tests**

Extend the setup-server test input with NGINX class and TLS Secret, then assert the completed result contains all six routing fields and no administrator credentials.

Add a component test that selects Ingress and enters `nginx` plus a TLS Secret.

- [ ] **Step 2: Run frontend tests and confirm RED**

Run:

```bash
npm run test:unit -- tests/integration/setup-server.test.ts tests/integration/setup-wizard.test.tsx
```

Expected: type or assertion failures for the missing routing fields.

- [ ] **Step 3: Implement routing fields in the wizard**

Add provider-specific inputs. Require an Ingress class for Ingress. Keep the Istio gateway default. Persist annotations as a key-value object and return the complete sanitized routing result.

- [ ] **Step 4: Add failing installer assertions**

Update `tests/installers.sh` so its guided result contains every routing field. Assert final values include:

```yaml
routing:
  provider: ingress
  host: data.example.com
  tlsSecret: data-example-com-tls
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: 20m
  ingress:
    className: nginx
  istio:
    gateway: cluster-ingress/cn-http-gateway
```

Assert `NOTES.txt` uses `port-forward deployment/<release>-setup-wizard <local>:3000`.

- [ ] **Step 5: Run installer tests and confirm RED**

Run `tests/installers.sh`.

Expected: failure because the installer writes only the old routing mode and host.

- [ ] **Step 6: Implement the final values handoff**

Parse every routing result field with `jq`, write the Task 1 values shape, and retain the existing localhost-only setup flow. Correct `NOTES.txt` and the wizard guide.

- [ ] **Step 7: Verify frontend and installer tests**

Run:

```bash
npm run test:unit -- tests/integration/setup-server.test.ts tests/integration/setup-wizard.test.tsx
tests/installers.sh
tests/docs.sh
```

Expected: all pass.

- [ ] **Step 8: Commit each repository**

Commit frontend routing persistence and deployment installer changes separately with exact staged paths.

### Task 6: Full verification

**Files:**
- Review all changed files in the three feature worktrees.

**Interfaces:**
- Consumes: Tasks 1 through 5.
- Produces: release-ready source changes without publishing artifacts.

- [ ] **Step 1: Run deployment verification**

Run:

```bash
tests/all.sh
git diff --check
```

- [ ] **Step 2: Run backend verification**

Run outside the sandbox:

```bash
dotnet test CantonDataApp.Tests/CantonDataApp.Tests.csproj
git diff --check
```

- [ ] **Step 3: Run frontend verification**

Run:

```bash
npm run test:unit
npm run lint
npm run build
git diff --check
```

- [ ] **Step 4: Inspect repository state**

Run `git status --short` in each worktree. Confirm only intended committed changes exist and the classifier worktree remains detached and unmodified.

- [ ] **Step 5: Review against the approved design**

Check routing, generated key retention, PVC-first storage, optional S3, private images, migration refusal, security behavior, Auth0 instructions, capture verification, and wizard handoff against `docs/superpowers/specs/2026-07-29-helm-v4-installation-design.md`.
