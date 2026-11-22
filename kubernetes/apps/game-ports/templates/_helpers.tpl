{{/*
Every public port, one per line: the pools' ports plus the canary's. The
gateway's entrypoints and the Tailscale Service's ports both come from this.
*/}}
{{- define "game-ports.ports" -}}
{{- range .Values.pools }}
{{- $from := int .from }}
{{- range $i := until (int (add1 (sub (int .to) $from))) }}
{{ add $from $i }}
{{- end }}
{{- end }}
{{ int .Values.canary.port }}
{{- end }}

{{/* The controller's configuration (images/game-ports/game_ports.py). */}}
{{- define "game-ports.config" -}}
{{- $canary := dict "hostname" .Values.canary.hostname "port" .Values.canary.port }}
{{- dict "namespace" .Values.gamesNamespace "poolLabel" .Values.poolLabel "routeNamespace" .Release.Namespace "routeConfigMap" "game-ports-routes" "metricsPort" .Values.controller.metricsPort "canary" $canary | toJson }}
{{- end }}
