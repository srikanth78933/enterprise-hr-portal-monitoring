{{- define "beats.labels" -}}
app.kubernetes.io/part-of: monitoring
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Private IP / host name of the ELK EC2 instance (required) */}}
{{- define "beats.elkHost" -}}
{{ required "elk.host is required: the private IP of the ELK EC2 instance" .Values.elk.host }}
{{- end }}
