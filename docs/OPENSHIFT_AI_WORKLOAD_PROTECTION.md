# OpenShift AI Workload Protection: Pre-Checks and Resource Constraints

This guide prepares a production cluster for **Red Hat OpenShift AI (RHOAI)** installation without disrupting workloads already in place. The primary focus is **pre-install validation** and **resource constraints** you can apply before the operator is installed.

**Node isolation** (dedicated workers, taints, and tolerations) is documented in an **optional** section. Whether you implement it depends on cluster capacity, operational constraints, and customer agreement—it is not required to complete the pre-checks in this guide or to install RHOAI.

---

## Target environment

| Attribute | Value |
|-----------|--------|
| **OpenShift version** | **4.20.17** |
| **Control plane** | **3** nodes — no user workloads |
| **Workers** | **3** nodes — GPU workloads and applications |
| **Access** | `cluster-admin`, `oc` CLI configured |

This document applies to a production-style cluster.

**RHOAI namespaces (typical):** `redhat-ods-operator`, `redhat-ods-applications` — confirm for your RHOAI version/channel.

Complete the **pre-checks and resource constraints** sections before installing the Red Hat OpenShift AI Operator or creating a `DataScienceCluster`. The **optional isolation** section can be pursued later if the customer approves dedicated AI workers and the associated drain or scale-out work.

### Cluster hardware (Dell XE9680)

| Item | Per node (control plane and worker) |
|------|-------------------------------------|
| **Platform** | Dell PowerEdge XE9680 |
| **GPU** | **8× NVIDIA H200** (workers; confirm GPU operator advertises `nvidia.com/gpu`) |
| **CPU** | 2× Intel Xeon Platinum **8568Y** (48 cores/socket → **96 physical cores**, **192 vCPUs** with HT) |
| **Memory** | **2 TiB** RAM |

| Role | Count | Scheduling |
|------|-------|------------|
| Control plane | **3** | OpenShift control plane only (`NoSchedule` on masters) |
| Worker | **3** | User applications and RHOAI |

### Planning capacity (workers)

After install, confirm **allocatable** (below is a planning baseline; OpenShift reserves CPU/memory for system daemons—values are usually slightly below capacity):

| Resource | Per worker (planning) | **3 workers (planning total)** |
|----------|----------------------|--------------------------------|
| CPU (allocatable) | ~**191** cores | ~**573** cores |
| Memory (allocatable) | ~**2000 GiB** | ~**6000 GiB** |
| `nvidia.com/gpu` | **8** | **24** |

```bash
# Verify on the live cluster and adjust quotas if allocatable differs
oc get nodes -l node-role.kubernetes.io/worker -o custom-columns=\
NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,GPU:.status.allocatable.'nvidia\.com/gpu'
```

**Quota profiles in this document:**

| Profile | Use when | RHOAI share of worker fleet |
|---------|----------|-----------------------------|
| **A — Shared workers (default)** | No node isolation; 3 workers shared | ~50% CPU/memory requests, ~16 GPUs |
| **B — Optional isolation** | Customer dedicates **2** workers to AI, **1** to apps | ~90% of **2** workers for RHOAI |

Leave headroom above RHOAI quotas for existing application **requests**, daemonsets, and burst **limits**.

---

## Table of Contents

1. [Approach](#1-approach)
2. [Pre-Checks and Resource Constraints](#2-pre-checks-and-resource-constraints)
   - [2.1 Cluster and control plane pre-checks](#21-cluster-and-control-plane-pre-checks)
   - [2.2 Audit existing workload resources](#22-audit-existing-workload-resources)
   - [2.3 Resource quotas for OpenShift AI namespaces](#23-resource-quotas-for-openshift-ai-namespaces)
   - [2.4 LimitRange in application and AI namespaces](#24-limitrange-in-application-and-ai-namespaces)
   - [2.5 Pod disruption budgets](#25-pod-disruption-budgets)
   - [2.6 Prepare namespaces before operator install](#26-prepare-namespaces-before-operator-install)
3. [Optional: Node isolation strategy](#3-optional-node-isolation-strategy)
   - [3.1 Planning worker layout](#31-planning-worker-layout)
   - [3.2 Dedicated AI nodes](#32-dedicated-ai-nodes)
   - [3.3 Taints and tolerations](#33-taints-and-tolerations)
4. [Pre-Install Checklist](#4-pre-install-checklist)
5. [References](#5-references)

---

## 1. Approach

| Track | Required? | When | What it protects |
|-------|-----------|------|------------------|
| **Pre-checks and resource constraints** | **Yes** | Before operator install | Control plane headroom, predictable app capacity, hard caps on AI namespaces, safe disruption during upgrades |
| **Node isolation** | **Optional** | If customer approves | Scheduling separation so AI pods do not compete with applications on the same nodes |

Resource quotas in [section 2.3](#23-resource-quotas-for-openshift-ai-namespaces) are tuned for the Dell XE9680 fleet above. Reconcile against live `allocatable` after nodes join; if optional isolation is adopted, switch to **Profile B**.

```text
Pre-checks + constraints  →  Install RHOAI operator  →  Enable DS components
                                    ↓ (optional, if approved)
                         Dedicated AI nodes + taints/tolerations
```

---

## 2. Pre-Checks and Resource Constraints

### Task summary

| Step | Task | Outcome |
|------|------|---------|
| 2.1 | Control plane and cluster health pre-checks | Confirm API/etcd can absorb operator install |
| 2.2 | Audit requests/limits on existing deployments | Existing apps have reserved capacity |
| 2.3 | ResourceQuota on RHOAI namespaces | Hard ceiling on AI resource use |
| 2.4 | LimitRange (optional) | Defaults and per-pod maximums |
| 2.5 | Verify PDBs on critical apps | Safe eviction during drains/upgrades |
| 2.6 | Create namespaces and apply quotas | Ready before operator subscription |

---

### 2.1 Cluster and control plane pre-checks

#### Goal

Confirm the **3-node** control plane on **OpenShift 4.20.17** is healthy and not under sustained load **before** RHOAI increases API traffic, custom resources, and etcd watch volume.

#### Version and topology

```bash
oc version
oc get nodes -o custom-columns=\
NAME:.metadata.name,ROLES:.metadata.labels,STATUS:.status.conditions[-1].type

oc get nodes -l node-role.kubernetes.io/control-plane
oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l
```

Expect **3** control plane nodes and **3** workers in `Ready` state.

#### ClusterOperators and API health

```bash
oc get co -o custom-columns=\
NAME:.metadata.name,\
AVAILABLE:.status.conditions[?(@.type=="Available")].status,\
DEGRADED:.status.conditions[?(@.type=="Degraded")].status,\
PROGRESSING:.status.conditions[?(@.type=="Progressing")].status

oc get --raw /readyz?verbose
oc get --raw /livez?verbose
```

#### etcd (3-member quorum)

```bash
oc get etcd cluster -o yaml
oc get pods -n openshift-etcd -l app=etcd -o wide
oc get clusteroperator etcd
```

```bash
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- etcdctl endpoint health
oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- etcdctl endpoint status -w table
```

#### Monitoring baseline

Capture metrics **before** install; compare again during operator reconciliation.

```bash
oc get route -n openshift-monitoring prometheus-k8s \
  -o jsonpath='https://{.spec.host}{"\n"}' 2>/dev/null
```

| Component | PromQL (examples) | Warning sign |
|-----------|-------------------|--------------|
| API 5xx | `sum(rate(apiserver_request_total{code=~"5.."}[5m]))` | Sustained increase |
| API latency | `histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket[5m])) by (le))` | p99 > 1s sustained |
| etcd fsync | `histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))` | Storage latency spike |
| etcd DB size | `etcd_mvcc_db_total_size_in_bytes` | Near limit; plan defrag |
| etcd leader | `etcd_server_has_leader` | Any member `0` |
| CP pressure | `kube_node_status_condition{condition=~"MemoryPressure\|DiskPressure",status="true"}` | `true` on control plane |

#### Worker utilization snapshot

```bash
oc adm top nodes
oc describe nodes -l node-role.kubernetes.io/control-plane \
  | grep -A12 'Allocated resources'
```

Control plane nodes should show **low** workload allocation. Heavy application usage on control plane nodes indicates a scheduling misconfiguration.

#### Go / no-go (control plane)

| Check | Pass |
|-------|------|
| Version | **4.20.17** reported by `oc version` |
| Control plane | **3** nodes `Ready`, no memory/disk pressure |
| Workers | **3** Dell XE9680 workers `Ready`; allocatable matches [planning table](#cluster-hardware-dell-xe9680) |
| etcd | Quorum healthy; leader on all members |
| ClusterOperators | No unexpected `Degraded` |
| API | `/readyz` ok; 5xx near baseline |
| Baseline | Metrics or dashboard export saved |

---

### 2.2 Audit existing workload resources

#### Goal

Every production deployment should define CPU and memory **requests** (scheduler guarantees) and **limits** (burst/OOM boundaries). Without them, new namespaces and operators compete unpredictably for worker capacity.

#### Inventory workers and top consumers

```bash
oc get nodes -l node-role.kubernetes.io/worker -o wide
oc adm top nodes -l node-role.kubernetes.io/worker
oc adm top pods -A --sort-by=memory | head -40
oc adm top pods -A --sort-by=cpu | head -40
```

#### Find deployments missing requests

```bash
for ns in $(oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | grep -vE '^(openshift|kube-|default|redhat-ods)'); do
  oc get deploy -n "$ns" -o json 2>/dev/null | jq -r --arg ns "$ns" '
    .items[] |
    select(
      ([.spec.template.spec.containers[]? |
        (.resources.requests.cpu // "") == "" or
        (.resources.requests.memory // "") == ""
      ] | any)
    ) |
    "\($ns)/\(.metadata.name)"
  '
done
```

#### Find deployments missing limits

```bash
for ns in $(oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | grep -vE '^(openshift|kube-|default|redhat-ods)'); do
  oc get deploy -n "$ns" -o json 2>/dev/null | jq -r --arg ns "$ns" '
    .items[] |
    select(
      ([.spec.template.spec.containers[]? |
        (.resources.limits.cpu // "") == "" or
        (.resources.limits.memory // "") == ""
      ] | any)
    ) |
    "\($ns)/\(.metadata.name)"
  '
done
```

#### Remediation: set resources on a deployment

```bash
NS=my-app-namespace
DEPLOY=my-application

oc set resources deployment/"$DEPLOY" -n "$NS" \
  --requests=cpu=500m,memory=1Gi \
  --limits=cpu=2,memory=4Gi
```

```yaml
# example-patch-resources.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-application
  namespace: my-app-namespace
spec:
  template:
    spec:
      containers:
        - name: app
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
```

```bash
oc apply -f example-patch-resources.yaml
```

#### Document cluster allocatable

Compare live allocatable to the [planning table](#cluster-hardware-dell-xe9680):

```bash
oc get nodes -l node-role.kubernetes.io/worker \
  -o custom-columns=\
NAME:.metadata.name,\
CPU:.status.allocatable.cpu,\
MEMORY:.status.allocatable.memory,\
GPU:.status.allocatable.'nvidia\.com/gpu'
```

---

### 2.3 Resource quotas for OpenShift AI namespaces

#### Goal

Apply **ResourceQuota** objects to RHOAI namespaces **before** the operator and data science components are installed. Quotas enforce a hard cap on the cluster whether or not you later adopt optional node isolation.

#### Create namespaces early

```bash
oc create namespace redhat-ods-operator --dry-run=client -o yaml | oc apply -f -
oc create namespace redhat-ods-applications --dry-run=client -o yaml | oc apply -f -
```

#### Quota sizing summary (Dell XE9680, 3 workers)

| Namespace | Profile A (shared) | Profile B (2 AI workers, optional isolation) |
|-----------|-------------------|---------------------------------------------|
| `redhat-ods-operator` | 32 CPU req / 128 Gi mem req | Same |
| `redhat-ods-applications` | 285 CPU req / 3000 Gi mem req / **16** GPU req | 340 CPU req / 3600 Gi mem req / **14** GPU req |

Profile A leaves roughly half of worker **requests** for existing applications and system daemons on the same 3 nodes. Profile B applies when two XE9680 workers are tainted for RHOAI only.

```bash
# Sum allocatable by pool after optional isolation labels exist
oc get nodes -o json | jq '[.items[] | select(
  .metadata.labels["node-role.kubernetes.io/worker"] or
  .metadata.labels["node.openshift.io/rhoai"] == "true"
)] | group_by(.metadata.labels["node.openshift.io/rhoai"] == "true") |
  map({
    pool: (if (.[0].metadata.labels["node.openshift.io/rhoai"] == "true") then "ai" else "general" end),
    nodes: length,
    cpu: (map(.status.allocatable.cpu) | join(",")),
    memory: (map(.status.allocatable.memory) | join(",")),
    gpu: (map(.status.allocatable["nvidia.com/gpu"] // "0") | join(","))
  })'
```

#### ResourceQuota — `redhat-ods-operator`

```yaml
# resourcequota-redhat-ods-operator.yaml
# Dell XE9680 fleet — operator control plane (all profiles)
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rhoai-operator-quota
  namespace: redhat-ods-operator
spec:
  hard:
    requests.cpu: "32"
    requests.memory: "128Gi"
    limits.cpu: "64"
    limits.memory: "256Gi"
    pods: "120"
    persistentvolumeclaims: "30"
    services: "40"
    secrets: "150"
    configmaps: "150"
```

#### ResourceQuota — `redhat-ods-applications` (Profile A — default, 3 shared workers)

```yaml
# resourcequota-redhat-ods-applications.yaml
# Profile A: ~50% of 3× XE9680 worker allocatable; 16 of 24 H200 GPUs
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rhoai-applications-quota
  namespace: redhat-ods-applications
spec:
  hard:
    requests.cpu: "285"
    requests.memory: "3000Gi"
    limits.cpu: "380"
    limits.memory: "4000Gi"
    pods: "400"
    persistentvolumeclaims: "100"
    requests.storage: "4Ti"
    requests.nvidia.com/gpu: "16"
    limits.nvidia.com/gpu: "18"
```

#### ResourceQuota — `redhat-ods-applications` (Profile B — optional, 2 dedicated AI workers)

Use only if two workers are isolated for RHOAI (~382 CPU / ~4000 GiB / 16 GPUs planning allocatable). Replace Profile A file or apply as a separate revision after customer approval:

```yaml
# resourcequota-redhat-ods-applications-profile-b.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rhoai-applications-quota
  namespace: redhat-ods-applications
spec:
  hard:
    requests.cpu: "340"
    requests.memory: "3600Gi"
    limits.cpu: "360"
    limits.memory: "3800Gi"
    pods: "400"
    persistentvolumeclaims: "100"
    requests.storage: "4Ti"
    requests.nvidia.com/gpu: "14"
    limits.nvidia.com/gpu: "16"
```

```bash
oc apply -f resourcequota-redhat-ods-operator.yaml
oc apply -f resourcequota-redhat-ods-applications.yaml   # Profile A

# If optional isolation (2 AI workers) is approved, replace applications quota:
# oc apply -f resourcequota-redhat-ods-applications-profile-b.yaml
```

#### Monitor quota usage

```bash
oc describe resourcequota -n redhat-ods-operator
oc describe resourcequota -n redhat-ods-applications
oc get resourcequota -A | grep redhat-ods
```

If operator install fails with quota exceeded, raise caps incrementally or, if using optional isolation, recalculate from the dedicated AI node pool.

---

### 2.4 LimitRange in application and AI namespaces

#### Goal

**LimitRange** complements ResourceQuota: enforces defaults for pods without resources and caps maximum per-container size inside a namespace.

#### Application namespaces (existing workloads)

```yaml
# limitrange-app-namespace.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: app-namespace-defaults
  namespace: my-app-namespace
spec:
  limits:
    - type: Container
      default:
        cpu: "1"
        memory: "2Gi"
      defaultRequest:
        cpu: "250m"
        memory: "512Mi"
      max:
        cpu: "4"
        memory: "8Gi"
      min:
        cpu: "100m"
        memory: "128Mi"
```

```bash
oc apply -f limitrange-app-namespace.yaml
```

#### RHOAI applications namespace

Sized for large notebook/training pods on XE9680 (up to roughly half a node per container; GPU count still bounded by ResourceQuota):

```yaml
# limitrange-redhat-ods-applications.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: rhoai-per-container-limits
  namespace: redhat-ods-applications
spec:
  limits:
    - type: Container
      max:
        cpu: "96"
        memory: "512Gi"
      maxLimitRequestRatio:
        cpu: "4"
        memory: "2"
```

```bash
oc apply -f limitrange-redhat-ods-applications.yaml
```

---

### 2.5 Pod disruption budgets

#### Goal

Mission-critical deployments need **PodDisruptionBudgets (PDBs)** so voluntary disruptions (upgrades, drains, rescheduling) cannot drop availability below your minimum. PDBs are required if you pursue optional node isolation (worker drains); they are recommended regardless.

#### List existing PDBs

```bash
oc get pdb -A
oc get pdb -A -o custom-columns=\
NS:.metadata.namespace,\
NAME:.metadata.name,\
MIN:.spec.minAvailable,\
MAX:.spec.maxUnavailable,\
ALLOWED:.status.disruptionsAllowed
```

#### Export deployments for PDB gap analysis

```bash
oc get deploy -A -o json | jq -r '
  .items[] | select((.spec.replicas // 0) > 0) |
  "\(.metadata.namespace)/\(.metadata.name) replicas=\(.spec.replicas)"' | sort

oc get pdb -A -o json | jq -r '
  .items[] | "\(.metadata.namespace)/\(.metadata.name) selector=\(.spec.selector | tostring)"'
```

Review HA services (replicas ≥ 2) without a matching PDB.

#### Example PDB

```yaml
# pdb-critical-app.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-ha-app-pdb
  namespace: my-app-namespace
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: my-ha-application
```

```bash
oc apply -f pdb-critical-app.yaml
oc describe pdb my-ha-app-pdb -n my-app-namespace
```

#### Dry-run drain (validates PDBs if pursuing optional isolation)

```bash
oc adm drain <worker-hostname> --dry-run=server --ignore-daemonsets
```

Resolve PDB violations before draining workers for dedicated AI nodes.

---

### 2.6 Prepare namespaces before operator install

#### Pre-install sequence

```bash
# 1. Health
oc get co
oc get --raw /readyz

# 2. Namespaces + quotas (sections 2.3–2.4)
oc apply -f resourcequota-redhat-ods-operator.yaml
oc apply -f resourcequota-redhat-ods-applications.yaml
# oc apply -f limitrange-redhat-ods-applications.yaml

# 3. Confirm no unexpected workloads in RHOAI namespaces yet
oc get pods -n redhat-ods-operator
oc get pods -n redhat-ods-applications
```

Proceed to **operator subscription and DataScienceCluster** only when the pre-install checklist items are complete. If optional isolation is implemented, switch applications quota to **Profile B**.

---

## 3. Optional: Node isolation strategy

This section is **optional**. It may not be feasible (capacity, cost, change window) or the customer may choose to rely on **ResourceQuota** and application **requests/limits** only. Include it in planning discussions; implement only with explicit customer approval.

When adopted, physical and scheduling isolation is the strongest guarantee that OpenShift AI will not disrupt applications on general workers.

### When to consider isolation

| Factor | Favor optional isolation | Favor quotas/limits only |
|--------|--------------------------|---------------------------|
| Customer appetite | Willing to drain/relabel workers or add a MachinePool | Wants minimal cluster change |
| Capacity | Can dedicate **2 of 3** XE9680 workers to AI (1 for apps) | All **3** workers needed for existing apps on shared nodes |
| Risk tolerance | Low tolerance for AI/app contention on same nodes | Accept shared workers with hard quotas |
| Operations | Can maintain separate node pools | Prefer single worker pool |

| Mechanism | Purpose |
|-----------|---------|
| Dedicated AI workers | Reserve **2 of 3** XE9680 workers for GPU/AI (only practical split on this fleet) |
| Taint `env=openshift-ai:NoSchedule` | Block non-AI pods from AI nodes |
| Tolerations on RHOAI pods | Allow AI only on dedicated nodes |
| Recalculate ResourceQuota | Align quotas from [section 2.3](#23-resource-quotas-for-openshift-ai-namespaces) with AI node allocatable |

**Labels and taint used below:**

- Label: `node.openshift.io/rhoai=true`
- Taint: `env=openshift-ai:NoSchedule`

---

### 3.1 Planning worker layout

On this fleet there are only **3** Dell XE9680 workers (192 vCPUs, 2 TiB RAM, 8× H200 each). Optional isolation is a **hard trade-off**:

| Layout | General (`worker`) | Dedicated AI (`rhoai`) | Notes |
|--------|-------------------|-------------------------|--------|
| **Default (Profile A)** | **3** (shared) | **0** | Rely on ResourceQuota + app requests/limits |
| **Optional isolation (Profile B)** | **1** | **2** | Apps must fit on **one** XE9680; RHOAI on two nodes (~16 GPUs, ~382 CPU req cap) |
| **Not recommended** | **2** | **1** | Insufficient GPU/CPU pool for RHOAI at scale |

Control plane nodes (same hardware class, **3** nodes) must not run application or RHOAI pods.

If isolation is approved, apply **Profile B** quotas from [section 2.3](#23-resource-quotas-for-openshift-ai-namespaces) and drain/label the two AI workers.

---

### 3.2 Dedicated AI nodes

#### Inventory machine API

```bash
oc get nodes -l node-role.kubernetes.io/worker -o wide
oc get machine -n openshift-machine-api
oc get machineset -n openshift-machine-api
oc get machinepool -n openshift-machine-api 2>/dev/null
```

#### Option A — Separate pool at install (`install-config.yaml`)

```yaml
# install-config.yaml (excerpt) — platform section varies
compute:
  - name: worker
    replicas: 1
    platform: {}   # general apps — Dell XE9680
  - name: rhoai
    replicas: 2
    platform: {}   # RHOAI / GPU — Dell XE9680, 8× H200
# Total workers: 3 (matches this environment)
```

```bash
oc get nodes -l node-role.kubernetes.io/rhoai
```

#### Option B — Repurpose existing workers

```bash
AI_NODES="xe9680-worker-02.example.com xe9680-worker-03.example.com"

for n in $AI_NODES; do
  oc cordon "$n"
  oc adm drain "$n" --ignore-daemonsets --delete-emptydir-data --grace-period=300
  oc label node "$n" node-role.kubernetes.io/rhoai="" \
    node.openshift.io/rhoai=true --overwrite
done
```

```bash
for n in $AI_NODES; do oc uncordon "$n"; done
```

#### Option C — New MachinePool (scale out)

```bash
oc get machinepool -n openshift-machine-api -o yaml | less
```

```yaml
# machinepool-rhoai.yaml — copy platform from existing pool
apiVersion: machine.openshift.io/v1
kind: MachinePool
metadata:
  name: rhoai-worker
  namespace: openshift-machine-api
spec:
  replicas: 2
  labels:
    node-role.kubernetes.io/rhoai: ""
  taints:
    - key: env
      value: openshift-ai
      effect: NoSchedule
  template:
    metadata:
      labels:
        node.openshift.io/rhoai: "true"
  # platform: <from existing MachinePool>
```

```bash
oc apply -f machinepool-rhoai.yaml
```

#### Option D — MachineSet (UPI / bare metal)

Clone an existing worker MachineSet; add labels, taints, and `providerSpec` from a live worker:

```yaml
# machineset-rhoai-worker.yaml
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: rhoai-worker
  namespace: openshift-machine-api
spec:
  replicas: 2
  template:
    metadata:
      labels:
        node-role.kubernetes.io/rhoai: ""
    spec:
      metadata:
        labels:
          node.openshift.io/rhoai: "true"
      taints:
        - key: env
          value: openshift-ai
          effect: NoSchedule
      # providerSpec: <copy from existing worker MachineSet — Dell XE9680>
```

```bash
oc apply -f machineset-rhoai-worker.yaml
```

#### Verify

```bash
oc get nodes -l node.openshift.io/rhoai=true -o wide
# Expect 2 nodes if using Profile B; 0 if staying on Profile A (shared workers)
```

---

### 3.3 Taints and tolerations

#### Apply taint (if not set on MachinePool / MachineSet)

```bash
for node in $(oc get nodes -l node.openshift.io/rhoai=true -o name); do
  oc adm taint nodes "${node#node/}" env=openshift-ai:NoSchedule --overwrite
done
```

```bash
oc get nodes -l node.openshift.io/rhoai=true \
  -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

#### Toleration and affinity for RHOAI workloads

```yaml
spec:
  tolerations:
    - key: env
      operator: Equal
      value: openshift-ai
      effect: NoSchedule
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node.openshift.io/rhoai
                operator: In
                values:
                  - "true"
```

#### Verify isolation

```bash
AI_NODE=<rhoai-node-hostname>
oc get pods -A --field-selector spec.nodeName="$AI_NODE" -o wide
```

Application pods without the toleration should not appear on `$AI_NODE`.

#### Reconcile quotas after isolation

```bash
oc get nodes -l node.openshift.io/rhoai=true -o json | jq '
  [.items[].status.allocatable] | {nodes: length, resources: .}'
```

Apply **Profile B** `resourcequota-redhat-ods-applications-profile-b.yaml` and re-apply operator quota if needed.

---

## 4. Pre-Install Checklist

### Required before operator install

- [ ] Cluster is **OpenShift 4.20.17** with **3** control planes and **3** Dell XE9680 workers
- [ ] Control plane pre-checks passed (ClusterOperators, `/readyz`, etcd quorum)
- [ ] API/etcd monitoring baseline captured
- [ ] Existing production deployments audited; requests/limits set (or LimitRange on app namespaces)
- [ ] `redhat-ods-operator` and `redhat-ods-applications` namespaces exist
- [ ] ResourceQuota applied: **Profile A** (shared workers) or **Profile B** documented if isolation approved
- [ ] Live worker `allocatable` compared to [planning table](#cluster-hardware-dell-xe9680)
- [ ] LimitRange applied where appropriate
- [ ] PDBs verified for mission-critical HA applications

### Optional — node isolation (only if customer approves)

- [ ] Customer decision recorded: pursue isolation **yes / no**
- [ ] Worker sizing and GPU layout documented (if yes)
- [ ] Drain dry-run passed for any worker to be repurposed (if yes)
- [ ] **2** workers dedicated to AI and **1** to general applications (if yes — only viable split on this fleet)
- [ ] AI nodes labeled `node.openshift.io/rhoai=true` (if yes)
- [ ] Taint `env=openshift-ai:NoSchedule` applied; RHOAI tolerations configured (if yes)
- [ ] No application pods on AI nodes without toleration (if yes)
- [ ] ResourceQuota values updated to match AI node allocatable (if yes)

After pre-checks pass, proceed with operator install per [Red Hat OpenShift AI documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/). Optional isolation can be scheduled before or after initial RHOAI component enablement, depending on customer change windows—not a prerequisite for operator install.

---

## 5. References

- [OpenShift Container Platform 4.20 — Managing resources](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/nodes/nodes-nodes-managing-resources)
- [OpenShift 4.20 — Pod disruption budgets](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/nodes/nodes-pods-pdb)
- [OpenShift 4.20 — Taints and tolerations](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/nodes/nodes-nodes-taints-tolerations)
- [OpenShift 4.20 — Machine management](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/machine_management/index)
- [OpenShift 4.20 — etcd](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/etcd/index)
- [Red Hat OpenShift AI Self-Managed — Requirements](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/deploying-openshift-ai-in-a-disconnected-environment_install#requirements-for-openshift-ai-self-managed_install)
