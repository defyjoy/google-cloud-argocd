# awx-operator

Ansible AWX operator — reconciles `AWX` custom resources into running AWX deployments. This
chart installs **only the operator**; AWX instances themselves are separate CRs.

---

## Configuration

```yaml
awx-operator:
  operator:
    replicas: 1
    image:
      repository: quay.io/ansible/awx-operator
      tag: "2.7.0"
```

### Security contexts

```yaml
awx-operator:
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

Both pod- and container-level contexts are set, which is what `restricted` PodSecurity
requires — the pod-level block alone is not sufficient.

### Resources

```yaml
awx-operator:
  resources:
    requests: { memory: 256Mi, cpu: 100m }
    limits:   { memory: 512Mi, cpu: 200m }
```

Sized for the operator's reconcile loop only — AWX instances it creates carry their own
resource requests.
