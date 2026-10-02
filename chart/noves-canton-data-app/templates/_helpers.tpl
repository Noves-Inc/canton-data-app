{{- define "cda.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cda.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "cda.labels" -}}
app.kubernetes.io/name: {{ include "cda.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "cda.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cda.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "cda.image" -}}
{{- printf "%s:%s" .repository .tag -}}{{- with .digest -}}@{{ . }}{{- end -}}
{{- end -}}

{{- define "cda.backendHost" -}}
{{- default (printf "api.%s" .Values.routing.host) .Values.routing.backend.host -}}
{{- end -}}

{{- define "cda.validate" -}}
{{- if not (or (eq .Values.routing.provider "none") (eq .Values.routing.provider "ingress") (eq .Values.routing.provider "istio")) -}}
{{- fail "routing.provider must be one of none, ingress, or istio" -}}
{{- end -}}
{{- if and (ne .Values.routing.provider "none") (not .Values.routing.host) -}}
{{- fail "routing.host is required when routing.provider is ingress or istio" -}}
{{- end -}}
{{- if and (eq .Values.routing.provider "ingress") (not .Values.routing.ingress.className) -}}
{{- fail "routing.ingress.className is required when routing.provider=ingress" -}}
{{- end -}}
{{- if and (eq .Values.routing.provider "istio") (not .Values.routing.istio.gateway) -}}
{{- fail "routing.istio.gateway is required when routing.provider=istio" -}}
{{- end -}}
{{- if ne (int .Values.backend.replicaCount) 1 -}}
{{- fail "backend.replicaCount must be 1" -}}
{{- end -}}
{{- if ge (int .Values.backend.performance.readModel.reservedLiveCapacity) (int .Values.backend.performance.readModel.totalCapacity) -}}
{{- fail "backend.performance.readModel.reservedLiveCapacity must be less than totalCapacity" -}}
{{- end -}}
{{- if and (eq .Values.exports.storage "s3") (not .Values.exports.s3.bucket) -}}
{{- fail "exports.s3.bucket is required when exports.storage=s3" -}}
{{- end -}}
{{- if and .Values.backup.s3.enabled (not .Values.backup.s3.bucket) -}}
{{- fail "backup.s3.bucket is required when backup.s3.enabled=true" -}}
{{- end -}}
{{- if .Values.migration.enabled -}}
{{- if ne .Values.migration.sourceVersion "3.16.1" -}}
{{- fail "migration requires an existing installation of v3.16.1 of the Noves Data App" -}}
{{- end -}}
{{- if not .Values.migration.backupConfirmed -}}
{{- fail "migration requires backupConfirmed=true for the database from v3.16.1 of the Noves Data App" -}}
{{- end -}}
{{- if not .Values.migration.oldWorkloadStopped -}}
{{- fail "migration requires oldWorkloadStopped=true for v3.16.1 of the Noves Data App" -}}
{{- end -}}
{{- if not .Values.migration.existingClaim -}}
{{- fail "migration requires migration.existingClaim" -}}
{{- end -}}
{{- end -}}
{{- if not (or (eq .Values.oidc.provider "auth0") (eq .Values.oidc.provider "keycloak")) -}}
{{- fail "oidc.provider must be auth0 or keycloak" -}}
{{- end -}}
{{- if not .Values.oidc.appUrl -}}
{{- fail "oidc.appUrl is required" -}}
{{- end -}}
{{- if and (eq .Values.oidc.provider "auth0") (or (not .Values.oidc.auth0.domain) (not .Values.oidc.auth0.clientId) (not .Values.oidc.auth0.audience)) -}}
{{- fail "oidc.auth0.domain, oidc.auth0.clientId, and oidc.auth0.audience are required for Auth0" -}}
{{- end -}}
{{- if and (eq .Values.oidc.provider "keycloak") (or (not .Values.oidc.keycloak.url) (not .Values.oidc.keycloak.realm) (not .Values.oidc.keycloak.clientId)) -}}
{{- fail "oidc.keycloak.url, oidc.keycloak.realm, and oidc.keycloak.clientId are required for Keycloak" -}}
{{- end -}}
{{- $seenNodeIds := dict -}}
{{- $needsGlobalM2mIndexing := false -}}
{{- range $node := .Values.canton.nodes -}}
{{- if hasKey $seenNodeIds $node.id -}}
{{- fail (printf "canton.nodes contains duplicate id %q" $node.id) -}}
{{- end -}}
{{- $_ := set $seenNodeIds $node.id true -}}
{{- $tls := $node.tls -}}
{{- if ne (empty $tls.clientCertificateKey) (empty $tls.clientPrivateKeyKey) -}}
{{- fail (printf "canton.nodes[%s].tls.clientCertificateKey and clientPrivateKeyKey must be configured together" $node.id) -}}
{{- end -}}
{{- if and (or $tls.certificateKey $tls.clientCertificateKey) (not $tls.existingSecret) -}}
{{- fail (printf "canton.nodes[%s].tls.existingSecret is required when configuring TLS certificate keys" $node.id) -}}
{{- end -}}
{{- $credential := $node.m2mIndexing -}}
{{- if eq $credential.mode "clientCredentials" -}}
{{- if or (not $credential.tokenEndpoint) (not $credential.clientId) (not $credential.existingSecret) -}}
{{- fail (printf "canton.nodes[%s].m2mIndexing.tokenEndpoint, clientId, and existingSecret are required when mode=clientCredentials" $node.id) -}}
{{- end -}}
{{- else if eq $credential.mode "staticToken" -}}
{{- if not $credential.existingSecret -}}
{{- fail (printf "canton.nodes[%s].m2mIndexing.existingSecret is required when mode=staticToken" $node.id) -}}
{{- end -}}
{{- if or $credential.tokenEndpoint $credential.clientId $credential.audience $credential.scope -}}
{{- fail (printf "canton.nodes[%s].m2mIndexing client-credentials fields are incompatible with mode=staticToken" $node.id) -}}
{{- end -}}
{{- else if eq $credential.mode "global" -}}
{{- $needsGlobalM2mIndexing = true -}}
{{- if or $credential.tokenEndpoint $credential.clientId $credential.audience $credential.scope $credential.existingSecret -}}
{{- fail (printf "canton.nodes[%s].m2mIndexing fields require mode=clientCredentials or mode=staticToken" $node.id) -}}
{{- end -}}
{{- else -}}
{{- fail (printf "canton.nodes[%s].m2mIndexing.mode must be global, clientCredentials, or staticToken" $node.id) -}}
{{- end -}}
{{- end -}}
{{- if and $needsGlobalM2mIndexing (not .Values.m2mIndexing.existingSecret) -}}
{{- fail "m2mIndexing.existingSecret is required when any canton.nodes m2mIndexing mode is global" -}}
{{- end -}}
{{- if not .Values.database.existingSecret -}}
{{- fail "database.existingSecret is required" -}}
{{- end -}}
{{- include "cda.installationDefaults" . -}}
{{- /* Names and keys are rendered into YAML and into lookups, so each must be exactly a Kubernetes
Secret name (DNS-1123 subdomain: at most 253 characters, labels of at most 63) or Secret key; anything else could parse as a different Secret. */ -}}
{{- range $role := list "kek" "canary" -}}
{{- $secret := index $.Values.installation $role -}}
{{- if and $secret.existingSecret (or (gt (len $secret.existingSecret) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?([.][a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $secret.existingSecret))) -}}
{{- fail (printf "installation.%s.existingSecret must be a Kubernetes Secret name: %q" $role $secret.existingSecret) -}}
{{- end -}}
{{- if or (gt (len $secret.key) 253) (not (regexMatch "^[-._a-zA-Z0-9]+$" $secret.key)) -}}
{{- fail (printf "installation.%s.key must be a Kubernetes Secret key: %q" $role $secret.key) -}}
{{- end -}}
{{- end -}}
{{- /* One Secret may hold both values only when the operator manages it and keeps them under distinct
keys; a shared key would hand the KEK to the frontend, and a chart-generated Secret holds one key only. */ -}}
{{- if eq (include "cda.installationKekSecretName" .) (include "cda.installationCanarySecretName" .) -}}
{{- if or (eq .Values.installation.kek.key .Values.installation.canary.key) (not .Values.installation.kek.existingSecret) (not .Values.installation.canary.existingSecret) -}}
{{- fail "installation.kek and installation.canary must not share a Secret key, or a Secret the chart generates: the frontend would receive the KEK" -}}
{{- end -}}
{{- end -}}
{{- /* The canonical generated Secret names stay reserved to their role whether or not the chart
generates them now: a generated KEK Secret is retained after the KEK moves to an operator Secret, so a
canary that named it would copy the KEK into the frontend. */ -}}
{{- $generatedKek := include "cda.installationGeneratedSecretName" (dict "context" . "suffix" "installation-kek") -}}
{{- $generatedCanary := include "cda.installationGeneratedSecretName" (dict "context" . "suffix" "installation-canary") -}}
{{- /* A role's own generated name as existingSecret would drop that Secret from the release, and Helm
would delete the Secret both pods mount. */ -}}
{{- if eq .Values.installation.kek.existingSecret $generatedKek -}}
{{- fail (printf "installation.kek.existingSecret must not name %s, its own generated Secret: leave existingSecret empty to keep using it" $generatedKek) -}}
{{- end -}}
{{- if eq .Values.installation.canary.existingSecret $generatedCanary -}}
{{- fail (printf "installation.canary.existingSecret must not name %s, its own generated Secret: leave existingSecret empty to keep using it" $generatedCanary) -}}
{{- end -}}
{{- if eq .Values.installation.canary.existingSecret $generatedKek -}}
{{- fail (printf "installation.canary.existingSecret must not name %s: the chart reserves that Secret for the installation KEK" $generatedKek) -}}
{{- end -}}
{{- if eq .Values.installation.kek.existingSecret $generatedCanary -}}
{{- fail (printf "installation.kek.existingSecret must not name %s: the chart reserves that Secret for the canary capability" $generatedCanary) -}}
{{- end -}}
{{- /* The installation file variables are fixed: pointing the backend at another file would encrypt the
signing key with a value that is not the retained KEK. */ -}}
{{- range $entry := .Values.backend.extraEnv -}}
{{- if has $entry.name (list "INSTALLATION_KEK_FILE" "INSTALLATION_CANARY_CAPABILITY_FILE") -}}
{{- fail (printf "backend.extraEnv must not set %s: the chart fixes it to the copied installation secret" $entry.name) -}}
{{- end -}}
{{- end -}}
{{- /* The installation annotations carry the lost-KEK check and the restart checksums. */ -}}
{{- range $annotation := list "noves.fi/installation-kek-secret" "checksum/installation-kek" "checksum/installation-canary" -}}
{{- if hasKey $.Values.podAnnotations $annotation -}}
{{- fail (printf "podAnnotations must not set %s: the chart reserves it" $annotation) -}}
{{- end -}}
{{- end -}}
{{- range $field, $value := dict
  "m2mIndexing.ledgerApiUserKey" .Values.m2mIndexing.ledgerApiUserKey
  "m2mIndexing.tokenEndpointKey" .Values.m2mIndexing.tokenEndpointKey
  "m2mIndexing.clientIdKey" .Values.m2mIndexing.clientIdKey
  "m2mIndexing.clientSecretKey" .Values.m2mIndexing.clientSecretKey
  "m2mIndexing.audienceKey" .Values.m2mIndexing.audienceKey
  "m2mIndexing.scopeKey" .Values.m2mIndexing.scopeKey
-}}
{{- if not $value -}}
{{- fail (printf "%s is required" $field) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The volume size the backend paces background indexing against.

database.persistence.size is the answer only when the chart creates the claim from it. A claim
the chart did not create carries a size it cannot read, and in migration mode the database runs
on migration.existingClaim with no volumeClaimTemplate at all, so persistence.size describes no
volume and would hand the backend a figure unrelated to the disk it is on. Declaring a capacity
smaller than the database latches background indexing with no reachable resume, so those cases
render "0" (unevaluated) until the operator states the size in the tuning block.
*/}}
{{- define "noves-canton-data-app.databaseVolumeCapacity" -}}
{{- $declared := .Values.backend.performance.readModel.databaseVolumeCapacity | toString -}}
{{- if $declared -}}
{{- $declared -}}
{{- else if or .Values.migration.enabled .Values.database.persistence.existingClaim -}}
0
{{- else -}}
{{- .Values.database.persistence.size | toString -}}
{{- end -}}
{{- end -}}

{{/*
Fills the installation block in .Values with its defaults, field by field. helm upgrade
--reuse-values from 4.1.3 hands the templates the 4.1.3 release values, which have no installation
block at all, so every template and helper that reads .Values.installation calls this first; a
missing or partial block then behaves exactly like the defaults. Idempotent.
*/}}
{{- define "cda.installationDefaults" -}}
{{- if not (kindIs "map" .Values.installation) -}}
{{- $_ := set .Values "installation" dict -}}
{{- end -}}
{{- range $role, $key := dict "kek" "installation-kek" "canary" "installation-canary-capability" -}}
{{- if not (kindIs "map" (index $.Values.installation $role)) -}}
{{- $_ := set $.Values.installation $role dict -}}
{{- end -}}
{{- $secret := index $.Values.installation $role -}}
{{- if not (hasKey $secret "existingSecret") -}}
{{- $_ := set $secret "existingSecret" "" -}}
{{- end -}}
{{- if not (hasKey $secret "key") -}}
{{- $_ := set $secret "key" $key -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Secrets the pods read the installation KEK and the canary capability from: the operator-managed
Secret when existingSecret is set, otherwise the one the chart generates.
*/}}
{{- define "cda.installationKekSecretName" -}}
{{- include "cda.installationDefaults" . -}}
{{- default (include "cda.installationGeneratedSecretName" (dict "context" . "suffix" "installation-kek")) .Values.installation.kek.existingSecret -}}
{{- end -}}

{{- define "cda.installationCanarySecretName" -}}
{{- include "cda.installationDefaults" . -}}
{{- default (include "cda.installationGeneratedSecretName" (dict "context" . "suffix" "installation-canary")) .Values.installation.canary.existingSecret -}}
{{- end -}}

{{/*
Name of a chart-generated installation Secret: "<fullname>-<suffix>" when that fits the 63-character
limit of a DNS label, otherwise the fullname truncated so that "<base>-<hash>-<suffix>" is exactly
within it. The 8-character hash is of the full fullname, so the name is stable across renders and two
fullnames sharing a long prefix never collide. Every reference (Secrets, projections, the KEK marker,
lookups and the reserved-name rules) goes through this helper. Arguments: dict with "context" and
"suffix".
*/}}
{{- define "cda.installationGeneratedSecretName" -}}
{{- $fullname := include "cda.fullname" .context -}}
{{- $name := printf "%s-%s" $fullname .suffix -}}
{{- if gt (len $name) 63 -}}
{{- $base := regexReplaceAll "[-.]+$" (trunc (int (sub 63 (add (len .suffix) 10))) $fullname) "" -}}
{{- $name = printf "%s-%s-%s" $base (sha256sum $fullname | trunc 8) .suffix -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{/*
The Secret data values (base64 of the 44-character text) of the installation Secrets, as YAML with
keys "kek" and "canary", plus "kekGenerated" when this render created a new KEK. An operator-managed
Secret contributes its value whenever lookup can read it, so its KEK checksum guards it the same way and
its canary checksum rolls both Deployments when it changes; the key is absent otherwise.

The value is computed once per render and memoized in .Values, so the Secret templates and the pod
checksum annotations all see the same random value; computing it per template would give each a
different one. The pod templates carry a checksum of each value, so a regenerated canary or a restored
KEK recreates the pods that copied the previous value.

KEK rules. They apply to the chart-generated Secret and to an operator-managed one alike, so moving
between them, or between operator Secrets or keys, is accepted only when the value stays the same. The
generated Secret is reused through lookup and is never replaced on its own initiative: a new value
on a database that already holds installation material leaves the backend unable to use its
credential. Two states are render failures instead of regeneration:
- the Secret exists without its key, or holds a value other than the one the live backend copied (its
  pod template carries the value's checksum);
- the selected Secret, generated or operator-managed, is gone while the release's live backend depends
  on a KEK (its pod template names a KEK Secret or carries a KEK checksum), which is a lost Secret next
  to a retained database; rendering on would also drop the checksum that detects a wrong restore.
A live backend that names no KEK Secret has never had one, so the value is generated.

Canary rules. The capability carries no stored state: lookup reuses it, and a missing Secret or key
gets a new value.
*/}}
{{- define "cda.installationSecretValues" -}}
{{- include "cda.installationDefaults" . -}}
{{- if not (hasKey .Values "__installationSecretValues") -}}
{{- $values := dict -}}
{{- $kekName := include "cda.installationKekSecretName" . -}}
{{- $key := .Values.installation.kek.key -}}
{{- $backendName := printf "%s-backend" (include "cda.fullname" .) -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $kekName -}}
{{- $backend := lookup "apps/v1" "Deployment" .Release.Namespace $backendName -}}
{{- if $existing -}}
{{- $value := index ($existing.data | default dict) $key | default "" -}}
{{- if not $value -}}
{{- fail (printf "Secret %s exists without key %s. The installation KEK is never regenerated: restore the backed-up value into that key, or name an operator-managed Secret in installation.kek.existingSecret." $kekName $key) -}}
{{- end -}}
{{- $liveDigest := dig "spec" "template" "metadata" "annotations" "checksum/installation-kek" "" $backend -}}
{{- if and $liveDigest (ne (b64dec $value | sha256sum) $liveDigest) -}}
{{- fail (printf "Secret %s key %s does not match the KEK that backend %s copied. The database's installation credential is encrypted with that KEK: restore the backed-up value." $kekName $key $backendName) -}}
{{- end -}}
{{- $_ := set $values "kek" $value -}}
{{- else if or (dig "spec" "template" "metadata" "annotations" "noves.fi/installation-kek-secret" "" $backend) (dig "spec" "template" "metadata" "annotations" "checksum/installation-kek" "" $backend) -}}
{{- fail (printf "Secret %s is missing, but backend %s already uses an installation KEK. Generating a new KEK or dropping its checksum would leave the database's installation credential unusable or unguarded: restore the backed-up Secret %s." $kekName $backendName $kekName) -}}
{{- else if not .Values.installation.kek.existingSecret -}}
{{- $_ := set $values "kek" (randBytes 32 | b64enc) -}}
{{- $_ := set $values "kekGenerated" true -}}
{{- end -}}
{{- $canaryName := include "cda.installationCanarySecretName" . -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $canaryName -}}
{{- $value := "" -}}
{{- if $existing -}}
{{- $value = index ($existing.data | default dict) .Values.installation.canary.key | default "" -}}
{{- end -}}
{{- if not .Values.installation.canary.existingSecret -}}
{{- $value = $value | default (randBytes 32 | b64enc) -}}
{{- end -}}
{{- if $value -}}
{{- $_ := set $values "canary" $value -}}
{{- end -}}
{{- $_ := set .Values "__installationSecretValues" $values -}}
{{- end -}}
{{- toYaml (get .Values "__installationSecretValues") -}}
{{- end -}}

{{/*
Announced in NOTES.txt: a new KEK is correct for a new installation, but on a reused database it means
the retained KEK was not found, typically after renaming the release or changing fullnameOverride. The
backend then refuses to start until the original KEK is restored, so the operator is told at once.
*/}}
{{- define "cda.installationKekNotice" -}}
{{- if (include "cda.installationSecretValues" . | fromYaml).kekGenerated -}}
WARNING: this release generated a new installation KEK in Secret {{ include "cda.installationKekSecretName" . }}.
Back it up with the database. If this release reuses an existing database (for example after renaming
the release or changing fullnameOverride), the backend refuses to start with this KEK. Recover with the
original KEK, as described in "Recover from a KEK generated by mistake" in docs/helm.md:
  1. Set installation.kek.existingSecret to the retained KEK Secret (or recreate it from the backup).
  2. Using the same kubectl context and namespace as the helm command:
     kubectl --context "${KUBE_CONTEXT:?set KUBE_CONTEXT to the exact context the helm command used}" --namespace "${NAMESPACE:?set NAMESPACE to the exact namespace the helm command used ({{ .Release.Namespace }})}" delete deployment {{ include "cda.fullname" . }}-backend
     (its pod template records this new KEK, so the chart refuses the switch until it is gone).
  3. Run the same helm upgrade again, then confirm the backend becomes ready.
  4. Delete Secret {{ include "cda.installationKekSecretName" . }} once the backend is healthy.
{{- end -}}
{{- end -}}

{{/*
Init-container script that turns projected installation secrets into owner-only files.

A projected Secret file is owned by root, so a non-root container can read it only through group or
other permission bits; it cannot be both 0600 and readable by the runtime uid. The projection is 0444
so it does not depend on the pod's fsGroup, and only this init container mounts it. The init container runs
with the main container's security context, so the copy it writes into the in-memory emptyDir is owned
by exactly the uid that reads it, and the script proves that before the pod starts. The format check
makes every consumer see the same 44-character base64 text of 32 bytes, and a malformed operator
Secret stops the pod instead of reaching the backend. Argument: the list of file names to copy.
*/}}
{{- define "cda.installationSecretCopyScript" -}}
set -eu
umask 077
for name in {{ join " " . }}; do
  source="/installation-secret-sources/$name"
  target="/installation-secrets/$name"
  if [ ! -f "$source" ]; then
    echo "Installation secret $name is missing from its Secret." >&2
    exit 1
  fi
  if [ "$(wc -c <"$source" | tr -d ' ')" != 44 ] || ! grep -Eqx '[A-Za-z0-9+/]{43}=' "$source"; then
    echo "Installation secret $name must be the base64 encoding of 32 bytes: 44 characters and no newline." >&2
    exit 1
  fi
  cp "$source" "$target.tmp"
  chmod 0600 "$target.tmp"
  mv -f "$target.tmp" "$target"
  if [ "$(stat -c '%u %a' "$target")" != "$(id -u) 600" ]; then
    echo "Installation secret $name is not owner-only for uid $(id -u)." >&2
    exit 1
  fi
done
{{- end -}}
