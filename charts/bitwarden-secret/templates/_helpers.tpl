{{/*
Detect if a value is a Bitwarden UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).
Returns "true" if UUID format, empty string otherwise.
Usage: {{ include "bitwarden-secret.isUUID" "0a3a525c-8a89-4513-ae77-b3f00030686f" }}
*/}}
{{- define "bitwarden-secret.isUUID" -}}
{{- if regexMatch "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" . -}}
true
{{- end -}}
{{- end -}}
