# CloudNative-PG CRDs

This directory contains information about CloudNative-PG Custom Resource Definitions (CRDs).

## CRD Installation

The CloudNative-PG Helm chart automatically installs CRDs when `crds.create: true` is set in the values (which is the default).

### Manual CRD Installation (Alternative)

If you need to install CRDs separately:

```bash
# Download CRDs from the official release
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-1.27.1.yaml
```

Or for a specific version:
```bash
# Replace VERSION with the desired version
VERSION=1.27.1
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-${VERSION}.yaml
```

## CRD Resources

CloudNative-PG installs the following CRDs:

1. **Cluster** (`postgresql.cnpg.io/v1`)
   - Main resource for PostgreSQL cluster management
   - Defines PostgreSQL instances, configuration, and resources

2. **Backup** (`postgresql.cnpg.io/v1`)
   - Manages backup operations
   - Supports various storage backends (S3, Azure, GCS, etc.)

3. **ScheduledBackup** (`postgresql.cnpg.io/v1`)
   - Automated backup scheduling
   - Cron-based backup jobs

4. **Pooler** (`postgresql.cnpg.io/v1`)
   - Connection pooling (PgBouncer)
   - High-availability connection management

## Verifying CRD Installation

```bash
# List all CloudNative-PG CRDs
kubectl get crd | grep cnpg.io

# Check specific CRD
kubectl get crd clusters.postgresql.cnpg.io -o yaml

# Verify CRD is installed and ready
kubectl api-resources | grep postgresql.cnpg.io
```

## CRD Versions

The CRDs are versioned with the operator. Ensure CRD version matches operator version:
- Operator 1.27.1 → CRD version 1.27.1

## Upgrade Considerations

When upgrading CloudNative-PG:
1. CRDs are automatically updated by the Helm chart
2. CRDs are backward compatible within the same major version
3. Review [upgrade documentation](https://cloudnative-pg.io/documentation/current/upgrade/) before upgrading

## Troubleshooting

### CRD Not Found

```bash
# Verify CRD exists
kubectl get crd clusters.postgresql.cnpg.io

# If missing, install manually (see above)
```

### CRD Version Mismatch

```bash
# Check CRD version
kubectl get crd clusters.postgresql.cnpg.io -o jsonpath='{.spec.versions[*].name}'

# Compare with operator version
kubectl get deployment -n cloudnative-pg-system cnpg-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}'
```

## Additional Resources

- [CloudNative-PG CRD Reference](https://cloudnative-pg.io/documentation/current/api_reference/)
- [CRD Examples](https://github.com/cloudnative-pg/cloudnative-pg/tree/main/docs/src/samples)


