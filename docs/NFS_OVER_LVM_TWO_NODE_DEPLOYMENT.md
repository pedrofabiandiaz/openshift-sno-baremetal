# NFS over LVMS on OpenShift 4.20 — Two-Node Bare-Metal Cluster (SNO + Worker)

This document describes **end-to-end steps** for **OpenShift Container Platform 4.20**: deploy **in-cluster NFS** backed by **LVM volumes provisioned through the LVMS operator** (Logical Volume Manager Storage), on the topology defined in this repository: **Single-Node OpenShift (SNO) plus one bare metal worker** ([ADD_WORKER_NODE_PLAN.md](ADD_WORKER_NODE_PLAN.md)).

| Layer | Role |
|-------|------|
| **LVMS** | Creates LVM-backed **ReadWriteOnce (RWO)** volumes and a `StorageClass`. |
| **NFS server (pod)** | Mounts one large RWO PVC and **exports** it over NFS (shared **ReadWriteMany** access for clients). |
| **NFS CSI driver** | Lets workloads request **RWX** PVCs that mount that export. |

**Support note:** LVMS is a Red Hat operator; the **in-cluster NFS server image** and **Kubernetes NFS CSI** below are common community/upstream patterns. Validate images, versions, and SCC posture against your security and support requirements before production.

**Related docs:** [ADD_WORKER_NODE_PLAN.md](ADD_WORKER_NODE_PLAN.md), [LOCAL_STORAGE_OPERATOR_SNO.md](LOCAL_STORAGE_OPERATOR_SNO.md) (disk safety habits), [REGISTRY_STORAGE_SETUP_PLAN.md](REGISTRY_STORAGE_SETUP_PLAN.md) (RWX registry), [ADD_CATALOG_SOURCE_DISCONNECTED.md](ADD_CATALOG_SOURCE_DISCONNECTED.md) (disconnected catalogs and mirroring).

---

## 1. Prerequisites

| Item | Requirement |
|------|-------------|
| **Cluster** | **OpenShift 4.20** (z-stream as supported by your org) with SNO + worker **Ready**. |
| **Roles** | `cluster-admin` for operators, SCC, and CSI install. |
| **Disks** | Unused disks on the node that will host NFS (usually the **dedicated worker**). Same rules as local storage: **wrong disk can destroy the cluster**—use stable `/dev/disk/by-id` or `by-path` paths. |
| **Catalog** | `redhat-operators` (connected) or mirrored operators (disconnected). LVMS channel example in this repo: `imagesetconfigs/operators-channels-4_20.txt` (`lvms-operator`, `stable-4.20`). |
| **Air-gapped NFS CSI** | CSI install YAMLs are **vendored** under `manifests/nfs-csi-driver/openshift-4.20/` in this repo; you still need a private registry and **`ImageTagMirrorSet`** (or image-rewritten YAML) for container images per **Phase C**. |

Discover node names:

```bash
oc get nodes -o wide --show-labels
```

---

## 2. Phase A — LVMS operator and `LVMCluster`

### 2.1 Install the LVMS operator

**Console:** **Operators → OperatorHub** → search **Logical Volume Manager Storage** (or **LVMS**) → install into **`openshift-storage`** (or the namespace required by your OCP version’s documentation). Channel: **stable-4.20** (or the channel that matches your cluster).

**CLI (outline):** create `Subscription` / `OperatorGroup` as for other platform operators; wait until CSV shows **Succeeded**.

```bash
oc -n openshift-storage get csv
oc -n openshift-storage get pods
```

### 2.2 Create `LVMCluster`

1. Replace placeholders: **node hostname**, **disk paths**, device class **name**, and **`forceWipeDevicesAndDestroyAllData`** only when wiping is intentional.

2. Apply a cluster-scoped CR similar to the following (API group/version may vary slightly by OCP release—confirm with `oc explain lvmcluster`):

```yaml
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: nfs-backing-lvm
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
      - name: nfsvg
        default: true
        fstype: xfs
        nodeSelector:
          nodeSelectorTerms:
            - matchExpressions:
                - key: kubernetes.io/hostname
                  operator: In
                  values:
                    - <WORKER_NODE_HOSTNAME>
        deviceSelector:
          paths:
            - /dev/disk/by-id/<REPLACE_WITH_YOUR_DISK_ID>
          forceWipeDevicesAndDestroyAllData: true
        # Optional thin provisioning; omit for thick LVs only.
        # thinPoolConfig:
        #   name: thin-pool-1
        #   sizePercent: 90
        #   overprovisionRatio: 10
```

3. Wait until the operator reports healthy status and StorageClasses exist:

```bash
oc get lvmcluster -n openshift-storage
oc get storageclass | grep lvms
```

You should see a StorageClass named like **`lvms-nfsvg`** (pattern `lvms-<deviceClassName>`).

### 2.3 Namespace and backing PVC for the NFS export (RWO)

Create the workload namespace **before** the PVC (the PVC is namespaced):

```bash
oc create namespace nfs-system
```

Create a **single large** PVC used only by the NFS server. **Access mode must be `ReadWriteOnce`.** The NFS Deployment in Phase B must use **`strategy.type: Recreate`** so the volume is never attached to two pods at once.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-backing
  namespace: nfs-system
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: 200Gi
  storageClassName: lvms-nfsvg
```

```bash
oc apply -f nfs-backing-pvc.yaml
oc -n nfs-system get pvc nfs-backing -w
```

**Bound** means LVMS provisioned an LV on the selected node. The NFS pod will be scheduled on **that same node** automatically.

---

## 3. Phase B — In-cluster NFS server

### 3.1 Pod Security labels (OpenShift)

Namespace **`nfs-system`** was created in **section 2.3**. Allow privileged workloads in it (NFS daemons typically require it):

```bash
oc label namespace nfs-system pod-security.kubernetes.io/enforce=privileged --overwrite
oc label namespace nfs-system security.openshift.io/scc.podSecurityLabelSync=false --overwrite
```

(If your site uses a different PSA/SCC model, align with cluster policy; the goal is a **privileged** pod allowed for the NFS workload only.)

### 3.2 Service account and SCC

```bash
oc -n nfs-system create serviceaccount nfs-server
oc adm policy add-scc-to-user privileged -z nfs-server -n nfs-system
```

### 3.3 NFS server Deployment

Properties that matter on OpenShift:

- **`privileged: true`** for the container (or an SCC-granted equivalent).
- **`strategy.type: Recreate`** so the RWO volume is not mounted by two pods during rollout.
- **One replica** (NFS server is not horizontally scaled this way).

The example below uses a **community** image (`itsthenetwork/nfs-server-alpine`) often used in labs; **substitute** an image your organization approves. Env `SHARED_DIRECTORY` must match the volume mount path.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-server
  namespace: nfs-system
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nfs-server
  template:
    metadata:
      labels:
        app: nfs-server
    spec:
      serviceAccountName: nfs-server
      containers:
        - name: nfs
          image: docker.io/itsthenetwork/nfs-server-alpine:12
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
          env:
            - name: SHARED_DIRECTORY
              value: /exports
          ports:
            - name: nfs
              containerPort: 2049
              protocol: TCP
            - name: mountd
              containerPort: 20048
              protocol: TCP
            - name: rpcbind
              containerPort: 111
              protocol: TCP
          volumeMounts:
            - name: export
              mountPath: /exports
      volumes:
        - name: export
          persistentVolumeClaim:
            claimName: nfs-backing
```

```bash
oc apply -f nfs-server-deployment.yaml
oc -n nfs-system get pods -l app=nfs-server -w
oc -n nfs-system logs deploy/nfs-server
```

### 3.4 Service (in-cluster NFS endpoint)

Expose NFS to other namespaces via a **ClusterIP** Service. Client pods and the CSI driver use this DNS name.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nfs-server
  namespace: nfs-system
spec:
  selector:
    app: nfs-server
  ports:
    - name: nfs
      port: 2049
      targetPort: 2049
      protocol: TCP
    - name: mountd
      port: 20048
      targetPort: 20048
      protocol: TCP
    - name: rpcbind-udp
      port: 111
      targetPort: 111
      protocol: UDP
    - name: rpcbind-tcp
      port: 111
      targetPort: 111
      protocol: TCP
```

```bash
oc apply -f nfs-server-service.yaml
```

**In-cluster server DNS:** `nfs-server.nfs-system.svc.cluster.local`

**Export path for this image:** clients use the exported directory **`/exports`** (set `share` in CSI StorageClass accordingly).

### 3.5 Smoke test (optional, before CSI)

Use a pod with an **inline NFS volume** so the kubelet mounts the export at **`/mnt`** (no manual `mount` inside the container):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nfs-client-smoke
  namespace: nfs-system
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: registry.redhat.io/rhel9/support-tools
      command: ["sleep", "600"]
      volumeMounts:
        - name: n
          mountPath: /mnt
  volumes:
    - name: n
      nfs:
        server: nfs-server.nfs-system.svc.cluster.local
        path: /exports
```

```bash
oc apply -f nfs-client-smoke-pod.yaml
oc wait -n nfs-system pod/nfs-client-smoke --for=condition=Ready --timeout=120s
oc exec -n nfs-system nfs-client-smoke -- touch /mnt/from-client
oc exec -n nfs-system nfs-client-smoke -- ls -la /mnt
oc delete pod -n nfs-system nfs-client-smoke
```

If the pod stays **ContainerCreating** or **MountVolume.SetUp failed**, fix the NFS server or Service before installing the CSI driver.

---

## 4. Phase C — NFS CSI driver (disconnected / air-gapped)

Install the **Kubernetes NFS CSI driver** so workloads can use **`csi` driver `nfs.csi.k8s.io`** and the **StorageClass** in Phase D. This section is written for **OpenShift 4.20** in a **disconnected** cluster: you mirror **container images** into your **private registry**, configure **mirror mapping** on the cluster, then **`oc apply`** the manifests from this repository—**no live downloads on the cluster**.

The driver YAMLs are pinned to upstream **[kubernetes-csi/csi-driver-nfs v4.13.2](https://github.com/kubernetes-csi/csi-driver-nfs/releases/tag/v4.13.2)** (`deploy/v4.13.2/`), which is a current release line tested against recent Kubernetes versions shipped with OpenShift 4.20. Re-validate in your lab before production.

**Vendored directory:** [`manifests/nfs-csi-driver/openshift-4.20/`](../manifests/nfs-csi-driver/openshift-4.20/) — see [`NOTICE`](../manifests/nfs-csi-driver/openshift-4.20/NOTICE).

| Order | File | Apply on every install |
|-------|------|------------------------|
| 1 | [`rbac-csi-nfs.yaml`](../manifests/nfs-csi-driver/openshift-4.20/rbac-csi-nfs.yaml) | Yes |
| 2 | [`csi-nfs-driverinfo.yaml`](../manifests/nfs-csi-driver/openshift-4.20/csi-nfs-driverinfo.yaml) | Yes |
| 3 | [`csi-nfs-controller.yaml`](../manifests/nfs-csi-driver/openshift-4.20/csi-nfs-controller.yaml) | Yes |
| 4 | [`csi-nfs-node.yaml`](../manifests/nfs-csi-driver/openshift-4.20/csi-nfs-node.yaml) | Yes |
| 5 | [`crd-csi-snapshot.yaml`](../manifests/nfs-csi-driver/openshift-4.20/crd-csi-snapshot.yaml) | Only if snapshot CRDs are missing (see **4.7**) |
| 6 | [`rbac-snapshot-controller.yaml`](../manifests/nfs-csi-driver/openshift-4.20/rbac-snapshot-controller.yaml) | Only with row 5–7 |
| 7 | [`csi-snapshot-controller.yaml`](../manifests/nfs-csi-driver/openshift-4.20/csi-snapshot-controller.yaml) | Only with row 5–7 |
| 8 | [`snapshotclass.yaml`](../manifests/nfs-csi-driver/openshift-4.20/snapshotclass.yaml) | Optional, after snapshot controller runs |

**Do not apply** upstream `storageclass.yaml` from the CSI project for cluster storage defaults; Phase D defines the **in-cluster NFS** `StorageClass`.

Core install order matches [`deploy/install-driver.sh`](https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/deploy/install-driver.sh) without the `snapshot` second argument; snapshot files are vendored separately for air-gapped optional use.

### 4.1 Refresh policy (rebasing for a newer OpenShift or driver)

This bundle is named **`openshift-4.20`** for the OpenShift version line you are running. To move to a **newer csi-driver-nfs** tag (or re-pin after an OpenShift upgrade):

1. Pick a **release** from [kubernetes-csi/csi-driver-nfs releases](https://github.com/kubernetes-csi/csi-driver-nfs/releases) and validate it in a lab on your target OCP z-stream.
2. Replace all files under **`manifests/nfs-csi-driver/openshift-4.20/`** from `https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/<tag>/deploy/<tag>/` (same filenames as the table above, excluding upstream `storageclass.yaml`), update **[`NOTICE`](../manifests/nfs-csi-driver/openshift-4.20/NOTICE)**, and re-run **`grep image: manifests/nfs-csi-driver/openshift-4.20/*.yaml`** to refresh **section 4.3** and your **`oc mirror` `additionalImages`** list.

### 4.2 Copy manifests into the air-gapped network

**Option A — Full git clone:** clone or update this repository on a host that can reach the cluster; the manifests are already at **`manifests/nfs-csi-driver/openshift-4.20/*.yaml`**.

**Option B — Tarball only:** from the repository root on a machine that has the files:

```bash
tar czf nfs-csi-manifests-openshift-4.20.tar.gz \
  manifests/nfs-csi-driver/openshift-4.20/NOTICE \
  manifests/nfs-csi-driver/openshift-4.20/*.yaml
```

Transfer **`nfs-csi-manifests-openshift-4.20.tar.gz`** to the administration host in the disconnected environment and extract before **`oc apply`**.

### 4.3 Image list to mirror (OpenShift 4.20 bundle, csi-driver-nfs **v4.13.2**)

These **`image:`** values are taken from the **vendored** manifests under [`manifests/nfs-csi-driver/openshift-4.20/`](../manifests/nfs-csi-driver/openshift-4.20/). After any rebase of those files, run:

```bash
grep -h 'image: ' manifests/nfs-csi-driver/openshift-4.20/*.yaml | sort -u
```

**Core NFS CSI (controller + node):**

| Image |
|-------|
| `registry.k8s.io/sig-storage/csi-provisioner:v6.1.0` |
| `registry.k8s.io/sig-storage/csi-resizer:v2.0.0` |
| `registry.k8s.io/sig-storage/csi-snapshotter:v8.4.0` |
| `registry.k8s.io/sig-storage/livenessprobe:v2.17.0` |
| `registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0` |
| `registry.k8s.io/sig-storage/nfsplugin:v4.13.2` |

**Optional snapshot controller** (only if you apply **`csi-snapshot-controller.yaml`** from this bundle):

| Image |
|-------|
| `registry.k8s.io/sig-storage/snapshot-controller:v8.4.0` |

Also mirror the **NFS server** image from Phase B (for example `docker.io/itsthenetwork/nfs-server-alpine:12`) and any **LVMS** / **support-tools** images you rely on, using the same mirror process your site uses for OpenShift.

**Mirror options (pick what matches your runbook):**

- **`oc mirror`** with `additionalImages` / image set config listing the tables above, then publish to your mirror registry (same family of workflow as [ADD_CATALOG_SOURCE_DISCONNECTED.md](ADD_CATALOG_SOURCE_DISCONNECTED.md)).
- **`skopeo copy`** (or `crane copy`) from the connected host: for each image, `docker://SOURCE` → `docker://<MIRROR>/<prefix>/…` preserving tag.

A ready-to-merge fragment is vendored at [`imagesetconfigs/nfs-csi-openshift-4_20-additionalImages.yaml`](../imagesetconfigs/nfs-csi-openshift-4_20-additionalImages.yaml) (same **`mirror.openshift.io/v2alpha1`** style as [imagesetconfigs/imageset-platform.yaml](../imagesetconfigs/imageset-platform.yaml)). Adjust tags there after any rebase of **`manifests/nfs-csi-driver/openshift-4.20/`**.

After `oc mirror` completes, apply the generated **`imageDigestMirrorSet`** / **`imageTagMirrorSet`** manifests (or equivalent) to the disconnected cluster so pulls rewrite to your mirror—follow the paths printed in the mirror working directory.

Record the **mirror pull spec** you end up with for each upstream image (host + repository path + tag).

### 4.4 Map `registry.k8s.io` pulls to your mirror (cluster-wide)

After images exist in your mirror, configure OpenShift so **unchanged** YAML that still says `registry.k8s.io/sig-storage/...` resolves to your mirror.

On **OpenShift 4.13+**, use **`ImageTagMirrorSet`** (tags) and/or **`ImageDigestMirrorSet`** (digests) as appropriate. Example **`ImageTagMirrorSet`** pattern when every image under `registry.k8s.io/sig-storage/` is replicated under **one** mirror repository prefix:

```yaml
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: nfs-csi-registry-k8s-sig-storage
spec:
  imageTagMirrors:
    - source: registry.k8s.io/sig-storage
      mirrors:
        - <YOUR_MIRROR_HOST>/<YOUR_ORG>/sig-storage
```

Replace `<YOUR_MIRROR_HOST>/<YOUR_ORG>/sig-storage` with the prefix your mirror actually serves (the cluster must resolve the same path layout for **every** `registry.k8s.io/sig-storage/...` image you use, including optional snapshot components). Apply the object **before** or **with** the first pull:

```bash
oc apply -f imagetagmirrorset-nfs-csi.yaml
```

Wait for the **cluster version operator** to roll out machine config changes if your change touches node pull behavior; then confirm nodes can pull (see **4.9**).

**Pull secret:** Ensure the global pull secret (or namespace pull secrets) includes credentials for **`<YOUR_MIRROR_HOST>`**, and that the mirror’s TLS CA is trusted (`additionalTrustBundle` in install config or equivalent)—same constraints as [ADD_CATALOG_SOURCE_DISCONNECTED.md](ADD_CATALOG_SOURCE_DISCONNECTED.md).

### 4.5 Alternative: rewrite images in YAML (no mirror mapping)

If you **cannot** use `ImageTagMirrorSet` / `ImageDigestMirrorSet`, edit the **vendored** copies under **`manifests/nfs-csi-driver/openshift-4.20/`** and replace every `registry.k8s.io/sig-storage/...` value with your mirror’s pull spec, then transfer the **edited** files only. Re-`grep image:` on those files before packaging to catch typos.

### 4.6 Apply manifests on the disconnected administration host

On a host with **`oc`**, **`KUBECONFIG`**, and a checkout (or extracted tarball) of this repository, set **`REPO_ROOT`** to the repository root directory, then apply in order:

```bash
export REPO_ROOT=/path/to/openshift-sno-baremetal

oc apply -f "${REPO_ROOT}/manifests/nfs-csi-driver/openshift-4.20/rbac-csi-nfs.yaml"
oc apply -f "${REPO_ROOT}/manifests/nfs-csi-driver/openshift-4.20/csi-nfs-driverinfo.yaml"
oc apply -f "${REPO_ROOT}/manifests/nfs-csi-driver/openshift-4.20/csi-nfs-controller.yaml"
oc apply -f "${REPO_ROOT}/manifests/nfs-csi-driver/openshift-4.20/csi-nfs-node.yaml"
```

**Do not** apply an upstream `storageclass.yaml` from the Kubernetes CSI driver bundle unless you intend to use it; Phase D defines the **in-cluster NFS** `StorageClass` for this design.

### 4.7 Optional: snapshot CRDs and controller (vendored)

The default [`install-driver.sh`](https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/deploy/install-driver.sh) **does not** install snapshots unless you pass a second argument containing `snapshot`. For **air-gapped** clusters, the same files are **already** under **`manifests/nfs-csi-driver/openshift-4.20/`** so you do not need to download them.

**Before applying anything from rows 5–8 of the manifest table**, run:

```bash
oc get crd volumesnapshots.snapshot.storage.k8s.io 2>/dev/null && echo "CRD present"
oc get deployment -A 2>/dev/null | grep -i snapshot || true
```

| Situation | Action |
|-----------|--------|
| **`volumesnapshots.snapshot.storage.k8s.io` CRD exists** and a **snapshot controller** Deployment is already running (common on OpenShift) | **Skip** `crd-csi-snapshot.yaml`, `rbac-snapshot-controller.yaml`, and `csi-snapshot-controller.yaml`. Apply **`snapshotclass.yaml`** only if it does not conflict with existing `VolumeSnapshotClass` objects. |
| **CRDs missing** (or you deliberately install the upstream snapshot stack after validating no conflict with OpenShift) | Apply **in order** after **4.6**, using the paths below. Mirror **`registry.k8s.io/sig-storage/snapshot-controller:v8.4.0`** first (**4.3**). |

If the second row applies:

```bash
export REPO_ROOT=/path/to/openshift-sno-baremetal
SNAP="${REPO_ROOT}/manifests/nfs-csi-driver/openshift-4.20"

oc apply -f "${SNAP}/crd-csi-snapshot.yaml"
oc apply -f "${SNAP}/rbac-snapshot-controller.yaml"
oc apply -f "${SNAP}/csi-snapshot-controller.yaml"
# Optional: oc apply -f "${SNAP}/snapshotclass.yaml"
```

### 4.8 OpenShift `ClusterCSIDriver`

Register the driver with OpenShift’s CSI driver operator API:

```yaml
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: nfs.csi.k8s.io
spec:
  managementState: Managed
```

```bash
oc apply -f clustercsidriver-nfs.yaml
```

### 4.9 Verification and common failures

```bash
oc get pods -n kube-system -l app=csi-nfs-controller -o wide
oc get pods -n kube-system -l app=csi-nfs-node -o wide
oc get csidriver nfs.csi.k8s.io
oc describe pod -n kube-system -l app=csi-nfs-controller
```

| Symptom | Checks |
|---------|--------|
| **`ImagePullBackOff`** | Mirror contains the exact tag; **`ImageTagMirrorSet`** source prefix matches `registry.k8s.io/sig-storage`; pull secret and CA for mirror. |
| **Controller not scheduled on SNO** | Upstream manifest includes **control-plane tolerations**; on two-node bare metal the controller should land on the SNO node. |
| **`Driver name nfs.csi.k8s.io already exists`** | Partial prior install; `oc get csidriver` and remove conflicting objects before re-applying. |

### 4.10 Connected cluster shortcut (not air-gapped)

If the cluster **can** pull `registry.k8s.io` directly, apply the **same vendored files** (no `curl` to GitHub required):

```bash
export REPO_ROOT=/path/to/openshift-sno-baremetal

oc apply -f "${REPO_ROOT}/manifests/nfs-csi-driver/openshift-4.20/rbac-csi-nfs.yaml"
oc apply -f "${REPO_ROOT}/manifests/nfs-csi-driver/openshift-4.20/csi-nfs-driverinfo.yaml"
oc apply -f "${REPO_ROOT}/manifests/nfs-csi-driver/openshift-4.20/csi-nfs-controller.yaml"
oc apply -f "${REPO_ROOT}/manifests/nfs-csi-driver/openshift-4.20/csi-nfs-node.yaml"
```

Then still apply **`ClusterCSIDriver`** (section **4.8**) and Phase D **StorageClass**.

---

## 5. Phase D — StorageClass for workload PVCs (RWX)

Create a **StorageClass** whose `provisioner` is **`nfs.csi.k8s.io`** and whose `parameters` point at the in-cluster Service and export path.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-rwx
provisioner: nfs.csi.k8s.io
parameters:
  server: nfs-server.nfs-system.svc.cluster.local
  share: /exports
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
allowVolumeExpansion: false
```

```bash
oc apply -f storageclass-nfs-rwx.yaml
```

**Test RWX:**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rwx-test
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-rwx
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: rwx-a
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: <SNO_NODE_HOSTNAME>
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: rwx-test
  containers:
    - name: app
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: data
          mountPath: /data
---
apiVersion: v1
kind: Pod
metadata:
  name: rwx-b
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: <WORKER_NODE_HOSTNAME>
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: rwx-test
  containers:
    - name: app
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: data
          mountPath: /data
```

```bash
oc apply -f rwx-test.yaml
oc get pvc rwx-test
oc wait pod/rwx-a pod/rwx-b --for=condition=Ready --timeout=120s
oc exec rwx-a -- touch /data/from-a
oc exec rwx-b -- ls -l /data/from-a
```

If **rwx-b** sees the file, NFS + CSI + multi-node attachment behave as expected.

---

## 6. Phase E — Optional: dynamic per-PVC subdirectories (`nfs-subdir-external-provisioner`)

If you want **one** NFS export but **many** automatically created subdirectories per PVC, install the **NFS subdir external provisioner** (Helm or manifests) **after** the NFS server is stable. Configure it with:

- **NFS server:** `nfs-server.nfs-system.svc.cluster.local`
- **NFS path:** `/exports` (or a subpath you create exclusively for subdir provisioning)

Follow the chart’s documentation for RBAC, StorageClass name, and reclaim policy. This is optional; many teams use **only** the NFS CSI StorageClass with `share: /exports` and accept a single shared tree or use **manual** PVs per app.

---

## 7. Phase F — Example consumer: image registry (RWX)

If the registry uses **multiple replicas** or you want **RWX**, point it at a PVC created with **`storageClassName: nfs-rwx`** (see [REGISTRY_STORAGE_SETUP_PLAN.md](REGISTRY_STORAGE_SETUP_PLAN.md) for operator patches and minimum size).

---

## 8. Operations checklist

| Topic | Action |
|--------|--------|
| **Upgrades** | Drain the **NFS worker** during maintenance; expect brief RWX outage unless you design HA NFS elsewhere. |
| **Backups** | Back up NFS data (LVMS **VolumeSnapshot** if enabled for the device class, or application-level backup). |
| **Capacity** | Expand LVMS-backed PVC only if your **StorageClass** / driver combination supports **volume expansion**; otherwise plan larger replacement PVC + data migration. |
| **Security** | Tighten export options (e.g. `root_squash`, client lists) on the server image you choose; restrict **NetworkPolicy** so only cluster workloads reach the NFS Service. |
| **Troubleshooting** | `oc -n nfs-system describe pod -l app=nfs-server`; check mount inside the pod; `oc logs` for `csi-nfs-node` on the node where a client pod fails. |

---

## 9. Summary flow

1. Install **LVMS** → create **`LVMCluster`** on the worker’s spare disks → get **`lvms-<class>`** StorageClass.  
2. Create **`nfs-system`**, **SCC** binding, **backing PVC** (`ReadWriteOnce`, `lvms-*`).  
3. Deploy **privileged NFS server** + **Service** (`Recreate`, one replica).  
4. Mirror CSI images (for example merge [`imagesetconfigs/nfs-csi-openshift-4_20-additionalImages.yaml`](../imagesetconfigs/nfs-csi-openshift-4_20-additionalImages.yaml)), apply **`ImageTagMirrorSet`** as needed, then **`oc apply`** vendored CSI YAMLs under **`manifests/nfs-csi-driver/openshift-4.20/`** (upstream **v4.13.2**), add **`ClusterCSIDriver`**, optional snapshot YAMLs (**4.7**), then create **`nfs-rwx`** StorageClass.  
5. Verify **RWX** from pods on **both** nodes.  
6. Attach consumers (e.g. registry per [REGISTRY_STORAGE_SETUP_PLAN.md](REGISTRY_STORAGE_SETUP_PLAN.md)).
