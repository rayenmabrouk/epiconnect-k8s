{{/*
Shared snippets. Everything the raw manifests repeated (image reference,
security contexts, secret environment) is defined once here.
*/}}

{{/* Base name for the release's objects: the release name ("epiconnect"). */}}
{{- define "epiconnect.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels on every object (metadata only, never in selectors: selectors are immutable). */}}
{{- define "epiconnect.labels" -}}
app.kubernetes.io/part-of: epiconnect
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Selector of the web pods. Must never change after the first install. */}}
{{- define "epiconnect.webSelector" -}}
app.kubernetes.io/name: epiconnect
app.kubernetes.io/component: web
{{- end -}}

{{/* Application image: values.image.tag, or the chart's appVersion. */}}
{{- define "epiconnect.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}

{{/* Pod security context. Call with (dict "uid" <n> "fsGroup" <bool>). */}}
{{- define "epiconnect.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .uid }}
{{- if .fsGroup }}
fsGroup: {{ .uid }}
{{- end }}
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/* Container security context: satisfies Pod Security "restricted". */}}
{{- define "epiconnect.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}

{{/* Configuration and secrets every application container needs. */}}
{{- define "epiconnect.appEnvFrom" -}}
- configMapRef:
    name: {{ include "epiconnect.fullname" . }}-config
{{- end -}}

{{- define "epiconnect.appSecretEnv" -}}
- name: SECRET_KEY
  valueFrom:
    secretKeyRef: {name: {{ .Values.existingSecret }}, key: django-secret-key}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef: {name: {{ .Values.existingSecret }}, key: db-password}
{{- end -}}
