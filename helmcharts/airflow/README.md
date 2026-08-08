# Apache Airflow Helm Chart

This Helm chart deploys Apache Airflow, a platform to programmatically author, schedule, and monitor workflows.

## Features

- **Workflow Orchestration**: Schedule and monitor complex workflows
- **Multiple Executors**: Support for LocalExecutor, CeleryExecutor, KubernetesExecutor, and CeleryKubernetesExecutor
- **Web UI**: Accessible web interface for managing DAGs
- **Scalable**: Support for multiple workers with CeleryExecutor
- **Ingress Support**: External access via Ingress

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- Ingress controller (nginx recommended)
- PostgreSQL (included in chart or external)
- Redis (for CeleryExecutor, included in chart)

## Configuration

### Basic Configuration

Edit `values.yaml` to customize your deployment:

```yaml
airflow:
  executor: "CeleryExecutor"  # Choose your executor
  webserver:
    ingress:
      enabled: true
      hosts:
        - host: airflow.workquark.org
```

### Executor Options

- **LocalExecutor**: Single scheduler and worker in one pod (good for development)
- **CeleryExecutor**: Distributed execution with multiple workers (recommended for production)
- **KubernetesExecutor**: Each task runs in its own Kubernetes pod
- **CeleryKubernetesExecutor**: Hybrid approach

### Ingress Configuration

The chart includes Ingress configuration for external access:

```yaml
airflow:
  webserver:
    ingress:
      enabled: true
      ingressClassName: nginx
      hosts:
        - host: airflow.workquark.org
          paths:
            - path: /
              pathType: Prefix
```

### DAGs Configuration

DAGs can be synced from Git or provided via PersistentVolume:

```yaml
airflow:
  dags:
    gitSync:
      enabled: true
      repo: https://github.com/your-org/airflow-dags
      branch: main
```

## Installation

### Via ArgoCD ApplicationSet

The chart is automatically deployed via ArgoCD ApplicationSet to clusters with the `airflow: "true"` label.

### Manual Installation

```bash
# Update dependencies
helm dependency update

# Install the chart
helm install airflow . -f values.yaml -n airflow --create-namespace
```

## Resources

- [Apache Airflow Documentation](https://airflow.apache.org/docs/)
- [Apache Airflow Helm Chart](https://airflow.apache.org/docs/helm-chart/stable/index.html)
- [Airflow Executors Guide](https://airflow.apache.org/docs/apache-airflow/stable/executor/index.html)

---

## This deployment's configuration

All dependency values nest under the `airflow:` key (chart version 1.21.0). Upstream reference:
<https://github.com/apache/airflow/blob/main/chart/values.yaml>.

### Hostname must be registered with StepCA

The hostname used by `templates/airflow-httproute.yaml` **must also appear** in
[`stepca`](../stepca/README.md)'s `edgeGatewayTls.dnsNames`, or the edge certificate will not
carry a matching SAN and TLS fails.

### Ingress disabled in favour of HTTPRoute

The chart's own Ingress resources are off; routing is a Gateway API `HTTPRoute` rendered by this
wrapper.

> 📌 The chart exposes both `ingress.web` (Airflow 2.x) and `ingress.apiServer` (Airflow 3+),
> plus a deprecated blanket `ingress.enabled`. Prefer the specific keys.
