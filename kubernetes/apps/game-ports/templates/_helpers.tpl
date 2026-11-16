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
{{- dict "namespace" .Values.gamesNamespace "routeNamespace" .Release.Namespace "routeConfigMap" "game-ports-routes" "loadBalancerClass" .Values.loadBalancerClass "games" .Values.games | toJson }}
{{- end }}
