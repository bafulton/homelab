{{- define "game-server.name" -}}
{{- .Values.nameOverride | default .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "game-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "game-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
games.homelab.io/* labels go on every resource, so a portal can discover an
instance from its StatefulSet or its Services alike.
*/}}
{{- define "game-server.labels" -}}
{{ include "game-server.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
games.homelab.io/instance: {{ include "game-server.name" . }}
{{- with .Values.game }}
games.homelab.io/game: {{ . }}
{{- end }}
{{- end -}}

{{- define "game-server.annotations" -}}
{{- with .Values.uiUrl }}
games.homelab.io/ui-url: {{ . | quote }}
{{- end }}
{{- end -}}

{{- define "game-server.servicePorts" -}}
{{- range .Values.ports }}
- name: {{ .name }}
  port: {{ .port }}
  targetPort: {{ .targetPort | default .port }}
  protocol: {{ .protocol | default "TCP" }}
{{- end }}
{{- end -}}

{{- define "game-server.serviceSelector" -}}
{{- if .Values.service.selector -}}
{{ toYaml .Values.service.selector }}
{{- else if .Values.workload.enabled -}}
{{ include "game-server.selectorLabels" . }}
{{- else -}}
{{ fail "workload.enabled is false: set service.selector to match the pods this chart's Services should reach" }}
{{- end -}}
{{- end -}}

{{- define "game-server.validate" -}}
{{- $names := dict -}}
{{- range .Values.ports -}}
{{- if not (and .name .port) -}}
{{ fail "every entry in ports needs a name and a port" }}
{{- end -}}
{{- if gt (len .name) 15 -}}
{{ fail (printf "port name %q is longer than 15 characters" .name) }}
{{- end -}}
{{- if hasKey $names .name -}}
{{ fail (printf "port name %q appears twice in ports" .name) }}
{{- end -}}
{{- $_ := set $names .name true -}}
{{- if not (has (.protocol | default "TCP") (list "TCP" "UDP")) -}}
{{ fail (printf "port %q: protocol must be TCP or UDP" .name) }}
{{- end -}}
{{- end -}}
{{- if and .Values.workload.enabled (gt (int .Values.workload.replicas) 1) -}}
{{ fail "workload.replicas must be 0 or 1: a game server has one writer" }}
{{- end -}}
{{- if and .Values.lan.enabled (not .Values.lan.loadBalancerIP) -}}
{{ fail "lan.enabled needs lan.loadBalancerIP, a free address in the MetalLB pool" }}
{{- end -}}
{{- end -}}
