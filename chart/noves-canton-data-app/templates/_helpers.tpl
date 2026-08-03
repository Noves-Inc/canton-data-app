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
