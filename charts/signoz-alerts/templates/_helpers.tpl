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
    "stepInterval": {{ $ctx.stepInterval | default 60 }},
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
    "stepInterval" ($alert.stepInterval | default 60)
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
  "matchType": "1",
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
    "stepInterval" ($alert.stepInterval | default 60)
    "isFormula" true
-}}
{{- $queryB := dict
    "name" "B"
    "metric" $alert.metrics.denominator
    "timeAggregation" ($alert.timeAggregation | default "avg")
    "spaceAggregation" ($alert.spaceAggregation | default "avg")
    "filter" ($alert.filter | default "")
    "groupBy" $alert.groupBy
    "stepInterval" ($alert.stepInterval | default 60)
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
  "matchType": "1",
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
  "matchType": "1",
  "algorithm": "standard",
  "seasonality": "hourly",
  "selectedQueryName": "A"
}
{{- end -}}
