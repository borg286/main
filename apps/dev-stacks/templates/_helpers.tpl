{{- define "code-server.fullname" -}}
{{- printf "%s-code-server" .name -}}
{{- end -}}

{{- define "code-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "code-server.fullname" . }}
{{- end -}}
