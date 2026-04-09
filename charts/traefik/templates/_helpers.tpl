{{- define "certificateName" -}}
{{- $s := . | lower -}}
{{- $s = regexReplaceAll "\\*" $s "wildcard" -}}
{{- $s = regexReplaceAll "[^a-z0-9-]" $s "-" -}}
{{- $s -}}
{{- end -}}
