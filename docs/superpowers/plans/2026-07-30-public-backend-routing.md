# Public Backend Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the complete v4 backend on `api.<frontend-host>` by default for Helm Ingress and Istio installations, while keeping the Compose backend published on a configurable loopback binding and documenting its Swagger URL.

**Architecture:** Extend the existing `routing` contract with a typed backend block. The Helm routing template will add a second host to the existing provider resource and send it to the backend Service on port 8090. Docker Compose will parameterize the existing backend host binding without adding another proxy container.

**Tech Stack:** Helm 3, Kubernetes Ingress v1, Istio VirtualService v1beta1, Docker Compose v2, Bash contract tests, Markdown operator documentation.

## Global Constraints

- `routing.backend.enabled` defaults to `true`.
- An empty backend host resolves to `api.<routing.host>`.
- An explicit backend host overrides the derived hostname.
- The Helm route exposes the complete backend API on port 8090.
- `routing.provider: none` creates no public routes.
- Compose keeps the backend published by default on `127.0.0.1:8090`.
- The chart and Compose bundle do not create DNS records, certificates, or reverse proxies.
- Existing backend authorization behavior does not change.
- Use test-first changes and stage exact paths.
- Do not push or mutate a live cluster as part of this plan.

---

### Task 1: Add the Helm backend-routing contract

**Files:**
- Modify: `tests/helm-chart.sh`
- Modify: `tests/fixtures/ingress-values.yaml`
- Modify: `tests/fixtures/istio-values.yaml`
- Modify: `chart/noves-canton-data-app/values.yaml`
- Modify: `chart/noves-canton-data-app/values.schema.json`
- Modify: `chart/noves-canton-data-app/templates/_helpers.tpl`
- Modify: `chart/noves-canton-data-app/templates/routing.yaml`
- Modify: `chart/noves-canton-data-app/templates/NOTES.txt`

**Interfaces:**
- Consumes: `routing.provider`, `routing.host`, `routing.tlsSecret`, `routing.ingress.className`, and `routing.istio.gateway`.
- Produces: `routing.backend.enabled: boolean`, `routing.backend.host: string`, `routing.backend.tlsSecret: string`, and the `cda.backendHost` template helper.

- [ ] **Step 1: Add failing default-route assertions**

Extend `tests/helm-chart.sh` after the current route renders:

```bash
assert_contains "$scratch/ingress.yaml" 'host: "api.data.example.com"'
assert_contains "$scratch/ingress.yaml" 'name: cda-backend'
assert_contains "$scratch/ingress.yaml" 'number: 8090'
assert_contains "$scratch/istio.yaml" '- "api.data.example.com"'
assert_contains "$scratch/istio.yaml" 'exact: "api.data.example.com"'
assert_contains "$scratch/istio.yaml" 'host: cda-backend'
assert_contains "$scratch/istio.yaml" 'number: 8090'
```

Add a TLS Secret to `tests/fixtures/ingress-values.yaml`:

```yaml
routing:
  provider: ingress
  host: data.example.com
  tlsSecret: data-example-com-tls
  ingress:
    className: nginx
```

Assert that the rendered Ingress TLS block includes both public hosts:

```bash
[[ "$(grep -c 'data.example.com' "$scratch/ingress.yaml")" -ge 2 ]] ||
  fail 'the ingress must include frontend and backend TLS hosts'
assert_contains "$scratch/ingress.yaml" 'secretName: data-example-com-tls'
```

- [ ] **Step 2: Add failing override and disable assertions**

Render two additional fixtures from the command line:

```bash
helm template cda "$chart" \
  --namespace validator \
  --values "$fixtures/ingress-values.yaml" \
  --show-only templates/routing.yaml \
  --set-string routing.backend.host=backend.example.com \
  --set-string routing.backend.tlsSecret=backend-example-com-tls \
  >"$scratch/backend-override.yaml"

helm template cda "$chart" \
  --namespace validator \
  --values "$fixtures/ingress-values.yaml" \
  --show-only templates/routing.yaml \
  --set routing.backend.enabled=false \
  >"$scratch/backend-disabled.yaml"
```

Add these assertions:

```bash
assert_contains "$scratch/backend-override.yaml" 'host: "backend.example.com"'
assert_contains "$scratch/backend-override.yaml" 'secretName: backend-example-com-tls'
assert_not_contains "$scratch/backend-override.yaml" 'host: "api.data.example.com"'
assert_not_contains "$scratch/backend-disabled.yaml" 'api.data.example.com'
assert_not_contains "$scratch/backend-disabled.yaml" 'name: cda-backend'
```

Add values-schema negative checks:

```bash
if helm lint "$chart" --values "$fixtures/ingress-values.yaml" \
  --set-string routing.backend.enabled=yes >/dev/null 2>&1; then
  fail 'routing.backend.enabled accepted a string'
fi
```

- [ ] **Step 3: Run the Helm test and confirm the new assertions fail**

Run:

```bash
tests/helm-chart.sh
```

Expected: FAIL because `routing.backend` and the backend route do not exist.

- [ ] **Step 4: Add values and schema definitions**

Add this default beneath `routing.annotations` in `values.yaml`:

```yaml
  backend:
    enabled: true
    host: ""
    tlsSecret: ""
```

Add `backend` to the routing schema's required list and define:

```json
"backend": {
  "type": "object",
  "additionalProperties": false,
  "required": ["enabled", "host", "tlsSecret"],
  "properties": {
    "enabled": { "type": "boolean" },
    "host": { "type": "string" },
    "tlsSecret": { "type": "string" }
  }
}
```

- [ ] **Step 5: Add the hostname helper**

Add this helper to `_helpers.tpl`:

```gotemplate
{{- define "cda.backendHost" -}}
{{- default (printf "api.%s" .Values.routing.host) .Values.routing.backend.host -}}
{{- end -}}
```

Keep existing provider validation. The helper runs only inside route and notes
branches that already require a non-empty frontend host.

- [ ] **Step 6: Render both hosts for Kubernetes Ingress**

In `routing.yaml`, resolve:

```gotemplate
{{- $backendEnabled := .Values.routing.backend.enabled -}}
{{- $backendHost := include "cda.backendHost" . -}}
{{- $backendTlsSecret := default .Values.routing.tlsSecret .Values.routing.backend.tlsSecret -}}
```

Keep the frontend rule. Add a second rule when `$backendEnabled`:

```gotemplate
    - host: {{ $backendHost | quote }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "cda.fullname" . }}-backend
                port:
                  number: 8090
```

Render one TLS item with both hosts when the frontend and backend share a
Secret. Render a second TLS item when `routing.backend.tlsSecret` names a
different Secret. Do not render a backend TLS host when backend routing is
disabled.

- [ ] **Step 7: Render both hosts for Istio**

Add the backend hostname to `spec.hosts` when enabled. Prepend this route:

```gotemplate
    - match:
        - authority:
            exact: {{ $backendHost | quote }}
      route:
        - destination:
            host: {{ include "cda.fullname" . }}-backend
            port:
              number: 8090
```

Give the frontend route an explicit authority match so each hostname has one
destination. Remove the backend host and route when the setting is false.

- [ ] **Step 8: Update Helm notes**

When public routing and backend routing are enabled, print the resolved backend
base URL and Swagger URL. Use HTTPS for an Ingress backend that has a TLS
Secret. For Istio, copy the scheme from `oidc.appUrl`.

Include:

```text
Backend API: https://api.data.example.com
Backend docs: https://api.data.example.com/docs
```

When public routing is disabled, retain the backend port-forward command and
add `Open http://127.0.0.1:8090/docs`.

- [ ] **Step 9: Run the focused Helm test**

Run:

```bash
tests/helm-chart.sh
```

Expected: `helm chart tests passed`.

- [ ] **Step 10: Commit the chart contract**

```bash
git add \
  chart/noves-canton-data-app/values.yaml \
  chart/noves-canton-data-app/values.schema.json \
  chart/noves-canton-data-app/templates/_helpers.tpl \
  chart/noves-canton-data-app/templates/routing.yaml \
  chart/noves-canton-data-app/templates/NOTES.txt \
  tests/fixtures/ingress-values.yaml \
  tests/fixtures/istio-values.yaml \
  tests/helm-chart.sh
git commit -m "feat(helm): expose backend on its own host"
```

---

### Task 2: Make the Compose backend binding explicit

**Files:**
- Modify: `tests/docker-compose.sh`
- Modify: `docker-compose/compose.yaml`
- Modify: `docker-compose/.env.example`

**Interfaces:**
- Consumes: Compose port publication for container port 8090.
- Produces: `BACKEND_BIND_ADDRESS` and the existing `BACKEND_PORT`.

- [ ] **Step 1: Add failing default and override tests**

Add to `tests/docker-compose.sh`:

```bash
BACKEND_BIND_ADDRESS=192.0.2.10 \
BACKEND_PORT=18090 \
docker compose --env-file "$compose_dir/.env.example" \
  -f "$compose_dir/compose.yaml" config >"$scratch/backend-binding.yaml"

assert_contains "$scratch/standard.yaml" 'host_ip: 127.0.0.1'
assert_contains "$scratch/standard.yaml" 'published: "8090"'
assert_contains "$scratch/backend-binding.yaml" 'host_ip: 192.0.2.10'
assert_contains "$scratch/backend-binding.yaml" 'published: "18090"'
assert_contains "$compose_dir/.env.example" 'BACKEND_BIND_ADDRESS=127.0.0.1'
```

- [ ] **Step 2: Run the Compose test and confirm the new assertion fails**

Run:

```bash
tests/docker-compose.sh
```

Expected: FAIL because `.env.example` lacks `BACKEND_BIND_ADDRESS`.

- [ ] **Step 3: Parameterize the backend binding**

Change the backend port mapping in `compose.yaml`:

```yaml
ports:
  - "${BACKEND_BIND_ADDRESS:-127.0.0.1}:${BACKEND_PORT:-8090}:8090"
```

Add to the local-bindings section of `.env.example`:

```dotenv
BACKEND_BIND_ADDRESS=127.0.0.1
BACKEND_PORT=8090
```

- [ ] **Step 4: Run the focused Compose test**

Run:

```bash
tests/docker-compose.sh
```

Expected: `docker compose tests passed`.

- [ ] **Step 5: Commit the Compose contract**

```bash
git add docker-compose/compose.yaml docker-compose/.env.example tests/docker-compose.sh
git commit -m "feat(compose): configure backend host binding"
```

---

### Task 3: Document the two-host deployment

**Files:**
- Modify: `readme.md`
- Modify: `docs/helm.md`
- Modify: `docs/docker-compose.md`
- Modify: `docs/security.md`
- Modify: `chart/noves-canton-data-app/examples/enterprise-values.yaml`
- Modify: `chart/noves-canton-data-app/examples/istio-values.yaml`
- Modify: `tests/docs.sh`

**Interfaces:**
- Consumes: the Helm `routing.backend` block and Compose
  `BACKEND_BIND_ADDRESS`.
- Produces: operator instructions for DNS, TLS, backend Swagger, opt-out, and
  reverse-proxy targets.

- [ ] **Step 1: Add failing documentation contracts**

Add these strings to the contract loop in `tests/docs.sh`:

```bash
  'routing.backend.enabled' \
  'api.data.example.com' \
  'BACKEND_BIND_ADDRESS' \
  '/docs/v1/openapi.json' \
  '127.0.0.1:8090'
```

- [ ] **Step 2: Run the documentation test and confirm it fails**

Run:

```bash
tests/docs.sh
```

Expected: FAIL on the first missing backend-routing contract.

- [ ] **Step 3: Update Helm examples and guide**

Add the backend block to both example values files:

```yaml
  backend:
    enabled: true
    host: ""
    tlsSecret: ""
```

In `docs/helm.md`:

- require frontend and backend DNS names;
- show both A or CNAME records pointing to the ingress address;
- explain the `api.` default and explicit override;
- explain shared-certificate SAN coverage and separate backend TLS Secrets;
- state that the Istio Gateway certificate must cover both names;
- show `routing.backend.enabled: false` for frontend-only deployments;
- verify `/docs`, `/docs/v1/openapi.json`, `/health`, and `/ready` on the
  backend hostname.

- [ ] **Step 4: Update Compose and security documentation**

In `docs/docker-compose.md`, document:

```text
Frontend reverse-proxy target: http://127.0.0.1:8091
Backend reverse-proxy target: http://127.0.0.1:8090
Local backend docs: http://127.0.0.1:8090/docs
Public backend docs: https://api.data.example.com/docs
```

Warn that setting `BACKEND_BIND_ADDRESS=0.0.0.0` publishes the complete API on
every host interface.

Update `docs/security.md` and `readme.md` to say the standard routed layout has
two public hostnames. Explain that protected backend endpoints keep their
existing authorization checks and that operators can disable the backend
route.

- [ ] **Step 5: Run documentation and example tests**

Run:

```bash
tests/docs.sh
tests/helm-chart.sh
```

Expected: both scripts pass.

- [ ] **Step 6: Commit operator documentation**

```bash
git add \
  readme.md \
  docs/helm.md \
  docs/docker-compose.md \
  docs/security.md \
  chart/noves-canton-data-app/examples/enterprise-values.yaml \
  chart/noves-canton-data-app/examples/istio-values.yaml \
  tests/docs.sh
git commit -m "docs: explain public backend routing"
```

---

### Task 4: Verify the integrated deployment bundle

**Files:**
- Verify only.

**Interfaces:**
- Consumes: Tasks 1 through 3.
- Produces: fresh evidence that all deployment contracts pass together.

- [ ] **Step 1: Run the complete repository suite**

Run:

```bash
tests/all.sh
```

Expected:

```text
helm chart tests passed
docker compose tests passed
installer tests passed
release workflow tests passed
documentation tests passed
```

- [ ] **Step 2: Check whitespace and repository state**

Run:

```bash
git diff --check
git status --short --branch
git log -5 --oneline
```

Expected: no unstaged implementation changes and the new commits appear on
`v4`.

- [ ] **Step 3: Render the operator examples**

Run:

```bash
helm template cda ./chart/noves-canton-data-app \
  --namespace validator \
  --values chart/noves-canton-data-app/examples/enterprise-values.yaml

helm template cda ./chart/noves-canton-data-app \
  --namespace validator \
  --values chart/noves-canton-data-app/examples/istio-values.yaml
```

Expected: both commands exit 0 and include frontend and backend routes.

- [ ] **Step 4: Report the result without pushing or deploying**

Report the commit SHAs, verification output, expected DNS names, and the exact
backend `/docs` URL. Leave pushing and live-cluster deployment for explicit
operator approval.
