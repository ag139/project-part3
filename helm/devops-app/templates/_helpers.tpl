{{- define "devops-app.labels" -}}
app: devops-app
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
