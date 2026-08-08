# strimzi-kafka-operator

Strimzi cluster operator — reconciles `Kafka` and related custom resources. This chart installs
**only the operator**; Kafka clusters themselves are separate CRs.

All dependency values nest under the `strimzi-kafka-operator:` key.

---

## Configuration

### Watch scope

```yaml
strimzi-kafka-operator:
  replicas: 1
  watchNamespaces: []
  watchAnyNamespace: false
```

> ⚠️ **This combination watches only the operator's own namespace.** An empty
> `watchNamespaces` does *not* mean "all" here — `watchAnyNamespace: false` is what governs.
> Set `watchAnyNamespace: true` for cluster-wide reconciliation, or list namespaces explicitly.

### Images

```yaml
strimzi-kafka-operator:
  defaultImageRegistry: quay.io
  defaultImageRepository: strimzi
  defaultImageTag: 0.40.0
  image:
    registry: ""
    repository: ""
    name: operator
    tag: ""
```

The `default*` fields apply to **all** Strimzi-managed images (Kafka, ZooKeeper, Connect,
bridge…), not just the operator. The `image:` block overrides only the operator itself, and its
empty `registry`/`repository`/`tag` fall back to the defaults above.

### Reconciliation

```yaml
strimzi-kafka-operator:
  fullReconciliationIntervalMs: 120000    # 2 minutes
  operationTimeoutMs: 300000              # 5 minutes
  kubernetesServiceDnsDomain: cluster.local
```

### Logging

```yaml
strimzi-kafka-operator:
  logLevel: INFO
  logVolume: co-config-volume
  logConfigMap: strimzi-cluster-operator
  logConfiguration: ""
```

`logConfiguration` is empty, so the operator uses the ConfigMap named above rather than an
inline log4j2 config.

### Misc

```yaml
strimzi-kafka-operator:
  featureGates: ""
  tmpDirSizeLimit: 1Mi
  extraEnvs: []
```

`featureGates` takes a comma-separated list; empty means upstream defaults for this version.
