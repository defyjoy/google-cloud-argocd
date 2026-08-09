# Atlantis Helm Chart

This Helm chart wraps the official Atlantis Helm chart and provides additional configurations for deployment in a GitOps environment.

## Overview

Atlantis is a tool for Terraform pull request automation. It listens for GitHub/GitLab webhooks about pull request events and then runs `terraform plan` and `terraform apply` on the Terraform files in the pull request.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+
- ArgoCD (for GitOps deployment)
- External Secrets Operator (for secret management)

## Installation

### Using Helm

```bash
helm repo add runatlantis https://runatlantis.github.io/helm-charts
helm repo update
helm install atlantis ./helmcharts/atlantis -n atlantis --create-namespace
```

### Using ArgoCD ApplicationSet

The ApplicationSet is configured to deploy Atlantis to multiple clusters automatically. It will:

1. Deploy Atlantis to all clusters labeled with `argocd.argoproj.io/secret-type: cluster`
2. Configure ingress with cluster-specific hostnames
3. Set up TLS certificates automatically

## Configuration

### Required Secrets

The following secrets need to be configured via External Secrets:

- `github-token`: GitHub personal access token or app token
- `webhook-secret`: GitHub webhook secret
- `gitlab-token`: GitLab personal access token (if using GitLab)
- `gitlab-webhook-secret`: GitLab webhook secret (if using GitLab)

### Key Configuration Options

```yaml
atlantis:
  enabled: true
  image:
    repository: runatlantis/atlantis
    tag: "v0.27.0"
  
  ingress:
    enabled: true
    className: "nginx"
    hosts:
      - host: atlantis.jrclabs.xyz
    
  config:
    github:
      user: "atlantis-bot"
      token: ""  # Set via External Secrets
      webhookSecret: ""  # Set via External Secrets
    
    repos:
      - id: "/.*/"
        apply_requirements: ["approved"]
        workflow: "default"
```

## Security Features

- Non-root user execution
- Read-only root filesystem (where possible)
- Security contexts with minimal privileges
- Pod Security Standards compliance

## Monitoring and Observability

- Structured logging with configurable log levels
- Health check endpoints
- Resource limits and requests configured
- Prometheus metrics available

## Troubleshooting

### Common Issues

1. **Webhook not working**: Check that the webhook secret matches between GitHub/GitLab and the Kubernetes secret
2. **Permission denied**: Verify that the GitHub/GitLab token has sufficient permissions
3. **Terraform plan fails**: Check that the repository has the correct Terraform configuration and Atlantis can access the required providers

### Logs

```bash
kubectl logs -n atlantis deployment/atlantis
```

### Debug Mode

To enable debug logging, update the configuration:

```yaml
atlantis:
  config:
    server:
      log_level: "debug"
```

## Contributing

1. Make changes to the Helm chart
2. Test the changes in a development environment
3. Submit a pull request with a clear description of the changes

## License

This chart is licensed under the Apache 2.0 License.

---

## This deployment's configuration

Wraps the official Atlantis chart (v4.4.4).

### VCS credentials

Both GitHub and GitLab blocks exist in `values.yaml`; **GitHub is the configured path** and the
GitLab block is inert unless swapped in.

> 🔐 Supply tokens and webhook secrets via External Secrets rather than inline values.

### Repository and workflow config

`repoConfig` and the workflow settings determine which repos Atlantis will plan/apply for and
under what workflow. Keep this narrow — Atlantis executes Terraform with whatever credentials it
holds.

Pod- and container-level security contexts are both set for `restricted` PodSecurity.
