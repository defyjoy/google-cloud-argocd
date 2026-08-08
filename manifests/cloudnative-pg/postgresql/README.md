# CloudNative-PG PostgreSQL Examples

This directory contains example manifests for deploying PostgreSQL clusters using CloudNative-PG operator.

## Prerequisites

1. CloudNative-PG operator must be installed in the cluster
2. Storage class must be available (e.g., OpenEBS)
3. (Optional) S3-compatible storage for backups

## Quick Start

### 1. Create Namespace

```bash
kubectl create namespace postgresql
```

### 2. Create Credentials Secret

Update the secrets in `example-cluster.yaml` with your actual credentials, or create them separately:

```bash
kubectl create secret generic postgresql-credentials \
  --from-literal=username=app_user \
  --from-literal=password=secure-password \
  --from-literal=dbname=example_db \
  -n postgresql
```

### 3. Apply PostgreSQL Cluster

```bash
kubectl apply -f example-cluster.yaml
```

### 4. Check Cluster Status

```bash
# Check cluster status
kubectl get cluster -n postgresql

# Check pods
kubectl get pods -n postgresql

# Check cluster details
kubectl describe cluster example-postgresql -n postgresql
```

## Connecting to PostgreSQL

### Get Connection Details

```bash
# Get the service endpoint
kubectl get svc -n postgresql example-postgresql-rw

# Port forward to access locally
kubectl port-forward -n postgresql svc/example-postgresql-rw 5432:5432
```

### Connect Using psql

```bash
# Using port forward
PGPASSWORD=$(kubectl get secret postgresql-credentials -n postgresql -o jsonpath='{.data.password}' | base64 -d) \
  psql -h localhost -U app_user -d example_db
```

### Connection String Format

```
postgresql://app_user:password@example-postgresql-rw.postgresql.svc.cluster.local:5432/example_db
```

## Backup Configuration

The example cluster includes S3 backup configuration. To enable backups:

1. Create S3 backup credentials secret:
```bash
kubectl create secret generic backup-credentials \
  --from-literal=ACCESS_KEY_ID=your-key \
  --from-literal=SECRET_ACCESS_KEY=your-secret \
  -n postgresql
```

2. Update the `endpointURL` and `serverName` in the Cluster manifest to match your S3 endpoint

3. Apply the updated manifest

## High Availability

The example cluster is configured with:
- **3 instances** for high availability
- **Pod anti-affinity** to spread instances across nodes
- **Automatic failover** managed by CloudNative-PG

## Scaling

### Increase Instances

```bash
kubectl patch cluster example-postgresql -n postgresql \
  --type merge -p '{"spec":{"instances":5}}'
```

### Scale Storage

```bash
kubectl patch cluster example-postgresql -n postgresql \
  --type merge -p '{"spec":{"storage":{"size":"50Gi"}}}'
```

## Monitoring

When monitoring is enabled, the cluster automatically creates:
- ServiceMonitor for Prometheus
- Metrics endpoints

Access metrics:
```bash
kubectl port-forward -n postgresql svc/example-postgresql-rw 9187:9187
curl http://localhost:9187/metrics
```

## Disaster Recovery

### Manual Backup

```bash
# Create a Backup resource
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: manual-backup
  namespace: postgresql
spec:
  cluster:
    name: example-postgresql
EOF
```

### Restore from Backup

```bash
# Create a Restore resource
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: restore-cluster
  namespace: postgresql
spec:
  source: manual-backup
  cluster:
    name: restored-postgresql
EOF
```

## Production Considerations

1. **Change Default Passwords**: Update all secrets with strong, unique passwords
2. **Enable TLS**: Configure SSL/TLS for connections
3. **Resource Limits**: Adjust CPU and memory based on workload
4. **Storage Class**: Use production-grade storage (SSD, replication)
5. **Backup Strategy**: Configure regular automated backups
6. **Monitoring**: Enable comprehensive monitoring and alerting
7. **Network Policies**: Restrict network access to database pods
8. **Pod Security**: Apply pod security policies/standards

## Additional Resources

- [CloudNative-PG Documentation](https://cloudnative-pg.io/documentation/)
- [PostgreSQL Best Practices](https://cloudnative-pg.io/documentation/current/examples/)
- [Backup and Restore Guide](https://cloudnative-pg.io/documentation/current/backup_recovery/)


