{{/*
wrapper.nats.fullname mirrors the upstream nats subchart's "nats.fullname" logic
using dependency values nested under .Values.nats (umbrella chart).
Used so PVC names match the claimName rendered inside the subchart.
*/}}
{{- define "wrapper.nats.fullname" -}}
{{- $vals := index .Values "nats" }}
{{- if $vals.fullnameOverride }}
{{- $vals.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "nats" $vals.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
wrapper.nats.authUsersSecretName is the Secret holding the NATS include file (wrapper chart).
*/}}
{{- define "wrapper.nats.authUsersSecretName" -}}
{{- if .Values.nats.authUsers.existingSecret }}
{{- .Values.nats.authUsers.existingSecret }}
{{- else }}
{{- printf "%s-auth-users" (include "wrapper.nats.fullname" .) }}
{{- end }}
{{- end }}

{{/*
wrapper.nats.authUsersIncludeKey — key inside the Secret (stringData) for the JSON include fragment.
*/}}
{{- define "wrapper.nats.authUsersIncludeKey" -}}
{{- .Values.nats.authUsers.secret.includeKey | default "auth-users.inc" }}
{{- end }}

{{/*
wrapper.nats.authUsersJSON — JSON fragment merged via $include (authorization.users).
Per client:
  - publish-only: publishSubjects / subjectPattern / defaultSubjectPattern; optional publishDenySubjects.
    Optional subscribeAllowSubjects + subscribeDenySubjects (e.g. _INBOX for JS publish acks; deny $JS.API); if subscribeAllowSubjects is set and deny lists are empty, defaults deny "$JS.API.>" on publish and subscribe.
  - consume-only: use subscribeSubjects (list) -> permissions.subscribe.allow; else subjectPattern or default.
  - full: publish and subscribe on subjectPattern or defaultSubjectPattern (JetStream CLI, nats-box, ops); not for untrusted workloads.
*/}}
{{- define "wrapper.nats.authUsersJSON" -}}
{{- $auth := .Values.nats.authUsers }}
{{- $defSub := $auth.defaultSubjectPattern | default ">" }}
{{- $users := list }}
{{- range $c := $auth.clients }}
  {{- $perm := dict }}
  {{- if eq $c.mode "publish-only" }}
    {{- $pub := $defSub }}
    {{- $plist := $c.publishSubjects | default list }}
    {{- if kindIs "string" $c.publishSubjects }}
      {{- if ne $c.publishSubjects "" }}
        {{- $plist = list $c.publishSubjects }}
      {{- end }}
    {{- end }}
    {{- if and (kindIs "slice" $plist) (gt (len $plist) 0) }}
      {{- $pub = dict "allow" $plist }}
    {{- else if $c.subjectPattern }}
      {{- $pub = $c.subjectPattern }}
    {{- end }}
    {{- $pubObj := dict }}
    {{- if kindIs "map" $pub }}
      {{- $pubObj = deepCopy $pub }}
    {{- else }}
      {{- $pubObj = dict "allow" (list $pub) }}
    {{- end }}
    {{- $pdn := $c.publishDenySubjects | default list }}
    {{- if kindIs "string" $c.publishDenySubjects }}
      {{- if ne $c.publishDenySubjects "" }}
        {{- $pdn = list $c.publishDenySubjects }}
      {{- end }}
    {{- end }}
    {{- $salist := $c.subscribeAllowSubjects | default list }}
    {{- if kindIs "string" $c.subscribeAllowSubjects }}
      {{- if ne $c.subscribeAllowSubjects "" }}
        {{- $salist = list $c.subscribeAllowSubjects }}
      {{- end }}
    {{- end }}
    {{- if and (kindIs "slice" $salist) (gt (len $salist) 0) }}
      {{- if not (and (kindIs "slice" $pdn) (gt (len $pdn) 0)) }}
        {{- $pdn = list "$JS.API.>" }}
      {{- end }}
      {{- $_ := set $pubObj "deny" $pdn }}
      {{- $sdn := $c.subscribeDenySubjects | default list }}
      {{- if kindIs "string" $c.subscribeDenySubjects }}
        {{- if ne $c.subscribeDenySubjects "" }}
          {{- $sdn = list $c.subscribeDenySubjects }}
        {{- end }}
      {{- end }}
      {{- if not (and (kindIs "slice" $sdn) (gt (len $sdn) 0)) }}
        {{- $sdn = list "$JS.API.>" }}
      {{- end }}
      {{- $subObj := dict "allow" $salist "deny" $sdn }}
      {{- $perm = dict "publish" $pubObj "subscribe" $subObj }}
    {{- else }}
      {{- if and (kindIs "slice" $pdn) (gt (len $pdn) 0) }}
        {{- $_ := set $pubObj "deny" $pdn }}
      {{- end }}
      {{- $perm = dict "publish" $pubObj "subscribe" (dict "deny" ">") }}
    {{- end }}
  {{- else if eq $c.mode "consume-only" }}
    {{- $sub := $defSub }}
    {{- $slist := $c.subscribeSubjects | default list }}
    {{- if kindIs "string" $c.subscribeSubjects }}
      {{- if ne $c.subscribeSubjects "" }}
        {{- $slist = list $c.subscribeSubjects }}
      {{- end }}
    {{- end }}
    {{- if and (kindIs "slice" $slist) (gt (len $slist) 0) }}
      {{- $sub = dict "allow" $slist }}
    {{- else if $c.subjectPattern }}
      {{- $sub = $c.subjectPattern }}
    {{- end }}
    {{- $perm = dict "publish" (dict "deny" ">") "subscribe" $sub }}
  {{- else if eq $c.mode "full" }}
    {{- $pat := $defSub }}
    {{- if $c.subjectPattern }}
      {{- $pat = $c.subjectPattern }}
    {{- end }}
    {{- $perm = dict "publish" $pat "subscribe" $pat }}
  {{- else }}
    {{- fail (printf "nats.authUsers.clients: invalid mode %q for user %q (use publish-only, consume-only, or full)" $c.mode $c.user) }}
  {{- end }}
  {{- $users = append $users (dict "user" $c.user "password" $c.password "permissions" $perm) }}
{{- end }}
{{- dict "authorization" (dict "users" $users) | toRawJson }}
{{- end }}
