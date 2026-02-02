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
