{{/*
Resolve matchType - how the condition must hold across the evaluation window.

SigNoz has no separate Prometheus-style `for` field: a hold-down is expressed
as matchType "All the Time" (every sample in evalWindow must breach) over an
evalWindow equal to the duration you want held. So `for: 5m0s` compiles to
evalWindow 5m0s + matchType 2, which is what `for` means everywhere else.

Both spellings are accepted so existing alerts keep rendering, but setting
`for` alongside `evalWindow` or `matchType` is a contradiction rather than a
precedence puzzle, and fails the render.
*/}}
{{- define "signoz-alerts.matchTypeCode" -}}
{{- $alert := . -}}
{{- $hold := $alert.for -}}
{{- if $hold -}}
  {{- if $alert.evalWindow }}{{ fail (printf "Alert '%s' sets both `for` and `evalWindow`. `for` is the hold-down and already sets the window; drop `evalWindow`." $alert.name) }}{{ end -}}
  {{- if $alert.matchType }}{{ fail (printf "Alert '%s' sets both `for` and `matchType`. `for` implies matchType all_the_times; use one or the other." $alert.name) }}{{ end -}}
2
{{- else -}}
{{- $m := $alert.matchType | default "at_least_once" | toString -}}
{{- if eq $m "at_least_once" }}1
{{- else if eq $m "all_the_times" }}2
{{- else if eq $m "on_average" }}3
{{- else if eq $m "in_total" }}4
{{- else if eq $m "last" }}5
{{- else if regexMatch "^[1-5]$" $m }}{{ $m }}
{{- else }}{{ fail (printf "Alert '%s' has matchType '%s'. Use at_least_once, all_the_times, on_average, in_total, last (or 1-5)." $alert.name $m) }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The evaluation window. `for` sets it, because a hold-down of N is expressed as
"breaching at every sample across a window of N".
*/}}
{{- define "signoz-alerts.evalWindow" -}}
{{- $alert := .alert -}}
{{- $alert.for | default $alert.evalWindow | default .root.Values.defaults.evalWindow -}}
{{- end -}}

{{/*
Map operator string to SigNoz op code
Only > and < are officially verified. For other operators, use type: promql
*/}}
{{- define "signoz-alerts.opCode" -}}
{{- $op := . -}}
{{- if eq $op ">" }}1
{{- else if eq $op "<" }}2
{{- else }}{{ fail (printf "Unsupported operator '%s'. Only '>' and '<' are supported. Use type: promql for custom operators." $op) }}
{{- end -}}
{{- end -}}

{{/*
Build groupBy array for builder queries
*/}}
{{- define "signoz-alerts.groupBy" -}}
{{- $groupBy := list -}}
{{- range . -}}
{{- $groupBy = append $groupBy (dict
    "name" .
    "signal" ""
    "fieldContext" "attribute"
    "fieldDataType" "string"
) -}}
{{- end -}}
{{- $groupBy | toJson -}}
{{- end -}}

{{/*
Build a single builder query
*/}}
{{- define "signoz-alerts.builderQuery" -}}
{{- $ctx := . -}}
{
  "type": "builder_query",
  "spec": {
    "name": {{ $ctx.name | quote }},
    "stepInterval": 0,
    "signal": "metrics",
    "source": "",
    "aggregations": [
      {
        "metricName": {{ $ctx.metric | quote }},
        "temporality": "",
        "timeAggregation": {{ $ctx.timeAggregation | default "avg" | quote }},
        "spaceAggregation": {{ $ctx.spaceAggregation | default "avg" | quote }},
        "reduceTo": ""
      }
    ],
    "disabled": {{ if $ctx.isFormula }}true{{ else }}false{{ end }},
    "filter": {
      "expression": {{ $ctx.filter | default "" | quote }}
    },
    "groupBy": {{ include "signoz-alerts.groupBy" $ctx.groupBy }},
    "having": {
      "expression": ""
    }
    {{- if $ctx.legend }},
    "legend": {{ $ctx.legend | quote }}
    {{- end }}
  }
}
{{- end -}}

{{/*
Build threshold condition (single metric)
*/}}
{{- define "signoz-alerts.thresholdCondition" -}}
{{- $alert := .alert -}}
{{- $querySpec := dict
    "name" "A"
    "metric" $alert.metric
    "timeAggregation" ($alert.timeAggregation | default "avg")
    "spaceAggregation" ($alert.spaceAggregation | default "avg")
    "filter" ($alert.filter | default "")
    "groupBy" $alert.groupBy
    "legend" ($alert.legend | default "")
    "isFormula" false
-}}
{
  "compositeQuery": {
    "queries": [
      {{ include "signoz-alerts.builderQuery" $querySpec }}
    ],
    "panelType": "graph",
    "queryType": "builder"
  },
  "op": "{{ include "signoz-alerts.opCode" $alert.op }}",
  "target": {{ $alert.threshold }},
  "matchType": {{ include "signoz-alerts.matchTypeCode" $alert | quote }},
  "selectedQueryName": "A"
}
{{- end -}}

{{/*
Build ratio condition (A/B formula)
*/}}
{{- define "signoz-alerts.ratioCondition" -}}
{{- $alert := .alert -}}
{{- $queryA := dict
    "name" "A"
    "metric" $alert.metrics.numerator
    "timeAggregation" ($alert.timeAggregation | default "avg")
    "spaceAggregation" ($alert.spaceAggregation | default "avg")
    "filter" ($alert.filter | default "")
    "groupBy" $alert.groupBy
    "isFormula" true
-}}
{{- $queryB := dict
    "name" "B"
    "metric" $alert.metrics.denominator
    "timeAggregation" ($alert.timeAggregation | default "avg")
    "spaceAggregation" ($alert.spaceAggregation | default "avg")
    "filter" ($alert.filter | default "")
    "groupBy" $alert.groupBy
    "isFormula" true
-}}
{{- $multiplier := $alert.multiply | default 1 -}}
{{- $expression := "(A/B)" -}}
{{- if ne $multiplier 1 -}}
{{- $expression = printf "(A/B)*%v" $multiplier -}}
{{- end -}}
{
  "compositeQuery": {
    "queries": [
      {{ include "signoz-alerts.builderQuery" $queryA }},
      {{ include "signoz-alerts.builderQuery" $queryB }},
      {
        "type": "builder_formula",
        "spec": {
          "name": "F1",
          "expression": {{ $expression | quote }},
          "legend": {{ $alert.legend | default (printf "{{%s}}" (index $alert.groupBy 0)) | quote }}
        }
      }
    ],
    "panelType": "graph",
    "queryType": "builder"
  },
  "op": "{{ include "signoz-alerts.opCode" $alert.op }}",
  "target": {{ $alert.threshold }},
  "matchType": {{ include "signoz-alerts.matchTypeCode" $alert | quote }},
  "selectedQueryName": "F1"
}
{{- end -}}

{{/*
Build PromQL condition
*/}}
{{- define "signoz-alerts.promqlCondition" -}}
{{- $alert := .alert -}}
{
  "compositeQuery": {
    "queries": [
      {
        "type": "promql",
        "spec": {
          "name": "A",
          "query": {{ $alert.query | quote }},
          "disabled": false,
          "step": 0,
          "stats": false,
          "legend": {{ $alert.legend | default "" | quote }}
        }
      }
    ],
    "panelType": "graph",
    "queryType": "promql"
  },
  "op": "{{ include "signoz-alerts.opCode" $alert.op }}",
  "target": {{ $alert.threshold }},
  "matchType": {{ include "signoz-alerts.matchTypeCode" $alert | quote }},
  "algorithm": "standard",
  "seasonality": "hourly",
  "selectedQueryName": "A"
}
{{- end -}}
