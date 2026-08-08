# forgejo-runner

Self-hosted CI runner for Forgejo.

- Upstream chart: `oci://codeberg.org/wrenix/helm-charts/forgejo-runner`
- All dependency settings nest under the dependency name (see `Chart.yaml`)

---

## Configuration

```yaml
forgejo-runner:
  enabled: true
  knownLastVersion: true
  replicaCount: 1
```

`knownLastVersion: true` is **required by upstream chart v0.7.x** — it acknowledges the chart's
maintenance notice, and the chart refuses to render without it.

### Runner registration

```yaml
forgejo-runner:
  runner:
    config:
      create: true
      existingInitSecret: forgejo-runner-init
      instance: ""
      name: ""
      token: ""
```

`create: true` runs a pre-install Job that registers the runner with the Forgejo instance and
writes the resulting `.runner` secret.

Registration credentials come from an existing Kubernetes Secret named `forgejo-runner-init`,
with keys `CONFIG_NAME`, `CONFIG_INSTANCE` and `CONFIG_TOKEN` (see the upstream chart's
`jobs.yaml`).

> 🔐 **Create that Secret outside GitOps** — e.g. via External Secrets. The inline
> `instance`/`name`/`token` fields are ignored whenever `existingInitSecret` is set, and are
> deliberately left empty so registration tokens are never stored in git.

### Privileged

```yaml
forgejo-runner:
  securityContext:
    privileged: true
```

> ⚠️ **This runner is privileged** — it executes arbitrary CI workloads and needs container
> runtime access. It is the one chart in this repo that deliberately opts out of the
> `restricted` PodSecurity posture applied everywhere else. Treat anything it can reach as
> exposed to CI jobs.

### Resources

```yaml
forgejo-runner:
  resources: {}
```

Deliberately unset — CI job resource needs vary too much to pin a useful default.
