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
{{- /* One Secret may hold both values only when the operator manages it and keeps them under distinct
keys; a shared key would hand the KEK to the frontend, and a chart-generated Secret holds one key only. */ -}}
{{- if eq (include "cda.installationKekSecretName" .) (include "cda.installationCanarySecretName" .) -}}
{{- if or (eq .Values.installation.kek.key .Values.installation.canary.key) (not .Values.installation.kek.existingSecret) (not .Values.installation.canary.existingSecret) -}}
{{- fail "installation.kek and installation.canary must not share a Secret key, or a Secret the chart generates: the frontend would receive the KEK" -}}
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
Secrets the pods read the installation KEK and the canary capability from: the operator-managed
Secret when existingSecret is set, otherwise the one the chart generates.
*/}}
{{- define "cda.installationKekSecretName" -}}
{{- default (printf "%s-installation-kek" (include "cda.fullname" .)) .Values.installation.kek.existingSecret -}}
{{- end -}}

{{- define "cda.installationCanarySecretName" -}}
{{- default (printf "%s-installation-canary" (include "cda.fullname" .)) .Values.installation.canary.existingSecret -}}
{{- end -}}

{{/*
The Secret data values (base64 of the 44-character text) of the chart-generated installation Secrets,
as YAML with keys "kek" and "canary"; a key is absent when that Secret is operator-managed.

The value is computed once per render and memoized in .Values, so the Secret templates and the pod
checksum annotations all see the same random value; computing it per template would give each a
different one. The pod templates carry a checksum of each value, so a regenerated canary or a restored
KEK recreates the pods that copied the previous value.

KEK rules. The Secret is reused through lookup and is never replaced on its own initiative: a new value
on a database that already holds installation material leaves the backend unable to use its
credential. Two states are render failures instead of regeneration:
- the Secret exists without its key, or holds a value other than the one the live backend copied (its
  pod template carries the value's checksum);
- the Secret is gone while the release's live backend depends on a KEK (its pod template names the
  Secret), which is a lost Secret next to a retained database.
A live backend that names no KEK Secret has never had one, so the value is generated.

Canary rules. The capability carries no stored state: lookup reuses it, and a missing Secret or key
gets a new value.
*/}}
{{- define "cda.installationSecretValues" -}}
{{- if not (hasKey .Values "__installationSecretValues") -}}
{{- $values := dict -}}
{{- if not .Values.installation.kek.existingSecret -}}
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
{{- fail (printf "Secret %s does not match the KEK that backend %s copied. The database's installation credential is encrypted with that KEK: restore the backed-up value into Secret %s." $kekName $backendName $kekName) -}}
{{- end -}}
{{- $_ := set $values "kek" $value -}}
{{- else if dig "spec" "template" "metadata" "annotations" "noves.fi/installation-kek-secret" "" $backend -}}
{{- fail (printf "Secret %s is missing, but backend %s already uses an installation KEK. Generating a new KEK would leave the database's installation credential unusable: restore the backed-up Secret %s, or name an operator-managed Secret in installation.kek.existingSecret." $kekName $backendName $kekName) -}}
{{- else -}}
{{- $_ := set $values "kek" (randBytes 32 | b64enc) -}}
{{- end -}}
{{- end -}}
{{- if not .Values.installation.canary.existingSecret -}}
{{- $canaryName := include "cda.installationCanarySecretName" . -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $canaryName -}}
{{- $value := "" -}}
{{- if $existing -}}
{{- $value = index ($existing.data | default dict) .Values.installation.canary.key | default "" -}}
{{- end -}}
{{- $_ := set $values "canary" ($value | default (randBytes 32 | b64enc)) -}}
{{- end -}}
{{- $_ := set .Values "__installationSecretValues" $values -}}
{{- end -}}
{{- toYaml (get .Values "__installationSecretValues") -}}
{{- end -}}

{{/*
Init-container script that turns projected installation secrets into owner-only files.

A projected Secret file is owned by root, so a non-root container can read it only through group or
other permission bits; it cannot be both 0600 and readable by the runtime uid. The init container runs
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
