# new-app

Scaffold a new ArgoCD-managed application in this repo. Creates the Helm chart, ApplicationSet, CoreDNS entry, and cluster secret label in one pass.

## Usage

```
/new-app <app-name> <team> <hostname> <container-port> [component-type]
```

**Arguments** (space-separated, positional):
1. `app-name` — kebab-case app name, e.g. `staypingo-admin-ui`
2. `team` — the team/product namespace prefix, e.g. `staypingo`
3. `hostname` — the `.home.arpa` hostname for the HTTPRoute, e.g. `admin-ui.staypingo.home.arpa`
4. `container-port` — port the container listens on, e.g. `3000` for UI, `8080` for API
5. `component-type` *(optional)* — `ui` or `api` (default: derived from app-name suffix)

---

## What this skill does

Given `$ARGUMENTS`, parse the positional args and perform ALL of the following steps in order. Do not skip any step.

### Step 1 — Determine values

From the arguments:
- `APP_NAME` = arg 1
- `TEAM` = arg 2
- `HOSTNAME` = arg 3
- `CONTAINER_PORT` = arg 4
- `COMPONENT` = arg 5 if provided, else infer from `APP_NAME` suffix (`-ui` → `ui`, `-api` → `api`, otherwise `app`)
- `IMAGE_REPO` = `harbor.workquark.org/${TEAM}/${APP_NAME}`
- `REGISTRY_SECRET_NAME` = `${APP_NAME}-registry`
- `CONFIGMAP_NAME` = `${APP_NAME}-config`
- `CHART_PATH` = `helmcharts/${TEAM}/${APP_NAME}`
- `APPLICATIONSET_PATH` = `helmcharts/argocd-apps/templates/applicationsets/${APP_NAME}-as.yaml`
- `SERVICE_PORT` = `80`

### Step 2 — Create the Helm chart

Create the following files, modelling them exactly on the existing `helmcharts/staypingo/staypingo-admin-api` chart:

**`${CHART_PATH}/Chart.yaml`**
```yaml
apiVersion: v2
name: <APP_NAME>
description: A Helm chart for the <APP_NAME> application
type: application
version: 0.1.0
appVersion: "v0.0.1"
```

**`${CHART_PATH}/values.yaml`**
- `image.repository`: `<IMAGE_REPO>`
- `image.tag`: `v0.0.1`
- `image.pullPolicy`: `IfNotPresent`
- `replicas`: `1`
- `containerPort`: `<CONTAINER_PORT>`
- `servicePort`: `80`
- `environment`: `prod`
- `imagePullSecrets[0].name`: `<REGISTRY_SECRET_NAME>`
- `config`: empty map `{}` (placeholder for env vars; prompt user to add any needed keys)
- `envFromSecrets`: commented out with example `- <APP_NAME>-vars`
- `resources`: requests `cpu: 100m, memory: 128Mi`; limits `cpu: "1", memory: 512Mi`
- `externalSecrets.secretStore`: `vault-secretstore`
- `externalSecrets.registryCredentialKey`: `harbor/staypingo-registry-credential`
- `httproute.hostname`: `<HOSTNAME>`
- `httproute.path`: `/`
- `httproute.gatewayName`: `default`
- `httproute.gatewayNamespace`: `envoy-gateway-system`
- `httproute.gatewayListener`: `http`

**`${CHART_PATH}/templates/deployment.yaml`**

Use the staypingo-admin-api deployment as the exact template, replacing:
- All occurrences of `staypingo-admin-api` → `<APP_NAME>`
- `app.kubernetes.io/component: api` → `app.kubernetes.io/component: <COMPONENT>`
- Container name `api` → `<COMPONENT>`

The `envFrom` block must unconditionally mount the configmap first, then range over `envFromSecrets`:
```yaml
envFrom:
  - configMapRef:
      name: {{ .Release.Name }}-config
  {{- range .Values.envFromSecrets }}
  - secretRef:
      name: {{ . }}
  {{- end }}
```

**`${CHART_PATH}/templates/service.yaml`**

Mirror staypingo-admin-api service, replacing `staypingo-admin-api` → `<APP_NAME>` and component label → `<COMPONENT>`.

**`${CHART_PATH}/templates/httproute.yaml`**

Mirror staypingo-admin-api httproute, replacing `staypingo-admin-api` → `<APP_NAME>` and component label → `httproute`.

**`${CHART_PATH}/templates/configmap.yaml`**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/name: <APP_NAME>
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: <COMPONENT>
    app.kubernetes.io/managed-by: Helm
data:
  {{- range $key, $value := .Values.config }}
  {{ $key }}: {{ $value | quote }}
  {{- end }}
```

**`${CHART_PATH}/templates/harbor-registry-external-secret.yaml`**

Mirror staypingo-admin-api external secret, replacing all `staypingo-admin-api` references → `<APP_NAME>` and target secret name → `<REGISTRY_SECRET_NAME>`.

### Step 3 — Create the ApplicationSet

Create `${APPLICATIONSET_PATH}` mirroring `helmcharts/argocd-apps/templates/applicationsets/staypingo-admin-api-as.yaml` exactly, replacing:
- All `staypingo-admin-api` references → `<APP_NAME>`
- `path: helmcharts/staypingo/staypingo-admin-api` → `path: <CHART_PATH>`
- Cluster selector labels: `<APP_NAME>-dev: "true"` (dev) and `<APP_NAME>: "true"` (prod)
- Namespace: `<APP_NAME>`

### Step 4 — Add CoreDNS entry

Read `helmcharts/argocd/templates/kube-system/core-dns-cofigmap.yaml` and add:
```
            192.168.3.10 <HOSTNAME>
```
Insert it immediately before the `fallthrough` line in the `home.arpa:53` hosts block.

### Step 5 — Add cluster label

Read `helmcharts/argocd/templates/cluster/local-cluster-secret.yaml` and add:
```yaml
    <APP_NAME>: "true"
```
Insert it on the line immediately after the last `staypingo-*` label entry in the `# Staypingo apps` section. If the team is not `staypingo`, find or create the appropriate `# <TEAM> apps` section comment and add it there.

### Step 6 — Report

After all files are created/updated, print a summary table:

| File | Action |
|------|--------|
| `${CHART_PATH}/Chart.yaml` | Created |
| `${CHART_PATH}/values.yaml` | Created |
| `${CHART_PATH}/templates/deployment.yaml` | Created |
| `${CHART_PATH}/templates/service.yaml` | Created |
| `${CHART_PATH}/templates/httproute.yaml` | Created |
| `${CHART_PATH}/templates/configmap.yaml` | Created |
| `${CHART_PATH}/templates/harbor-registry-external-secret.yaml` | Created |
| `${APPLICATIONSET_PATH}` | Created |
| `helmcharts/argocd/templates/kube-system/core-dns-cofigmap.yaml` | Updated |
| `helmcharts/argocd/templates/cluster/local-cluster-secret.yaml` | Updated |

Then remind the user of any manual follow-up steps:
- Add any app-specific env vars under `config:` in `values.yaml`
- If secrets are needed, uncomment `envFromSecrets` and create the corresponding Vault secret
- The Harbor image `<IMAGE_REPO>:<TAG>` must exist in the registry before syncing
