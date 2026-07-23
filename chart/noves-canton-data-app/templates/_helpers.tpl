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

{{- define "cda.validate" -}}
{{- if and .Values.routing.istio.enabled .Values.routing.ingress.enabled -}}
{{- fail "routing.istio.enabled and routing.ingress.enabled are mutually exclusive" -}}
{{- end -}}
{{- if and .Values.routing.enabled (not (or .Values.routing.istio.enabled .Values.routing.ingress.enabled)) -}}
{{- fail "routing.enabled requires exactly one of routing.istio.enabled or routing.ingress.enabled" -}}
{{- end -}}
{{- if and .Values.routing.enabled (not .Values.routing.host) -}}
{{- fail "routing.host is required when routing.enabled=true" -}}
{{- end -}}
{{- if and .Values.setupWizard.enabled .Values.routing.enabled -}}
{{- fail "public routing is disabled while setupWizard is active; use localhost port-forwarding" -}}
{{- end -}}
{{- range $name, $workload := dict "backend" .Values.backend "frontend" .Values.frontend "database" .Values.database -}}
{{- if not (or (eq $workload.image.tag "latest") (regexMatch "^4\\." $workload.image.tag)) -}}
{{- fail (printf "%s.image.tag must be a v4 image tag or latest within the v4 repository" $name) -}}
{{- end -}}
{{- end -}}
{{- if .Values.migration.enabled -}}
{{- if ne .Values.migration.sourceVersion "3.16.1" -}}
{{- fail "migration requires an existing Data App v3.16.1 installation" -}}
{{- end -}}
{{- if not .Values.migration.backupConfirmed -}}
{{- fail "migration requires backupConfirmed=true for the Data App v3.16.1 database" -}}
{{- end -}}
{{- if not .Values.migration.oldWorkloadStopped -}}
{{- fail "migration requires oldWorkloadStopped=true for Data App v3.16.1" -}}
{{- end -}}
{{- if not .Values.migration.existingClaim -}}
{{- fail "migration requires migration.existingClaim" -}}
{{- end -}}
{{- end -}}
{{- if not .Values.setupWizard.enabled -}}
{{- if not (or (eq .Values.oidc.provider "auth0") (eq .Values.oidc.provider "keycloak")) -}}
{{- fail "oidc.provider must be auth0 or keycloak when setupWizard.enabled=false" -}}
{{- end -}}
{{- if not .Values.oidc.appUrl -}}
{{- fail "oidc.appUrl is required when setupWizard.enabled=false" -}}
{{- end -}}
{{- if and (eq .Values.oidc.provider "auth0") (or (not .Values.oidc.auth0.domain) (not .Values.oidc.auth0.clientId) (not .Values.oidc.auth0.audience)) -}}
{{- fail "oidc.auth0.domain, oidc.auth0.clientId, and oidc.auth0.audience are required for Auth0" -}}
{{- end -}}
{{- if and (eq .Values.oidc.provider "keycloak") (or (not .Values.oidc.keycloak.url) (not .Values.oidc.keycloak.realm) (not .Values.oidc.keycloak.clientId)) -}}
{{- fail "oidc.keycloak.url, oidc.keycloak.realm, and oidc.keycloak.clientId are required for Keycloak" -}}
{{- end -}}
{{- if not .Values.canton.expectedParticipantId -}}
{{- fail "canton.expectedParticipantId is required when setupWizard.enabled=false" -}}
{{- end -}}
{{- if not .Values.capture.existingSecret -}}
{{- fail "capture.existingSecret is required when setupWizard.enabled=false" -}}
{{- end -}}
{{- end -}}
{{- if not .Values.database.existingSecret -}}
{{- fail "database.existingSecret is required" -}}
{{- end -}}
{{- end -}}
