{{/*
Resolve matchType - how the condition must hold across the evaluation window.

SigNoz has no separate Prometheus-style `for` field: a hold-down is expressed
as matchType "All the Time" (every sample in evalWindow must breach) over an
evalWindow equal to the duration you want held. So `for: 5m0s` compiles to
evalWindow 5m0s + matchType all_the_times, which is what `for` means
everywhere else.

Both spellings are accepted so existing alerts keep rendering, but setting
`for` alongside `evalWindow` or `matchType` is a contradiction rather than a
precedence puzzle, and fails the render.

Emits the v2alpha1 canonical name. Numeric 1-5 is still accepted as input for
back-compatibility with older values files and is translated here.
*/}}
{{- define "signoz-alerts.matchTypeName" -}}
{{- $alert := . -}}
{{- $hold := $alert.for -}}
{{- if $hold -}}
  {{- if $alert.evalWindow }}{{ fail (printf "Alert '%s' sets both `for` and `evalWindow`. `for` is the hold-down and already sets the window; drop `evalWindow`." $alert.name) }}{{ end -}}
  {{- if $alert.matchType }}{{ fail (printf "Alert '%s' sets both `for` and `matchType`. `for` implies matchType all_the_times; use one or the other." $alert.name) }}{{ end -}}
all_the_times
{{- else -}}
{{- $m := $alert.matchType | default "at_least_once" | toString -}}
{{- if eq $m "at_least_once" }}at_least_once
{{- else if eq $m "all_the_times" }}all_the_times
{{- else if eq $m "on_average" }}on_average
{{- else if eq $m "in_total" }}in_total
{{- else if eq $m "last" }}last
{{- else if eq $m "1" }}at_least_once
{{- else if eq $m "2" }}all_the_times
{{- else if eq $m "3" }}on_average
{{- else if eq $m "4" }}in_total
{{- else if eq $m "5" }}last
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
Map operator string to the v2alpha1 operator name.
Only > and < are officially verified. For other operators, use type: promql
*/}}
{{- define "signoz-alerts.opName" -}}
{{- $op := . -}}
{{- if eq $op ">" }}above
{{- else if eq $op "<" }}below
{{- else }}{{ fail (printf "Unsupported operator '%s'. Only '>' and '<' are supported. Use type: promql for custom operators." $op) }}
{{- end -}}
{{- end -}}

{{/*
The v2alpha1 thresholds block.

The threshold `name` is the routing tier AND the severity: alerts carry
threshold_name equal to it. Each rule here has exactly one threshold, so
labels.severity is kept alongside it (see configmap.yaml) - that is what the
email Subject template reads. If a rule ever grows a second threshold, drop
labels.severity so alerts stop carrying a single static value.
*/}}
{{- define "signoz-alerts.thresholds" -}}
{{- $alert := .alert -}}
{{- $defaults := .root.Values.defaults -}}
{
  "kind": "basic",
  "spec": [
    {
      "name": {{ $alert.severity | default $defaults.severity | quote }},
      "target": {{ $alert.threshold }},
      "op": {{ include "signoz-alerts.opName" $alert.op | quote }},
      "matchType": {{ include "signoz-alerts.matchTypeName" $alert | quote }},
      "channels": [{{ $defaults.notificationChannel | quote }}]
    }
  ]
}
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
  "selectedQueryName": "A",
  "thresholds": {{ include "signoz-alerts.thresholds" . | nindent 2 }}
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
  "selectedQueryName": "F1",
  "thresholds": {{ include "signoz-alerts.thresholds" . | nindent 2 }}
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
  "selectedQueryName": "A",
  "thresholds": {{ include "signoz-alerts.thresholds" . | nindent 2 }}
}
{{- end -}}
