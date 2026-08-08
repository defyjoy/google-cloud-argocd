# scripts/

Shell logic behind `Taskfile.yml`. Nothing here is meant to be run directly — every script is
invoked by a task, which supplies the environment variables it requires (most use
`"${VAR:?}"` and will refuse to run without them).

The folders mirror the `taskfiles/` split, so a task and the script it calls live in
correspondingly named places.

| Folder | Called from | Contents |
|---|---|---|
| `argocd/` | `taskfiles/argocd.yaml` | install/uninstall, admin password (get/reset/change), app-of-apps teardown, readiness wait, success banner |
| `cluster/` | `taskfiles/cluster.yaml`, `taskfiles/argocd.yaml` | prerequisite checks, Cilium install + wait, Gateway API and Prometheus Operator CRDs |
| `vault/` | `taskfiles/vault.yaml` | connectivity/check/init/unseal/status/health/login/cleanup, ESO token secret, bootstrap secret seeding |
| `helm/` | `Taskfile.yml`, `taskfiles/argocd.yaml` | repo hygiene — values-comment lint, chart dependency cleanup |
| `git-hooks/` | `task hooks:install` | versioned hooks symlinked into `.git/hooks` |

`helmcharts/vault/scripts/` is a **different**, chart-local set of scripts driven by
`helmcharts/vault/Taskfile.yml`. It is unrelated to this directory.

## Moving a script between folders

Three files resolve paths from their own location and break *silently* if their depth changes —
grep for these before moving anything:

```bash
scripts/vault/provision-vault-secrets.sh       REPO_ROOT="$SCRIPT_DIR/../.."
scripts/vault/hashicorp-vault-create-secret.sh REPO_ROOT=".../../.."
scripts/helm/values-comments.py                REPO = Path(__file__).resolve().parent.parent.parent
```

The Python one is the dangerous case: a wrong root makes its `rglob` over `helmcharts/` match
nothing, so `task lint:values` passes vacuously and looks exactly like a clean repo. After any
move, prove the linter still sees files rather than trusting a green run:

```bash
mkdir -p helmcharts/_probe && printf 'foo: bar  # x\n' > helmcharts/_probe/values.yaml
task lint:values   # MUST fail
rm -rf helmcharts/_probe
```

Callers use `{{.REPO_ROOT}}/scripts/<folder>/<name>.sh`, except `install-argocd.sh`, which is
invoked through the `ARGOCD_SCRIPTS_DIR` variable in `taskfiles/argocd.yaml` — a plain grep for
its path will not find the call site.
