{{- define "hostname" -}}
{{- $tenant := .name | replace " " "-" | lower -}}
{{- $environmentPrefix := .environmentPrefix | replace " " "-" | lower -}}
{{- printf "%s.%s.fluxdojo.local" $tenant $environmentPrefix -}}
{{- end -}}

{{- define "certificateName" -}}
{{- $s := . | lower -}}
{{- $s = regexReplaceAll "\\*" $s "wildcard" -}}
{{- $s = regexReplaceAll "[^a-z0-9-]" $s "-" -}}
{{- $s -}}
{{- end -}}

{{/*
Common labels for all resources in this chart
*/}}
{{- define "common.labels" -}}
platform.fluxdojo.local/part-of: idp
platform.fluxdojo.local/component: tenant-gateway
{{- end }}

{{- define "projectDisplayName" }}
{{- .name | abbrev 20 | replace "-" " " | title }}
{{- end }}

{{/* Returns the GitHub organization where tenant deploy repositories are created */}}
{{- define "deploy.githubOrg" -}}
jysk-kubernetes
{{- end -}}

{{/* Builds the repository name for a tenant (platform-deploy-<tenant>) */}}
{{- define "tenant.repoName" -}}
platform-deploy-{{ . | lower }}
{{- end -}}

{{/* Builds the full GitHub repository URL for a tenant */}}
{{- define "tenant.repoURL" -}}
https://github.com/{{ include "deploy.githubOrg" $ }}/{{ include "tenant.repoName" . }}
{{- end -}}
