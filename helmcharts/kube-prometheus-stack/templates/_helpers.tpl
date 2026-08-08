{{/*
Dynamic alert "service" label: workload identity, not Prometheus scrape metadata (job/service/instance).
*/}}
{{- define "kube-prometheus-stack.alertServiceLabel" -}}
{{`{{ if $labels.workload }}{{ $labels.workload }}{{ else if $labels.deployment }}{{ $labels.deployment }}{{ else if $labels.statefulset }}{{ $labels.statefulset }}{{ else if $labels.daemonset }}{{ $labels.daemonset }}{{ else if $labels.owner_name }}{{ $labels.owner_name }}{{ else if $labels.pod }}{{ $labels.pod }}{{ else if $labels.name }}{{ $labels.name }}{{ else if $labels.node }}{{ $labels.node }}{{ else if $labels.persistentvolumeclaim }}{{ $labels.persistentvolumeclaim }}{{ else if $labels.namespace }}{{ $labels.namespace }}{{ else }}unknown{{ end }}`}}
{{- end -}}

{{/*
Pod owners with workload label (deployment/sts/ds name). Excludes Job owners by design.
*/}}
{{- define "kube-prometheus-stack.podWorkloadOwners" }}
label_replace(
  kube_pod_owner{owner_kind="Deployment"},
  "workload", "$1", "owner_name", "(.+)"
)
or label_replace(
  kube_pod_owner{owner_kind="StatefulSet"},
  "workload", "$1", "owner_name", "(.+)"
)
or label_replace(
  kube_pod_owner{owner_kind="DaemonSet"},
  "workload", "$1", "owner_name", "(.+)"
)
or (
  kube_pod_owner{owner_kind="ReplicaSet"}
  * on (namespace, owner_name) group_left (workload)
    label_replace(
      label_replace(
        kube_replicaset_owner{owner_kind="Deployment"},
        "workload", "$1", "owner_name", "(.+)"
      ),
      "owner_name", "$1", "replicaset", "(.+)"
    )
)
{{- end }}

{{/*
Upstream-style pod owner join: exclude Job-owned pods, one owner series per pod (topk), attach workload.
Matches kube-prometheus-stack kubernetes-apps KubePodNotReady pattern + workload label for Alarmify routing.
*/}}
{{- define "kube-prometheus-stack.podOwnerFilterJoin" }}
* on (namespace, pod, cluster) group_left (owner_kind, owner_name, workload)
  topk by (namespace, pod, cluster) (
    1,
    max by (namespace, pod, owner_kind, owner_name, cluster) (
      (
        {{- include "kube-prometheus-stack.podWorkloadOwners" . | nindent 8 }}
      )
      or kube_pod_owner{owner_kind!~"Job|Deployment|StatefulSet|DaemonSet|ReplicaSet"}
    )
  )
{{- end }}
