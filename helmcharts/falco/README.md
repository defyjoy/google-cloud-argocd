# falco

Runtime security monitoring — watches syscalls for suspicious container behaviour.

- Upstream chart: `falco`
- Runs as a DaemonSet on every node

---

## Configuration

### Driver

```yaml
falco:
  driver:
    enabled: true
    kind: ebpf
```

**eBPF driver**, not the kernel module — no out-of-tree module to compile or maintain per
kernel upgrade.

### Security contexts

```yaml
falco:
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    readOnlyRootFilesystem: false
    runAsNonRoot: true
    privileged: false
    seccompProfile:
      type: RuntimeDefault
```

Deliberately **unprivileged**, which the eBPF driver makes possible.
`readOnlyRootFilesystem` is left `false` — Falco writes to its own runtime paths.

### Resources

```yaml
falco:
  resources:
    requests: { memory: 256Mi, cpu: 100m }
    limits:   { memory: 512Mi, cpu: 200m }
```

### Rules

```yaml
falco:
  config:
    rulesFile:
      - /etc/falco/falco_rules.yaml
      - /etc/falco/falco_rules.local.yaml
```

Upstream rules plus a local override file, in that order — later files win, so
`falco_rules.local.yaml` is where cluster-specific exceptions belong.
