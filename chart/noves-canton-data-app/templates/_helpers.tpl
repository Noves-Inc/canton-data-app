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
{{- if not .Values.canton.expectedParticipantId -}}
{{- fail "canton.expectedParticipantId is required" -}}
{{- end -}}
{{- if not .Values.capture.existingSecret -}}
{{- fail "capture.existingSecret is required" -}}
{{- end -}}
{{- if not .Values.database.existingSecret -}}
{{- fail "database.existingSecret is required" -}}
{{- end -}}
{{- if not .Values.novesGateway.existingSecret -}}
{{- fail "novesGateway.existingSecret is required" -}}
{{- end -}}
{{- if not .Values.novesGateway.tokenKey -}}
{{- fail "novesGateway.tokenKey is required" -}}
{{- end -}}
{{- range $field, $value := dict
  "capture.ledgerApiUserKey" .Values.capture.ledgerApiUserKey
  "capture.tokenEndpointKey" .Values.capture.tokenEndpointKey
  "capture.clientIdKey" .Values.capture.clientIdKey
  "capture.clientSecretKey" .Values.capture.clientSecretKey
  "capture.audienceKey" .Values.capture.audienceKey
  "capture.scopeKey" .Values.capture.scopeKey
-}}
{{- if not $value -}}
{{- fail (printf "%s is required" $field) -}}
{{- end -}}
{{- end -}}
{{- end -}}
