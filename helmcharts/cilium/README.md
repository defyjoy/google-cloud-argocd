# cilium

Wrapper around the Cilium subchart, serving as the cluster CNI, the kube-proxy replacement, and
the sole LoadBalancer implementation (LB-IPAM + L2 announcement).

- Toggled by `enabled` (`Chart.yaml` `condition: enabled`)
- The ApplicationSet is itself label-gated (`cilium: "true"`), so this stays effectively off on
  any cluster whose Secret doesn't carry the label
- Per-cluster LoadBalancer address lists live in `values/<environment>.yaml`

Full context: alarmify-docs `docs/cilium/cilium-migration-plan.md` (executable runbook) and
`docs/infrastructure/adr-009-cilium-cni-loadbalancer-migration.md` (decision).

---

## Configuration

### kube-proxy replacement

```yaml
cilium:
  kubeProxyReplacement: true
  k8sServiceHost: localhost
  k8sServicePort: 7445
```

kube-proxy is removed at the Talos level (`cluster.proxy.disabled: true`). With no kube-proxy,
Cilium must reach the API server directly — Talos **KubePrism** exposes a load-balanced
apiserver endpoint on `localhost:7445` on every node, which is exactly what this needs and
avoids depending on an external VIP.

### IPAM — pod CIDR must not change

```yaml
cilium:
  ipam:
    mode: kubernetes
```

Reuses the per-node podCIDRs Talos already allocates from the cluster CIDR (`10.244.0.0/16`).

> 🚫 **Keeps the pod CIDR unchanged deliberately.** Re-IPing would break the Istio ambient
> multi-network mesh (ADR-006) and every running pod.

### Talos requirements

```yaml
cilium:
  cgroup:
    autoMount:
      enabled: false
    hostRoot: /sys/fs/cgroup
  securityContext:
    capabilities:
      ciliumAgent:
        - CHOWN, KILL, NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN
        - SYS_RESOURCE, DAC_OVERRIDE, FOWNER, SETGID, SETUID
      cleanCiliumState:
        - NET_ADMIN, SYS_ADMIN, SYS_RESOURCE
```

Talos has a **read-only rootfs and mounts cgroup v2 itself**, so Cilium must not auto-mount it
and needs an explicit capability set. Both lists are Talos-documented.

*(Capabilities shown comma-joined for brevity; they are one item per line in `values.yaml`.)*

### Istio ambient coexistence — highest-risk setting

```yaml
cilium:
  cni:
    exclusive: false
  socketLB:
    hostNamespaceOnly: true
```

`istio-cni` and `ztunnel` already run here. Cilium **must not be the exclusive CNI**, so
istio-cni can chain its config, and its socket-level load balancer must stay in the host
namespace so it does not short-circuit ztunnel's in-pod traffic redirection.

> ⚠️ This is the highest-risk part of the migration — validate on dev (plan Phase 4) before
> touching management.

### LoadBalancer via L2/ARP

```yaml
cilium:
  l2announcements:
    enabled: true
  externalIPs:
    enabled: true
  k8sClientRateLimit:
    qps: 50
    burst: 100
```

L2/ARP announcement, because there is no BGP router on this LAN.

The raised client rate limit is **required, not tuning**: L2 announcements plus kube-proxy
replacement increase apiserver usage through leader-election leases, and at the default limit
announcements get throttled (per Cilium docs).

### Footprint

```yaml
cilium:
  operator:
    replicas: 1
    rollOutPods: true
    skipCRDCreation: true
  hubble:
    enabled: false
```

Single operator replica (small clusters). Hubble UI/relay off for now given this cluster's known
CPU pressure — enable post-migration if central observability is wanted.

> 📌 **`skipCRDCreation` history.** This was set because the wrapper previously vendored all
> Cilium CRDs in `crds/`, and letting the operator also manage them made ArgoCD and the operator
> fight over CRD ownership. `crds/` was **removed on 2026-07-23** — the operator now registers
> CRDs at runtime, and the CR templates carry sync-wave `"3"` plus
> `SkipDryRunOnMissingResource=true` so ArgoCD applies them only after the operator is up.

---

## This chart's own LoadBalancer CRs

```yaml
loadBalancer:
  enabled: true
  poolName: default-pool
  interface: "ens18"
  addresses: []
```

`templates/cilium-*.yaml` render a `CiliumLoadBalancerIPPool` and a
`CiliumL2AnnouncementPolicy`. `interface` is a regex of node interfaces to announce on — the
Talos Proxmox virtio NIC is `ens18`.

`addresses` is empty in the shared file; each cluster supplies its own disjoint `/32` list in
its overlay. **When empty the templates render nothing**, so a cluster can sync before its pool
is decided.

`loadBalancer.enabled: true` is the steady-state default. Cilium is now the only thing answering
ARP for these `/32`s; if a second L2 responder is ever introduced on this LAN, both would ARP for
the same addresses, so keep any such component's pool disjoint from these lists.

**IP pinning:** existing gateway Services already request their specific IP via
`Gateway.spec.addresses` → `Service.spec.loadBalancerIP`, which Cilium LB-IPAM honours. A pool
that merely *contains* the in-use `/32`s therefore preserves each Service's current IP
(verified in plan Phase 4).

---

## Per-cluster overlays

Lists must stay **disjoint** — both clusters share the `192.168.0.0/16` LAN.

### dev — `values/dev.yaml`

The migration canary (plan Phases 2–5).

```yaml
loadBalancer:
  addresses:
    - 192.168.5.11/32    # istio-gateway (dev)
    - 192.168.5.12/32    # istio-eastwest (dev)
```

### management — `values/local.yaml`

**Preserve every IP exactly** — each is already claimed by a live Service.

```yaml
loadBalancer:
  addresses:
    - 192.168.3.10/32    # istio-gateway (north-south)
    - 192.168.3.11/32    # coredns-lan (kube-system)
    - 192.168.3.12/32    # istio-eastwest
    - 192.168.3.13/32    # istio-eastwest-classic
```

> ⏳ **Gating note, possibly stale.** This overlay was written with the instruction *"do not
> enable Cilium here until the dev canary is fully validated (plan Phases 6–9), and only on
> Cilium 1.20.0 GA, not the RC pinned in `Chart.yaml`."* Confirm the current cluster state
> before relying on that: `Chart.yaml` still pins an RC, so if management is already running
> Cilium, this constraint has been consciously overridden and should be re-recorded.
