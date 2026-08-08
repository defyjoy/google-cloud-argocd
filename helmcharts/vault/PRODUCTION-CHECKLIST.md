# HashiCorp Vault Production Deployment Checklist

Use this checklist to ensure your Vault deployment is production-ready.

## Pre-Deployment Checklist

### Infrastructure Requirements
- [ ] Kubernetes cluster version 1.19+ is running
- [ ] At least 3 worker nodes available for HA deployment
- [ ] Persistent volume provisioner is configured
- [ ] Ingress controller is installed (nginx recommended)
- [ ] DNS is configured for Vault hostname
- [ ] (Optional) cert-manager is installed for TLS certificates
- [ ] (Optional) Prometheus is installed for monitoring

### Security Configuration
- [ ] TLS certificates are ready (or cert-manager configured)
- [ ] Cloud KMS is configured for auto-unseal (AWS/GCP/Azure)
- [ ] Network policies are defined
- [ ] RBAC policies are configured
- [ ] Security scanning is completed on Vault image

### Storage Configuration
- [ ] Storage class is selected and tested
- [ ] Storage size is calculated based on expected data volume
- [ ] Backup storage location is configured
- [ ] Storage performance is validated (IOPS/throughput)

## Configuration Checklist

### values.yaml Updates
- [ ] Update ingress hostname to your domain
- [ ] Configure TLS settings (`tlsDisable: false` for production)
- [ ] Set appropriate storage class for data and audit logs
- [ ] Configure resource limits based on workload
- [ ] Enable auto-unseal with cloud KMS
- [ ] Set replica count (default: 3 for HA)
- [ ] Configure node selectors/tolerations if needed
- [ ] Review and adjust pod disruption budget

### Auto-Unseal Configuration (Choose One)
- [ ] AWS KMS configured with IAM permissions
- [ ] GCP KMS configured with service account
- [ ] Azure Key Vault configured with managed identity
- [ ] HSM configured (Enterprise only)

## Deployment Steps

### 1. Initial Deployment
- [ ] Run `helm dependency update`
- [ ] Review generated values with `helm template`
- [ ] Install chart: `helm install vault . -f values.yaml -n vault --create-namespace`
- [ ] Verify all pods are running: `kubectl get pods -n vault`
- [ ] Check services: `kubectl get svc -n vault`
- [ ] Verify PVCs are bound: `kubectl get pvc -n vault`

### 2. Vault Initialization
- [ ] Initialize Vault: `kubectl exec -n vault vault-0 -- vault operator init`
- [ ] Save unseal keys in secure location (password manager/vault)
- [ ] Save root token securely
- [ ] Document key custodians (for manual unseal scenario)

### 3. Vault Unsealing (If Not Using Auto-Unseal)
- [ ] Unseal vault-0 with 3 keys
- [ ] Unseal vault-1 with 3 keys
- [ ] Unseal vault-2 with 3 keys
- [ ] Verify all pods are active: `kubectl exec -n vault vault-0 -- vault status`

### 4. Raft Cluster Configuration
- [ ] Verify Raft peers: `kubectl exec -n vault vault-0 -- vault operator raft list-peers`
- [ ] Ensure all 3 nodes are in the peer list
- [ ] Verify leader election occurred
- [ ] Check cluster health

### 5. Authentication Configuration
- [ ] Enable Kubernetes auth: `vault auth enable kubernetes`
- [ ] Configure Kubernetes auth method
- [ ] Test authentication from a pod
- [ ] Create service accounts for applications

### 6. Audit Logging
- [ ] Enable file audit device
- [ ] Verify audit logs are being written
- [ ] Configure log rotation if needed
- [ ] Set up audit log monitoring/alerting

### 7. Secrets Engines Setup
- [ ] Enable required secrets engines (KV, Database, PKI, etc.)
- [ ] Configure secrets engines
- [ ] Create initial secrets/roles
- [ ] Test secret retrieval

### 8. Policy Configuration
- [ ] Create application-specific policies
- [ ] Create admin policies
- [ ] Create read-only policies for monitoring
- [ ] Test policy enforcement

## Post-Deployment Checklist

### Monitoring and Observability
- [ ] Configure Prometheus scraping
- [ ] Set up Grafana dashboards
- [ ] Configure alerting rules
- [ ] Set up log aggregation (ELK/Loki)
- [ ] Create runbooks for common issues

### Backup and DR
- [ ] Configure automated Raft snapshots
- [ ] Test snapshot creation
- [ ] Test snapshot restoration
- [ ] Document backup schedule
- [ ] Store backups in different region/zone
- [ ] Test DR failover procedure

### Security Hardening
- [ ] Revoke root token
- [ ] Enable MFA for admin access
- [ ] Configure session timeout
- [ ] Enable request rate limiting
- [ ] Review and apply security patches
- [ ] Implement secret rotation policies

### Access Control
- [ ] Create break-glass procedures
- [ ] Document unsealing process
- [ ] Set up on-call rotation
- [ ] Train team on Vault operations
- [ ] Create disaster recovery documentation

### Performance Tuning
- [ ] Monitor resource utilization
- [ ] Adjust resource limits if needed
- [ ] Configure request/connection limits
- [ ] Optimize storage performance
- [ ] Review and tune Raft parameters

### Integration Testing
- [ ] Test Vault Agent Injector with sample application
- [ ] Verify secret rotation works
- [ ] Test failover scenarios
- [ ] Validate auto-unseal on pod restart
- [ ] Test backup and restore procedures

## Validation Checklist

### Health Checks
```bash
# Verify Vault status
kubectl exec -n vault vault-0 -- vault status

# Check Raft cluster
kubectl exec -n vault vault-0 -- vault operator raft list-peers

# View audit logs
kubectl exec -n vault vault-0 -- tail /vault/audit/audit.log

# Check metrics endpoint
kubectl exec -n vault vault-0 -- curl http://localhost:8200/v1/sys/metrics
```

### Performance Tests
- [ ] Load test Vault endpoints
- [ ] Measure secret retrieval latency
- [ ] Test concurrent request handling
- [ ] Validate storage I/O performance

### Security Validation
- [ ] Run security scanning on deployed pods
- [ ] Validate network policies
- [ ] Test RBAC restrictions
- [ ] Audit API access logs
- [ ] Verify TLS encryption

## Maintenance Checklist

### Regular Maintenance (Weekly)
- [ ] Review audit logs
- [ ] Check pod health and resource usage
- [ ] Verify backup completion
- [ ] Review alerts and metrics
- [ ] Update documentation

### Regular Maintenance (Monthly)
- [ ] Rotate Vault tokens
- [ ] Review and update policies
- [ ] Update Vault version (if available)
- [ ] Review and optimize storage usage
- [ ] Disaster recovery drill

### Regular Maintenance (Quarterly)
- [ ] Review access controls
- [ ] Audit unsealing procedures
- [ ] Update disaster recovery documentation
- [ ] Conduct security audit
- [ ] Team training refresh

## Incident Response

### Unsealed Pod Issues
1. Check pod logs: `kubectl logs -n vault <pod-name>`
2. Verify Raft cluster status
3. Unseal pods if needed
4. Check for storage issues

### Performance Degradation
1. Check resource utilization
2. Review Prometheus metrics
3. Analyze audit logs for unusual activity
4. Scale resources if needed

### Data Recovery
1. Identify last good snapshot
2. Stop Vault cluster
3. Restore from snapshot
4. Verify data integrity
5. Unseal and test

## Sign-Off

- [ ] Infrastructure team reviewed and approved
- [ ] Security team reviewed and approved
- [ ] Operations team trained and ready
- [ ] Documentation complete and accessible
- [ ] Backup and DR procedures tested
- [ ] Production deployment approved

---

**Deployment Date**: _______________  
**Deployed By**: _______________  
**Reviewed By**: _______________  
**Approved By**: _______________

