{{/*
Extract hostname for mDNS advertisement.
Prefers .local hostnames, falls back to first hostname.
Returns the hostname part before the first dot.

Usage:
{{- $hostname := include "gateway-route.mdnsHostname" .hostnames }}
*/}}
{{- define "gateway-route.mdnsHostname" -}}
{{- $selectedHostname := "" }}
{{- range . }}
  {{- if hasSuffix ".local" . }}
    {{- $selectedHostname = . }}
  {{- end }}
{{- end }}
{{- if not $selectedHostname }}
  {{- $selectedHostname = index . 0 }}
{{- end }}
{{- $hostnameParts := split "." $selectedHostname }}
{{- $hostnameParts._0 }}
{{- end }}

{{/* Resolve and validate access-class mappings and optional listener overrides.
Input: dict with root (chart context) and route (one routes entry).
Output: native HTTPRoute parentRefs as YAML.
*/}}
{{- define "gateway-route.parentRefs" -}}
{{- $root := .root -}}
{{- with .route -}}
{{- $access := required "gateway-route: every route needs access (admin or apps)" .access }}
{{- if not (has $access (list "admin" "apps")) }}
{{- fail "gateway-route: access must be admin or apps" }}
{{- end }}
{{- if hasKey . "parentRefs" }}
{{- fail "gateway-route: configure access and optional listeners, not parentRefs" }}
{{- end }}
{{- $gateway := get $root.Values.gateways $access }}
{{- if not $gateway }}{{- fail "gateway-route: missing access-class gateway mapping" }}{{- end }}
{{- $legacy := and (eq $gateway.name "traefik") (eq $gateway.namespace "traefik") }}
{{- if and (not $legacy) (or (ne $gateway.name (printf "traefik-%s" $access)) (ne $gateway.namespace (printf "traefik-%s" $access))) }}
{{- fail "gateway-route: gateway mapping must match its access class" }}
{{- end }}
{{- $listeners := $gateway.listeners }}
{{- if hasKey . "listeners" }}
{{- if eq $access "admin" }}{{- fail "gateway-route: admin listeners are controlled centrally" }}{{- end }}
{{- $listeners = .listeners }}
{{- end }}
{{- if or (not (kindIs "slice" $listeners)) (not $listeners) }}
{{- fail "gateway-route: listeners must be a nonempty list" }}
{{- end }}
{{- if ne (len $listeners) (len (uniq $listeners)) }}
{{- fail "gateway-route: listeners must not contain duplicates" }}
{{- end }}
{{- $parents := list }}
{{- range $listeners }}
{{- if and (eq $access "apps") (not (has . (list "web" "websecure" "edge"))) }}
{{- fail "gateway-route: invalid apps listener" }}
{{- end }}
{{- if and (eq $access "admin") (not $legacy) (ne . "admin") }}
{{- fail "gateway-route: admin mapping must use the admin listener" }}
{{- end }}
{{- if and $legacy (not (has . (list "web" "websecure" "edge"))) }}
{{- fail "gateway-route: invalid legacy listener" }}
{{- end }}
{{- $parents = append $parents (dict "name" $gateway.name "namespace" $gateway.namespace "sectionName" .) }}
{{- end }}
{{- if and (eq $access "admin") .mdns }}
{{- fail "gateway-route: admin routes must not advertise LAN access" }}
{{- end }}
{{- toYaml $parents -}}
{{- end -}}
{{- end -}}
