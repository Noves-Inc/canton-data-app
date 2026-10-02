#!/usr/bin/env bash
set -euo pipefail

# Chart render contracts. Everything here is client-side: KUBECONFIG points at an empty file, so neither
# helm lint nor helm template can reach a cluster, and lookup always answers "not found". The lookup
# harness below substitutes a fake cluster state for the two Secret lookups and the backend Deployment
# lookup to exercise the reuse, restore and fail-closed branches that a plain render cannot reach.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="$root/chart/noves-canton-data-app"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export KUBECONFIG="$scratch/empty-kubeconfig"
: >"$KUBECONFIG"

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || fail "helm is required"
python3 -c 'import yaml' 2>/dev/null || fail "python3 with PyYAML is required"

values="$scratch/values.yaml"
cat >"$values" <<'EOF'
oidc:
  provider: auth0
  appUrl: https://data.example.com
  auth0:
    domain: tenant.auth0.com
    clientId: browser-client
    audience: https://canton.network.global
EOF

render() {
  local target="$1" chart_dir="$2"
  shift 2
  helm template cda "$chart_dir" --namespace cda-test --values "$values" "$@" >"$target"
}

# Runs a Python assertion block against a rendered manifest. The block sees `docs` (all objects),
# `find(kind, name)`, `pod(component)` and `check(condition, message)`.
assert_render() {
  local manifest="$1" label="$2"
  python3 - "$manifest" "$label" 3<&0 <<'PY'
import base64, os, sys, yaml

manifest, label = sys.argv[1], sys.argv[2]
with open(manifest) as handle:
    docs = [d for d in yaml.safe_load_all(handle) if d]

def find(kind, name):
    matches = [d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name]
    return matches[0] if matches else None

def pod(component):
    deployment = find("Deployment", f"cda-{component}")
    if deployment is None:
        raise SystemExit(f"FAIL [{label}]: missing {component} Deployment")
    return deployment["spec"]["template"]

def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL [{label}]: {message}")

def secret_value(secret, key):
    raw = base64.b64decode(secret["data"][key])
    check(len(raw) == 44, f"{secret['metadata']['name']} value is {len(raw)} bytes, expected 44")
    check(len(base64.b64decode(raw, validate=True)) == 32, "value does not decode to 32 bytes")
    return raw

exec(os.fdopen(3).read())
PY
}

expect_render_failure() {
  local label="$1" expected="$2" chart_dir="$3"
  shift 3
  if helm template cda "$chart_dir" --namespace cda-test --values "$values" "$@" >"$scratch/failure.out" 2>&1; then
    fail "[$label] render succeeded"
  fi
  grep -Fq -- "$expected" "$scratch/failure.out" || { echo "args: $*" >&2;
    cat "$scratch/failure.out" >&2
    fail "[$label] failure does not mention: $expected"
  }
}

default_render_contracts() {
  local manifest="$scratch/default.yaml"
  render "$manifest" "$chart"
  assert_render "$manifest" default <<'PY'
kek = find("Secret", "cda-installation-kek")
canary = find("Secret", "cda-installation-canary")
check(kek is not None, "KEK Secret is not rendered")
check(canary is not None, "canary Secret is not rendered")
check(kek["metadata"].get("annotations", {}).get("helm.sh/resource-policy") == "keep",
      "KEK Secret is not kept across uninstall")
check("helm.sh/resource-policy" not in (canary["metadata"].get("annotations") or {}),
      "canary Secret must be deleted on uninstall so a reinstall rotates it")
check(list(kek["data"]) == ["installation-kek"], "KEK Secret keys")
check(kek.get("immutable") is True, "the generated KEK Secret must be immutable so no apply can replace its value")
check("immutable" not in canary, "the canary Secret must stay replaceable")
check(list(canary["data"]) == ["installation-canary-capability"], "canary Secret keys")
check(secret_value(kek, "installation-kek") != secret_value(canary, "installation-canary-capability"),
      "KEK and canary must be independent values")

backend = pod("backend")
spec = backend["spec"]
import hashlib
def digest(secret, key):
    return hashlib.sha256(base64.b64decode(secret["data"][key])).hexdigest()
annotations = backend["metadata"]["annotations"]
check(annotations.get("checksum/installation-kek") == digest(kek, "installation-kek"),
      "backend pod template must change when the KEK value changes")
check(annotations.get("checksum/installation-canary") == digest(canary, "installation-canary-capability"),
      "backend pod template must change when the canary value changes")
check(pod("frontend")["metadata"]["annotations"].get("checksum/installation-canary") ==
      digest(canary, "installation-canary-capability"), "frontend pod template must change with the canary value")
check("checksum/installation-kek" not in pod("frontend")["metadata"]["annotations"], "frontend must not depend on the KEK")
check(backend["metadata"]["annotations"].get("noves.fi/installation-kek-secret") == "cda-installation-kek",
      "backend pod template does not record the KEK Secret it depends on")
inits = {c["name"]: c for c in spec["initContainers"]}
check("installation-secrets" in inits, "backend has no installation-secrets init container")
init = inits["installation-secrets"]
main = [c for c in spec["containers"] if c["name"] == "backend"][0]
check(init["image"] == main["image"], "backend init container must use the backend image")
check(init["securityContext"] == main["securityContext"], "backend init container must run as the backend user")
check(init["securityContext"]["runAsUser"] == 1654, "backend runtime uid")
volumes = {v["name"]: v for v in spec["volumes"]}
sources = volumes["installation-secret-sources"]["projected"]
check(sources["defaultMode"] == 0o440, "backend projected Secret mode")
projected = {s["secret"]["name"]: s["secret"]["items"] for s in sources["sources"]}
check(projected == {
    "cda-installation-kek": [{"key": "installation-kek", "path": "kek"}],
    "cda-installation-canary": [{"key": "installation-canary-capability", "path": "canary-capability"}],
}, f"backend projection {projected}")
check(volumes["installation-secrets"]["emptyDir"]["medium"] == "Memory", "backend copies must stay in memory")
init_mounts = {m["name"]: m for m in init["volumeMounts"]}
check(init_mounts["installation-secret-sources"]["readOnly"] is True, "init source mount must be read-only")
check(not init_mounts["installation-secrets"].get("readOnly", False), "init target mount must be writable")
main_mounts = {m["name"]: m for m in main["volumeMounts"]}
check("installation-secret-sources" not in main_mounts, "backend main container must not mount the projected Secret")
check(main_mounts["installation-secrets"] == {"name": "installation-secrets", "mountPath": "/installation-secrets",
                                              "readOnly": True}, "backend main mount")
env = {e["name"]: e.get("value") for e in main["env"]}
check(env.get("INSTALLATION_KEK_FILE") == "/installation-secrets/kek", "backend INSTALLATION_KEK_FILE")
check(env.get("INSTALLATION_CANARY_CAPABILITY_FILE") == "/installation-secrets/canary-capability",
      "backend INSTALLATION_CANARY_CAPABILITY_FILE")
script = init["command"][-1]
for needle in ("for name in kek canary-capability; do", 'source="/installation-secret-sources/$name"',
               'target="/installation-secrets/$name"', "chmod 0600", "stat -c '%u %a'", "[A-Za-z0-9+/]{43}="):
    check(needle in script, f"backend copy script lacks {needle}")

frontend = pod("frontend")
fspec = frontend["spec"]
finits = {c["name"]: c for c in fspec["initContainers"]}
check(list(finits) == ["installation-secrets"], "frontend init containers")
finit = finits["installation-secrets"]
fmain = [c for c in fspec["containers"] if c["name"] == "frontend"][0]
check(finit["image"] == fmain["image"], "frontend init container must use the frontend image")
check(finit["securityContext"] == fmain["securityContext"], "frontend init container must run as the frontend user")
check(finit["securityContext"]["runAsUser"] == 1000, "frontend runtime uid")
fvolumes = {v["name"]: v for v in fspec["volumes"]}
fsources = fvolumes["installation-secret-sources"]["projected"]
check(fsources["defaultMode"] == 0o444, "frontend projected Secret mode")
check([s["secret"]["name"] for s in fsources["sources"]] == ["cda-installation-canary"],
      "frontend must receive only the canary Secret")
check("cda-installation-kek" not in yaml.safe_dump(frontend), "frontend pod references the KEK Secret")
check("/installation-secrets/kek" not in yaml.safe_dump(frontend), "frontend pod references the KEK path")
fenv = {e["name"]: e.get("value") for e in fmain.get("env", [])}
check(fenv == {"INSTALLATION_CANARY_CAPABILITY_FILE": "/installation-secrets/canary-capability"}, f"frontend env {fenv}")
check("INSTALLATION_KEK_FILE" not in yaml.safe_dump(frontend), "frontend must not name the KEK variable")
fmain_mounts = {m["name"]: m for m in fmain["volumeMounts"]}
check(fmain_mounts == {"installation-secrets": {"name": "installation-secrets", "mountPath": "/installation-secrets",
                                               "readOnly": True}}, f"frontend main mounts {fmain_mounts}")
check("for name in canary-capability; do" in finit["command"][-1] and "kek" not in finit["command"][-1],
      "frontend copy script must copy only the canary")
PY
}

existing_secret_contracts() {
  local manifest="$scratch/existing.yaml"
  render "$manifest" "$chart" \
    --set installation.kek.existingSecret=operator-kek \
    --set installation.kek.key=kek-value \
    --set installation.canary.existingSecret=operator-canary \
    --set installation.canary.key=canary-value
  assert_render "$manifest" existing-secret <<'PY'
check(find("Secret", "cda-installation-kek") is None, "KEK Secret rendered despite existingSecret")
check(find("Secret", "cda-installation-canary") is None, "canary Secret rendered despite existingSecret")
backend = pod("backend")
check(not any(k.startswith("checksum/installation-") for k in backend["metadata"]["annotations"]),
      "operator-managed values cannot be checksummed by the chart")
check(backend["metadata"]["annotations"]["noves.fi/installation-kek-secret"] == "operator-kek", "KEK marker")
sources = {v["name"]: v for v in backend["spec"]["volumes"]}["installation-secret-sources"]["projected"]["sources"]
check({s["secret"]["name"]: s["secret"]["items"] for s in sources} == {
    "operator-kek": [{"key": "kek-value", "path": "kek"}],
    "operator-canary": [{"key": "canary-value", "path": "canary-capability"}],
}, "backend projection with existingSecret")
check(all(s["secret"].get("optional") is not True for s in sources), "operator Secrets must not be optional")
fsources = {v["name"]: v for v in pod("frontend")["spec"]["volumes"]}["installation-secret-sources"]["projected"]["sources"]
check([(s["secret"]["name"], s["secret"]["items"]) for s in fsources] ==
      [("operator-canary", [{"key": "canary-value", "path": "canary-capability"}])], "frontend projection")
PY

  render "$manifest" "$chart" --set installation.kek.existingSecret=operator-kek
  assert_render "$manifest" existing-kek-only <<'PY'
check(find("Secret", "cda-installation-kek") is None, "KEK Secret rendered despite existingSecret")
check(find("Secret", "cda-installation-canary") is not None, "canary Secret must still be generated")
PY
}

replica_and_schema_contracts() {
  local manifest="$scratch/replicas.yaml"
  render "$manifest" "$chart" --set frontend.replicaCount=3
  assert_render "$manifest" multi-replica <<'PY'
check(pod("frontend") and find("Deployment", "cda-frontend")["spec"]["replicas"] == 3, "frontend replicas")
check(len([d for d in docs if d.get("kind") == "Secret" and "installation-canary" in d["metadata"]["name"]]) == 1,
      "every frontend replica must share one canary Secret")
PY
  expect_render_failure shared-secret-key 'must not share' "$chart" \
    --set installation.kek.existingSecret=shared --set installation.kek.key=value \
    --set installation.canary.existingSecret=shared --set installation.canary.key=value
  expect_render_failure kek-names-canary-secret 'must not share' "$chart" \
    --set installation.kek.existingSecret=cda-installation-canary --set installation.kek.key=installation-canary-capability
  expect_render_failure canary-names-kek-secret 'must not share' "$chart" \
    --set installation.canary.existingSecret=cda-installation-kek --set installation.canary.key=installation-kek
  expect_render_failure kek-aliases-generated-canary 'must not share' "$chart" \
    --set installation.kek.existingSecret=cda-installation-canary
  expect_render_failure canary-aliases-generated-kek 'must not share' "$chart" \
    --set installation.canary.existingSecret=cda-installation-kek
  render "$scratch/distinct-keys.yaml" "$chart" \
    --set installation.kek.existingSecret=shared --set installation.canary.existingSecret=shared
  # Canonical generated names stay reserved to their role across transitions: once the KEK moves to an
  # operator Secret, the retained generated KEK Secret must not become the canary source.
  expect_render_failure canary-references-retained-kek 'reserves' "$chart" \
    --set installation.kek.existingSecret=operator-kek \
    --set installation.canary.existingSecret=cda-installation-kek --set installation.canary.key=installation-kek
  expect_render_failure canary-references-retained-kek-other-key 'reserves' "$chart" \
    --set installation.kek.existingSecret=operator-kek \
    --set installation.canary.existingSecret=cda-installation-kek --set installation.canary.key=other
  expect_render_failure kek-references-generated-canary 'reserves' "$chart" \
    --set installation.canary.existingSecret=operator-canary \
    --set installation.kek.existingSecret=cda-installation-canary --set installation.kek.key=installation-canary-capability
  render "$scratch/own-role.yaml" "$chart" \
    --set installation.kek.existingSecret=cda-installation-kek --set installation.canary.existingSecret=cda-installation-canary
  # The installation file variables are fixed: extraEnv cannot point the backend at another file.
  expect_render_failure extra-env-kek 'backend.extraEnv must not set INSTALLATION_KEK_FILE' "$chart" \
    --set 'backend.extraEnv[0].name=INSTALLATION_KEK_FILE' \
    --set 'backend.extraEnv[0].value=/installation-secrets/canary-capability'
  expect_render_failure extra-env-canary 'backend.extraEnv must not set INSTALLATION_CANARY_CAPABILITY_FILE' "$chart" \
    --set 'backend.extraEnv[0].name=OTHER' --set 'backend.extraEnv[0].value=x' \
    --set 'backend.extraEnv[1].name=INSTALLATION_CANARY_CAPABILITY_FILE' \
    --set 'backend.extraEnv[1].value=/installation-secrets/kek'
  render "$scratch/extra-env.yaml" "$chart" --set 'backend.extraEnv[0].name=OTHER' --set 'backend.extraEnv[0].value=x'
  local reserved
  for reserved in noves.fi/installation-kek-secret checksum/installation-kek checksum/installation-canary; do
    expect_render_failure "reserved-$reserved" 'the chart reserves it' "$chart" \
      --set-string "podAnnotations.$(printf '%s' "$reserved" | sed 's/[.]/\\./g')=x"
  done
  expect_render_failure backend-replicas '/backend/replicaCount' "$chart" --set backend.replicaCount=2
  expect_render_failure schema-unknown 'installation' "$chart" --set installation.kek.extra=1
  expect_render_failure schema-empty-key 'installation' "$chart" --set installation.kek.key=
  expect_render_failure schema-empty-canary-key 'installation' "$chart" --set installation.canary.key=
  helm lint "$chart" --values "$values" >"$scratch/lint.out" 2>&1 || { cat "$scratch/lint.out" >&2; fail "helm lint"; }
}

# Builds a chart copy whose lookups read the fake cluster state in lookup-state.yaml (keyed
# "<Kind>/<name>") instead of a live API server. Each substitution is counted, so a template change
# that renames the lookup makes the harness fail instead of silently testing nothing.
lookup_harness() {
  local harness="$scratch/harness/noves-canton-data-app"
  rm -rf "$scratch/harness"
  mkdir -p "$scratch/harness"
  cp -R "$chart" "$harness"
  python3 - "$harness" <<'PY'
import pathlib, sys
harness = pathlib.Path(sys.argv[1])
replacements = {
    'lookup "v1" "Secret" .Release.Namespace $kekName':
        '(index (.Files.Get "lookup-state.yaml" | fromYaml) (printf "Secret/%s" $kekName) | default dict)',
    'lookup "v1" "Secret" .Release.Namespace $canaryName':
        '(index (.Files.Get "lookup-state.yaml" | fromYaml) (printf "Secret/%s" $canaryName) | default dict)',
    'lookup "apps/v1" "Deployment" .Release.Namespace $backendName':
        '(index (.Files.Get "lookup-state.yaml" | fromYaml) (printf "Deployment/%s" $backendName) | default dict)',
}
counts = {key: 0 for key in replacements}
path = harness / "templates" / "_helpers.tpl"
text = path.read_text()
for old, new in replacements.items():
    counts[old] += text.count(old)
    text = text.replace(old, new)
path.write_text(text)
expected = {key: 1 for key in replacements}
if counts != expected or 'lookup "' in text:
    raise SystemExit(f"FAIL [lookup-harness]: substitutions {counts}, expected {expected}")
PY
  [[ $? -eq 0 ]] || exit 1
  printf '%s\n' "$harness"
}

write_lookup_state() {
  printf '%s\n' "$2" >"$1/lookup-state.yaml"
}

lookup_contracts() {
  local harness manifest="$scratch/lookup.yaml"
  local kek_b64 canary_b64
  harness="$(lookup_harness)" || fail "lookup harness could not be built"
  # Base64 of the 44-byte text values the Secret data would hold.
  kek_b64="$(printf '%s' 'S0VLS0VLS0VLS0VLS0VLS0VLS0VLS0VLS0VLS0VLS0U=' | base64 | tr -d '\n')"
  canary_b64="$(printf '%s' 'Q0FOQVJZQ0FOQVJZQ0FOQVJZQ0FOQVJZQ0FOQVJZQ0E=' | base64 | tr -d '\n')"

  write_lookup_state "$harness" '{}'
  render "$manifest" "$harness"
  assert_render "$manifest" lookup-first-install <<'PY'
check(find("Secret", "cda-installation-kek") is not None, "first install generates the KEK")
check(find("Secret", "cda-installation-canary") is not None, "first install generates the canary")
PY

  # Upgrade (or reinstall after uninstall, where the kept KEK Secret is adopted): both values reused.
  write_lookup_state "$harness" "
Secret/cda-installation-kek: {data: {installation-kek: $kek_b64}}
Secret/cda-installation-canary: {data: {installation-canary-capability: $canary_b64}}
Deployment/cda-backend: {spec: {template: {metadata: {annotations: {noves.fi/installation-kek-secret: cda-installation-kek}}}}}"
  render "$manifest" "$harness"
  KEK_B64="$kek_b64" CANARY_B64="$canary_b64" assert_render "$manifest" lookup-upgrade <<'PY'
check(find("Secret", "cda-installation-kek")["data"]["installation-kek"] == os.environ["KEK_B64"], "KEK not reused")
check(find("Secret", "cda-installation-canary")["data"]["installation-canary-capability"] == os.environ["CANARY_B64"],
      "canary not reused on upgrade")
import hashlib
for component in ("backend", "frontend"):
    check(pod(component)["metadata"]["annotations"]["checksum/installation-canary"] ==
          hashlib.sha256(base64.b64decode(os.environ["CANARY_B64"])).hexdigest(), f"{component} canary checksum on upgrade")
check(pod("backend")["metadata"]["annotations"]["checksum/installation-kek"] ==
      hashlib.sha256(base64.b64decode(os.environ["KEK_B64"])).hexdigest(), "backend KEK checksum on upgrade")
PY

  # Reinstall after uninstall: the kept KEK is adopted, the deleted canary is regenerated.
  write_lookup_state "$harness" "Secret/cda-installation-kek: {data: {installation-kek: $kek_b64}}"
  render "$manifest" "$harness"
  KEK_B64="$kek_b64" CANARY_B64="$canary_b64" assert_render "$manifest" lookup-reinstall <<'PY'
check(find("Secret", "cda-installation-kek")["data"]["installation-kek"] == os.environ["KEK_B64"], "KEK not adopted")
check(find("Secret", "cda-installation-canary")["data"]["installation-canary-capability"] != os.environ["CANARY_B64"],
      "canary must rotate on reinstall")
secret_value(find("Secret", "cda-installation-canary"), "installation-canary-capability")
PY

  # Upgrade from 4.1.3: the live backend predates the KEK, so a missing Secret is a first provision.
  write_lookup_state "$harness" "Deployment/cda-backend: {spec: {template: {metadata: {annotations: {checksum/config: abc}}}}}"
  render "$manifest" "$harness"
  assert_render "$manifest" lookup-upgrade-from-4.1.3 <<'PY'
secret_value(find("Secret", "cda-installation-kek"), "installation-kek")
PY

  # Lost Secret with a retained database: the live backend already depends on the KEK.
  write_lookup_state "$harness" "Deployment/cda-backend: {spec: {template: {metadata: {annotations: {noves.fi/installation-kek-secret: cda-installation-kek}}}}}"
  expect_render_failure lookup-lost-kek 'cda-installation-kek' "$harness"
  grep -Fq 'restore' "$scratch/failure.out" || fail "[lookup-lost-kek] failure does not explain the restore"

  # A KEK Secret that lost its key is never silently replaced.
  write_lookup_state "$harness" "Secret/cda-installation-kek: {data: {other-key: $kek_b64}}"
  expect_render_failure lookup-kek-without-key 'installation-kek' "$harness"

  # A canary Secret without its key is replaced: the capability carries no stored state.
  write_lookup_state "$harness" "Secret/cda-installation-canary: {data: {other-key: $canary_b64}}"
  render "$manifest" "$harness"
  assert_render "$manifest" lookup-canary-without-key <<'PY'
secret_value(find("Secret", "cda-installation-canary"), "installation-canary-capability")
PY

  # Restored Secret: the operator re-applied the backed-up KEK; the chart reuses it.
  write_lookup_state "$harness" "
Secret/cda-installation-kek: {data: {installation-kek: $kek_b64}}
Deployment/cda-backend: {spec: {template: {metadata: {annotations: {noves.fi/installation-kek-secret: cda-installation-kek}}}}}"
  render "$manifest" "$harness"
  KEK_B64="$kek_b64" assert_render "$manifest" lookup-restored <<'PY'
check(find("Secret", "cda-installation-kek")["data"]["installation-kek"] == os.environ["KEK_B64"], "restored KEK reused")
PY

  # A KEK Secret recreated with a different value than the live backend copied is refused.
  local kek_digest
  kek_digest="$(printf '%s' 'S0VLS0VLS0VLS0VLS0VLS0VLS0VLS0VLS0VLS0VLS0U=' | shasum -a 256 | cut -d' ' -f1)"
  write_lookup_state "$harness" "
Secret/cda-installation-kek: {data: {installation-kek: $canary_b64}}
Deployment/cda-backend: {spec: {template: {metadata: {annotations: {noves.fi/installation-kek-secret: cda-installation-kek, checksum/installation-kek: $kek_digest}}}}}"
  expect_render_failure lookup-wrong-restore 'does not match' "$harness"
  write_lookup_state "$harness" "
Secret/cda-installation-kek: {data: {installation-kek: $kek_b64}}
Deployment/cda-backend: {spec: {template: {metadata: {annotations: {noves.fi/installation-kek-secret: cda-installation-kek, checksum/installation-kek: $kek_digest}}}}}"
  render "$manifest" "$harness"

  # Moving to an operator-managed KEK, or between operator Secrets or keys, must keep the value.
  local live_backend="Deployment/cda-backend: {spec: {template: {metadata: {annotations: {noves.fi/installation-kek-secret: cda-installation-kek, checksum/installation-kek: $kek_digest}}}}}"
  write_lookup_state "$harness" "
Secret/operator-kek: {data: {installation-kek: $canary_b64}}
$live_backend"
  expect_render_failure lookup-generated-to-wrong-existing 'does not match' "$harness" --set installation.kek.existingSecret=operator-kek
  write_lookup_state "$harness" "
Secret/operator-kek: {data: {installation-kek: $kek_b64, other: $canary_b64}}
$live_backend"
  render "$manifest" "$harness" --set installation.kek.existingSecret=operator-kek
  KEK_DIGEST="$kek_digest" assert_render "$manifest" lookup-generated-to-matching-existing <<'PY'
check(pod("backend")["metadata"]["annotations"].get("checksum/installation-kek") == os.environ["KEK_DIGEST"],
      "an operator-managed KEK keeps the checksum so later changes are detected")
PY
  expect_render_failure lookup-existing-key-change 'does not match' "$harness" \
    --set installation.kek.existingSecret=operator-kek --set installation.kek.key=other
  expect_render_failure lookup-existing-missing-key 'exists without key' "$harness" \
    --set installation.kek.existingSecret=operator-kek --set installation.kek.key=absent

  # A selected operator-managed KEK Secret that is absent while the live backend depends on a KEK fails
  # rendering, so the checksum survives and a later wrong restore is still detected.
  write_lookup_state "$harness" "$live_backend"
  expect_render_failure lookup-missing-operator-kek 'operator-kek is missing' "$harness" --set installation.kek.existingSecret=operator-kek
  write_lookup_state "$harness" "Deployment/cda-backend: {spec: {template: {metadata: {annotations: {checksum/installation-kek: $kek_digest}}}}}"
  expect_render_failure lookup-missing-operator-kek-checksum-only 'operator-kek is missing' "$harness" \
    --set installation.kek.existingSecret=operator-kek
  write_lookup_state "$harness" "Deployment/cda-backend: {spec: {template: {metadata: {annotations: {noves.fi/installation-kek-secret: operator-kek}}}}}"
  expect_render_failure lookup-missing-operator-kek-marker-only 'operator-kek is missing' "$harness" \
    --set installation.kek.existingSecret=operator-kek
  write_lookup_state "$harness" "
Secret/operator-kek: {data: {installation-kek: $canary_b64}}
$live_backend"
  expect_render_failure lookup-missing-then-wrong-operator-restore 'does not match' "$harness" \
    --set installation.kek.existingSecret=operator-kek
  # No live backend (first install with an operator-managed KEK): kubelet enforces the Secret's presence.
  write_lookup_state "$harness" '{}'
  render "$manifest" "$harness" --set installation.kek.existingSecret=operator-kek
}

# Runs the rendered init-container scripts in a local Linux container that reproduces the pod's file
# ownership: projected files owned by root (group 1654 through fsGroup for the backend), the emptyDir
# world-writable, and the script running as the runtime uid. Needs local Docker and an image that has
# setpriv; nothing is pulled.
init_permission_contracts() {
  local image="${CDA_TEST_LINUX_IMAGE:-mcr.microsoft.com/dotnet/sdk:10.0}"
  local manifest="$scratch/init.yaml" valid other
  command -v docker >/dev/null 2>&1 || fail "docker is required for init-permissions"
  docker image inspect "$image" >/dev/null 2>&1 || fail "local image $image is required (set CDA_TEST_LINUX_IMAGE)"
  render "$manifest" "$chart"
  python3 - "$manifest" "$scratch" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
for component in ("backend", "frontend"):
    deployment = [d for d in docs if d.get("kind") == "Deployment" and d["metadata"]["name"] == f"cda-{component}"][0]
    init = [c for c in deployment["spec"]["template"]["spec"]["initContainers"] if c["name"] == "installation-secrets"][0]
    open(f"{sys.argv[2]}/{component}-init.sh", "w").write(init["command"][-1])
PY
  valid="$(openssl rand -base64 32 | tr -d '\n')"
  other="$(openssl rand -base64 32 | tr -d '\n')"

  # Arguments: uid, supplementary group (fsGroup or "none"), source group, source mode, script,
  # then name=value pairs for the projected files. Prints the container output.
  run_init() {
    local uid="$1" groups="$2" source_group="$3" source_mode="$4" script="$5"
    shift 5
    docker run --rm --network none --pull never --user 0:0 \
      --volume "$scratch/$script:/init.sh:ro" \
      --env UID_UNDER_TEST="$uid" --env GROUPS_UNDER_TEST="$groups" \
      --env SOURCE_GROUP="$source_group" --env SOURCE_MODE="$source_mode" \
      --entrypoint /bin/sh "$image" -ec '
        mkdir -p /installation-secret-sources /installation-secrets
        chmod 0777 /installation-secrets
        for pair in "$@"; do
          name="${pair%%=*}"
          printf "%s" "${pair#*=}" >"/installation-secret-sources/$name"
          chown "0:$SOURCE_GROUP" "/installation-secret-sources/$name"
          chmod "$SOURCE_MODE" "/installation-secret-sources/$name"
        done
        if [ "$GROUPS_UNDER_TEST" = none ]; then group_args="--clear-groups"; else group_args="--groups $GROUPS_UNDER_TEST"; fi
        setpriv --reuid "$UID_UNDER_TEST" --regid "$UID_UNDER_TEST" $group_args sh -ec "$(cat /init.sh)"
        for file in /installation-secrets/*; do
          [ -e "$file" ] || continue
          printf "%s %s %s\n" "$file" "$(stat -c "%u %a" "$file")" "$(cat "$file")"
        done
        if [ -e /installation-secrets/kek ] &&
          setpriv --reuid 1000 --regid 1000 --clear-groups cat /installation-secrets/kek >/dev/null 2>&1; then
          echo "uid 1000 read the backend KEK copy"
          exit 1
        fi
      ' sh "$@"
  }

  run_init 1654 1654 1654 0440 backend-init.sh "kek=$valid" "canary-capability=$other" >"$scratch/backend-init.out" ||
    { cat "$scratch/backend-init.out" >&2; fail "[init-permissions] backend copy failed"; }
  grep -Fxq "/installation-secrets/kek 1654 600 $valid" "$scratch/backend-init.out" ||
    fail "[init-permissions] backend KEK copy: $(cat "$scratch/backend-init.out")"
  grep -Fxq "/installation-secrets/canary-capability 1654 600 $other" "$scratch/backend-init.out" ||
    fail "[init-permissions] backend canary copy: $(cat "$scratch/backend-init.out")"

  run_init 1000 none 0 0444 frontend-init.sh "canary-capability=$other" >"$scratch/frontend-init.out" ||
    { cat "$scratch/frontend-init.out" >&2; fail "[init-permissions] frontend copy failed"; }
  [[ "$(cat "$scratch/frontend-init.out")" == "/installation-secrets/canary-capability 1000 600 $other" ]] ||
    fail "[init-permissions] frontend copy: $(cat "$scratch/frontend-init.out")"

  if run_init 1654 1654 1654 0440 backend-init.sh "kek=${valid%?}" "canary-capability=$other" >"$scratch/short.out" 2>&1; then
    fail "[init-permissions] a 43-byte KEK was accepted"
  fi
  grep -Fq 'must be the base64 encoding of 32 bytes' "$scratch/short.out" || fail "[init-permissions] short KEK message"
  if run_init 1654 1654 1654 0440 backend-init.sh "kek=$valid"$'\n' "canary-capability=$other" >"$scratch/newline.out" 2>&1; then
    fail "[init-permissions] a KEK with a trailing newline was accepted"
  fi
  if run_init 1654 1654 1654 0440 backend-init.sh "canary-capability=$other" >"$scratch/missing.out" 2>&1; then
    fail "[init-permissions] a missing KEK was accepted"
  fi
  grep -Fq 'Installation secret kek is missing' "$scratch/missing.out" || fail "[init-permissions] missing KEK message"
  # Without the fsGroup the backend uid cannot read the 0440 projection: the pod stops instead of starting without a KEK.
  if run_init 1654 none 0 0440 backend-init.sh "kek=$valid" "canary-capability=$other" >"$scratch/nofsgroup.out" 2>&1; then
    fail "[init-permissions] the backend copied a Secret it should not be able to read"
  fi
}

case "${1:-all}" in
  all) default_render_contracts; existing_secret_contracts; replica_and_schema_contracts; lookup_contracts ;;
  default) default_render_contracts ;;
  existing) existing_secret_contracts ;;
  replicas) replica_and_schema_contracts ;;
  lookup) lookup_contracts ;;
  init-permissions) init_permission_contracts ;;
  *) fail "Usage: $0 [all|default|existing|replicas|lookup|init-permissions]" ;;
esac

echo "chart contracts passed"
