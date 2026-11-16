{{/*
Every public port, one per line: "<game> <port>", in slot order. The gateway's
entrypoints and the Tailscale Service's ports both come from this.
*/}}
{{- define "game-ports.ports" -}}
{{- range $name, $game := .Values.games }}
{{- range $i := until (int (mul $game.servers $game.portsPerServer)) }}
{{ $name }} {{ add $game.basePort $i }}
{{- end }}
{{- end }}
{{- end }}

{{/* The controller's configuration (images/game-ports/game_ports.py). */}}
{{- define "game-ports.config" -}}
{{- $canary := dict "name" .Values.canary.name "game" "game-ports-canary" "maxAgeHours" .Values.canary.maxAgeHours "settleSeconds" .Values.canary.settleSeconds }}
{{- dict "namespace" .Values.gamesNamespace "routeNamespace" .Release.Namespace "routeConfigMap" "game-ports-routes" "loadBalancerClass" .Values.loadBalancerClass "metricsPort" .Values.controller.metricsPort "canary" $canary "games" .Values.games | toJson }}
{{- end }}
