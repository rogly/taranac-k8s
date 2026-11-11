{{/*
Chart name.
*/}}
{{- define "taranac.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "taranac.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "taranac.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Takes (dict "root" $ "component" "<name>").
*/}}
{{- define "taranac.selectorLabels" -}}
app.kubernetes.io/name: {{ include "taranac.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Common labels. Takes (dict "root" $ "component" "<name>").
*/}}
{{- define "taranac.labels" -}}
helm.sh/chart: {{ include "taranac.chart" .root }}
{{ include "taranac.selectorLabels" . }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: taranac
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "taranac.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "taranac.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding the application keys.
*/}}
{{- define "taranac.secretName" -}}
{{- default (printf "%s-secrets" (include "taranac.fullname" .)) .Values.secrets.existingSecret }}
{{- end }}

{{/*
Name of the shared state PVC.
*/}}
{{- define "taranac.stateClaimName" -}}
{{- default (printf "%s-state" (include "taranac.fullname" .)) .Values.persistence.state.existingClaim }}
{{- end }}

{{/*
Image reference. Takes (dict "root" $ "image" <component image values>).
global.imageRegistry replaces the registry host of every repository.
*/}}
{{- define "taranac.image" -}}
{{- $repo := .image.repository }}
{{- with .root.Values.global.imageRegistry }}
{{- $repo = printf "%s/%s" (trimSuffix "/" .) (regexReplaceAll "^[^/]*[.:][^/]*/" $repo "") }}
{{- end }}
{{- if .image.digest }}
{{- printf "%s@%s" $repo .image.digest }}
{{- else }}
{{- printf "%s:%s" $repo (toString (default (default .root.Chart.AppVersion .root.Values.image.tag) .image.tag)) }}
{{- end }}
{{- end }}

{{/*
Fields shared by every Taranac container: image, pull policy, resources and
security context. Takes (dict "root" $ "c" <component values>).
*/}}
{{- define "taranac.container.common" -}}
image: {{ include "taranac.image" (dict "root" .root "image" .c.image) | quote }}
{{- with (default .root.Values.image.pullPolicy .c.image.pullPolicy) }}
imagePullPolicy: {{ . }}
{{- end }}
{{- with .c.extraEnvFrom }}
envFrom:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .c.resources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .c.securityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Pod spec fields shared by every workload. Takes (dict "root" $ "c" <component values>
["state" true if the pod mounts the state PVC] ["anchor" true for the core pod]).
*/}}
{{- define "taranac.pod.common" -}}
{{- with .root.Values.imagePullSecrets }}
imagePullSecrets:
  {{- range . }}
  - name: {{ . }}
  {{- end }}
{{- end }}
serviceAccountName: {{ include "taranac.serviceAccountName" .root }}
automountServiceAccountToken: {{ .root.Values.serviceAccount.automount }}
{{- with .c.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .c.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- with .c.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- /*
With a ReadWriteOnce state volume every pod that mounts it must run on the same
node: "state" pods (frontend, renderer) must follow the core pod, and the core
pod prefers the node they are on so restarts do not strand the volume.
*/ -}}
{{- $aff := deepCopy (default dict .c.affinity) }}
{{- if not (has "ReadWriteMany" .root.Values.persistence.state.accessModes) }}
{{- $pa := default dict $aff.podAffinity }}
{{- if .state }}
{{- $req := default list (index $pa "requiredDuringSchedulingIgnoredDuringExecution") }}
{{- $term := dict "topologyKey" "kubernetes.io/hostname" "labelSelector" (dict "matchLabels" (dict "app.kubernetes.io/name" (include "taranac.name" .root) "app.kubernetes.io/instance" .root.Release.Name "app.kubernetes.io/component" "core")) }}
{{- $_ := set $pa "requiredDuringSchedulingIgnoredDuringExecution" (append $req $term) }}
{{- $_ := set $aff "podAffinity" $pa }}
{{- else if .anchor }}
{{- $pref := default list (index $pa "preferredDuringSchedulingIgnoredDuringExecution") }}
{{- $term := dict "weight" 100 "podAffinityTerm" (dict "topologyKey" "kubernetes.io/hostname" "labelSelector" (dict "matchLabels" (dict "app.kubernetes.io/name" (include "taranac.name" .root) "app.kubernetes.io/instance" .root.Release.Name) "matchExpressions" (list (dict "key" "app.kubernetes.io/component" "operator" "In" "values" (list "frontend" "renderer"))))) }}
{{- $_ := set $pa "preferredDuringSchedulingIgnoredDuringExecution" (append $pref $term) }}
{{- $_ := set $aff "podAffinity" $pa }}
{{- end }}
{{- end }}
{{- with $aff }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .c.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .c.topologySpreadConstraints }}
topologySpreadConstraints:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Pod annotations. Takes (dict "root" $ "c" <component values>).
Provided secret values roll the pods on change; generated values never change.
*/}}
{{- define "taranac.pod.annotations" -}}
checksum/secrets: {{ toJson (dict "secrets" .root.Values.secrets "db" .root.Values.externalDatabase) | sha256sum }}
{{- with .c.podAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Keel annotations for the Kubernetes provider (workload metadata).
*/}}
{{- define "taranac.keel.annotations" -}}
{{- $k := .Values.keel }}
{{- if $k.enabled }}
keel.sh/policy: {{ $k.policy | quote }}
keel.sh/trigger: {{ $k.trigger | quote }}
{{- if eq $k.trigger "poll" }}
keel.sh/pollSchedule: {{ $k.pollSchedule | quote }}
{{- end }}
{{- if $k.matchTag }}
keel.sh/match-tag: "true"
{{- end }}
{{- if gt (int $k.approvals) 0 }}
keel.sh/approvals: {{ $k.approvals | quote }}
{{- with $k.approvalDeadline }}
keel.sh/approvalDeadline: {{ . | quote }}
{{- end }}
{{- end }}
{{- with $k.notify }}
keel.sh/notify: {{ . | quote }}
{{- end }}
{{- with $k.annotations }}
{{ toYaml . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Workload annotations (Keel + commonAnnotations). Emits nothing when empty.
*/}}
{{- define "taranac.workload.annotations" -}}
{{- $keel := include "taranac.keel.annotations" . | trim }}
{{- if or $keel .Values.commonAnnotations }}
annotations:
  {{- with $keel }}
  {{- . | nindent 2 }}
  {{- end }}
  {{- with .Values.commonAnnotations }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Cluster-internal FQDN of a Service. Takes (dict "root" $ "name" "<svc>").
*/}}
{{- define "taranac.fqdn" -}}
{{ .name }}.{{ .root.Release.Namespace }}.svc.{{ .root.Values.clusterDomain }}
{{- end }}

{{/*
Shell snippet that sets $NS to the DNS resolver nginx should use. The images
ship nginx configs pointing at Docker's 127.0.0.11; in Kubernetes the pod's own
resolv.conf already names the cluster DNS, so no Service CIDR needs configuring.
*/}}
{{- define "taranac.resolver.sh" -}}
NS={{ .Values.dnsResolver | quote }}
[ -n "$NS" ] || NS=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
case "$NS" in *:*) NS="[$NS]" ;; esac
{{- end }}

{{/* ---------------------------- database ---------------------------- */}}

{{/*
Fullname of the PostgreSQL subchart resources (mirrors the subchart's helper).
*/}}
{{- define "taranac.postgresql.fullname" -}}
{{- if .Values.postgresql.fullnameOverride }}
{{- .Values.postgresql.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "postgresql" .Values.postgresql.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "taranac.postgresql.host" -}}
{{- include "taranac.postgresql.fullname" . }}{{ if eq (default "standalone" .Values.postgresql.architecture) "replication" }}-primary{{ end }}
{{- end }}

{{- define "taranac.postgresql.port" -}}
{{- dig "primary" "service" "ports" "postgresql" 5432 .Values.postgresql | int }}
{{- end }}

{{/*
Fields parsed from externalDatabase.uri, as JSON (empty object when unset).
Only works for an inline URI; a URI held in a Secret cannot be parsed at render
time, so use externalDatabase.existingSecret with discrete keys instead.
*/}}
{{- define "taranac.db.parsed" -}}
{{- $out := dict }}
{{- with .Values.externalDatabase.uri }}
{{- $u := urlParse . }}
{{- $hp := splitList ":" (get $u "host") }}
{{- $_ := set $out "host" (first $hp) }}
{{- if gt (len $hp) 1 }}{{ $_ := set $out "port" (last $hp) }}{{ end }}
{{- $ui := splitn ":" 2 (default "" (get $u "userinfo")) }}
{{- if $ui._0 }}{{ $_ := set $out "user" $ui._0 }}{{ end }}
{{- if $ui._1 }}{{ $_ := set $out "password" $ui._1 }}{{ end }}
{{- $db := trimPrefix "/" (get $u "path") }}
{{- if $db }}{{ $_ := set $out "name" $db }}{{ end }}
{{- end }}
{{- toJson $out }}
{{- end }}

{{/*
POSTGRES_PASSWORD env var sourced from wherever the database password lives.
*/}}
{{- define "taranac.db.passwordEnv" -}}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if .Values.postgresql.enabled }}
      {{- $auth := .Values.postgresql.auth }}
      {{- if $auth.existingSecret }}
      name: {{ $auth.existingSecret }}
      key: {{ dig "secretKeys" "userPasswordKey" "password" $auth }}
      {{- else }}
      name: {{ include "taranac.postgresql.fullname" . }}
      key: password
      {{- end }}
      {{- else if .Values.externalDatabase.existingSecret }}
      name: {{ .Values.externalDatabase.existingSecret }}
      key: {{ default "password" .Values.externalDatabase.existingSecretKeys.password }}
      {{- else }}
      name: {{ include "taranac.secretName" . }}
      key: POSTGRES_PASSWORD
      {{- end }}
{{- end }}

{{/*
One connection-detail env var. Takes (dict "root" $ "env" "<ENV>" "field" "host|port|user|name"
"literal" "<value used with the subchart>" "default" "<fallback for external>").
External precedence: inline value (or URI) > ConfigMap key > Secret key > default.
*/}}
{{- define "taranac.db.field" -}}
- name: {{ .env }}
  {{- if .root.Values.postgresql.enabled }}
  value: {{ .literal | toString | quote }}
  {{- else }}
  {{- $ext := .root.Values.externalDatabase }}
  {{- $parsed := include "taranac.db.parsed" .root | fromJson }}
  {{- $inline := coalesce (get $ext .field) (get $parsed .field) }}
  {{- $cmKey := get $ext.existingConfigMapKeys .field }}
  {{- $secKey := get $ext.existingSecretKeys .field }}
  {{- if $inline }}
  value: {{ $inline | toString | quote }}
  {{- else if and $ext.existingConfigMap $cmKey }}
  valueFrom:
    configMapKeyRef:
      name: {{ $ext.existingConfigMap }}
      key: {{ $cmKey }}
  {{- else if and $ext.existingSecret $secKey }}
  valueFrom:
    secretKeyRef:
      name: {{ $ext.existingSecret }}
      key: {{ $secKey }}
  {{- else if .default }}
  value: {{ .default | toString | quote }}
  {{- else }}
  {{- fail (printf "externalDatabase.%s is required when postgresql.enabled=false (set it inline, via externalDatabase.uri, or map a key from existingConfigMap/existingSecret)" .field) }}
  {{- end }}
  {{- end }}
{{- end }}

{{/*
All database env vars. POSTGRES_PASSWORD and the K8S_DB_* vars are declared
first so that $(VAR) expansion in the connection URLs works.
*/}}
{{- define "taranac.db.env" -}}
{{- $ext := .Values.externalDatabase }}
{{- $fromRef := or $ext.existingConfigMap $ext.existingSecret }}
{{- include "taranac.db.passwordEnv" . }}
{{ include "taranac.db.field" (dict "root" . "env" "K8S_DB_HOST" "field" "host" "literal" (include "taranac.postgresql.host" .)) }}
{{ include "taranac.db.field" (dict "root" . "env" "K8S_DB_PORT" "field" "port" "literal" (include "taranac.postgresql.port" .) "default" "5432") }}
{{ include "taranac.db.field" (dict "root" . "env" "K8S_DB_USER" "field" "user" "literal" .Values.database.user "default" (ternary "" .Values.database.user (not (not $fromRef)))) }}
{{ include "taranac.db.field" (dict "root" . "env" "K8S_DB_NAME" "field" "name" "literal" .Values.database.name "default" (ternary "" .Values.database.name (not (not $fromRef)))) }}
{{- end }}

{{/*
Name of the MFA database.
*/}}
{{- define "taranac.db.mfaName" -}}
{{- if .Values.postgresql.enabled }}{{ .Values.database.mfaName }}{{ else }}{{ default .Values.database.mfaName .Values.externalDatabase.mfaName }}{{ end }}
{{- end }}

{{/*
Connection URL. Takes (dict "scheme" "postgresql" "db" "<name or $(K8S_DB_NAME)>").
*/}}
{{- define "taranac.db.url" -}}
{{ .scheme }}://$(K8S_DB_USER):$(POSTGRES_PASSWORD)@$(K8S_DB_HOST):$(K8S_DB_PORT)/{{ .db }}
{{- end }}

{{/*
A secretKeyRef env var from the application Secret. Takes (dict "root" $ "key" "<KEY>").
*/}}
{{- define "taranac.secretEnv" -}}
- name: {{ .key }}
  valueFrom:
    secretKeyRef:
      name: {{ include "taranac.secretName" .root }}
      key: {{ .key }}
{{- end }}

{{/*
Env-file rendering of the application keys, mounted at /app/host/env so the
api's backup/restore sees the secrets it would find in a Compose .env.
Takes the final key/value dict.
*/}}
{{- define "taranac.hostEnv" -}}
{{- range $k := list "MASTER_KEY" "SECRET_KEY" "EST_PROXY_KEY" "TARANAC_MFA_API_KEY" "REPORTS_RENDERER_API_KEY" }}
{{ $k }}={{ get $ $k }}
{{- end }}
{{- end }}

{{- define "taranac.dataClaimName" -}}
{{- default (printf "%s-data" (include "taranac.fullname" .)) .Values.persistence.data.existingClaim }}
{{- end }}

{{/*
Init container that waits until the core pod has minted files into the shared
certificate volume. Takes (dict "root" $ "c" <component values> "files" (list ...)).
*/}}
{{- define "taranac.waitForCerts" -}}
- name: wait-for-certs
  {{- include "taranac.container.common" (dict "root" .root "c" .c) | nindent 2 }}
  command:
    - /bin/sh
    - -c
    - |
      for f in {{ join " " .files }}; do
        until [ -s "/opt/taranac/certs/$f" ]; do
          echo "waiting for /opt/taranac/certs/$f"
          sleep 2
        done
      done
  volumeMounts:
    - name: taranac-certs
      mountPath: /opt/taranac/certs
      subPath: certs
      readOnly: true
{{- end }}
