# Local Storage Operator on Single-Node OpenShift (SNO)

This document describes how to install the **Local Storage Operator (LSO)** and provision **local PersistentVolumes** on a bare-metal SNO cluster. Local storage is a common choice for the integrated image registry, logging, or other workloads that need **ReadWriteOnce (RWO)** volumes on the single node.

For using the resulting `StorageClass` with the image registry, see [REGISTRY_STORAGE_SETUP_PLAN.md](REGISTRY_STORAGE_SETUP_PLAN.md).

---

## 1. Overview

| Item | Detail |
|------|--------|
| **Operator** | `local-storage-operator` |
| **Recommended namespace** | `openshift-local-storage` |
| **Provisioning model** | Operator discovers eligible local devices on selected nodes and creates PVs plus a `StorageClass` |
| **SNO fit** | One node; `nodeSelector` must match that node only |

**Important:** Local volumes are **not** replicated. Data lives on the physical disk on that node. Plan backups and disk sizing accordingly.

---

## 2. Prerequisites

| Requirement | Notes |
|-------------|--------|
| **Cluster access** | `cluster-admin` |
| **Spare disks** | One or more disks **not** used by the OpenShift installation (OS, etcd, container storage). Wrong device selection can destroy the cluster. |
| **Wiped or empty devices** | Prefer unused whole disks. LSO may partition and format devices you include in the set. |
| **Connected catalog** | Default instructions assume the `redhat-operators` catalog in `openshift-marketplace`. On disconnected clusters, mirror the operator and use your catalog source—see [ADD_CATALOG_SOURCE_DISCONNECTED.md](ADD_CATALOG_SOURCE_DISCONNECTED.md). |

Discover the SNO node name:

```bash
oc get nodes -o wide
```

Use the node’s `.metadata.name` (often the host’s short name) in the `LocalVolumeSet` examples below.

---

## 3. Install the Local Storage Operator

### 3.1 Web console

1. **Operators → OperatorHub** → search **Local Storage**.
2. Install **Local Storage** (Red Hat).
3. Namespace: **openshift-local-storage** (create if prompted).
4. Update channel: **stable** (or the channel that matches your OpenShift version).
5. Approval: **Automatic** (or Manual and approve the install plan).

### 3.2 CLI (Subscription)

Create the namespace, `OperatorGroup`, and `Subscription`:

```yaml
# lso-operator-install.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-local-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: local-storage
  namespace: openshift-local-storage
spec:
  targetNamespaces:
    - openshift-local-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: local-storage-operator
  namespace: openshift-local-storage
spec:
  channel: stable
  installPlanApproval: Automatic
  name: local-storage-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

```bash
oc apply -f lso-operator-install.yaml
```

**Disconnected clusters:** Replace `spec.source` and `spec.sourceNamespace` with your mirrored catalog (for example `my-redhat-operators` in `openshift-marketplace` or your custom namespace), consistent with [ADD_CATALOG_SOURCE_DISCONNECTED.md](ADD_CATALOG_SOURCE_DISCONNECTED.md).

Verify the operator is running:

```bash
oc -n openshift-local-storage get csv
oc -n openshift-local-storage get pods
```

Wait until the ClusterServiceVersion shows **Succeeded**.

---

## 4. Provision storage with a LocalVolumeSet (recommended)

`LocalVolumeSet` discovers devices on nodes that match `nodeSelector`, creates PersistentVolumes, and a **new** `StorageClass` named in `spec.storageClassName`.

### 4.1 Filesystem volumes (typical for registry PVCs)

Replace `<SNO_NODE_NAME>` with your node from `oc get nodes`.

```yaml
# lso-localvolumeset-fs.yaml
apiVersion: local.storage.openshift.io/v1
kind: LocalVolumeSet
metadata:
  name: sno-local-fs
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
              - <SNO_NODE_NAME>
  storageClassName: sno-local-fs
  volumeMode: Filesystem
  fsType: xfs
  maxDeviceCount: 10
  deviceInclusionSpec:
    deviceTypes:
      - disk
    # Optional: limit to SSDs
    # deviceMechanicalProperties:
    #   - NonRotational
    # Optional: restrict by size (example: between 100Gi and 2Ti)
    # minSize: 100Gi
    # maxSize: 2Ti
```

```bash
oc apply -f lso-localvolumeset-fs.yaml
```

### 4.2 Raw block volumes

Use when workloads need `volumeMode: Block` (for example some databases or CSI drivers).

```yaml
# lso-localvolumeset-block.yaml
apiVersion: local.storage.openshift.io/v1
kind: LocalVolumeSet
metadata:
  name: sno-local-block
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
              - <SNO_NODE_NAME>
  storageClassName: sno-local-block
  volumeMode: Block
  maxDeviceCount: 10
  deviceInclusionSpec:
    deviceTypes:
      - disk
```

Tighten `deviceInclusionSpec` (WWN, vendor, model, minimum size, etc.) so only intended disks are selected. On bare metal, listing block devices on the node (support tools or debug pod) helps before applying the CR.

---

## 5. Optional: LocalVolume (static device paths)

If you prefer **explicit paths** instead of discovery, use `LocalVolume`. You list each device path under `spec.storageClassDevices[].devicePaths`.

```yaml
# lso-localvolume-example.yaml — example only; adjust paths and node
apiVersion: local.storage.openshift.io/v1
kind: LocalVolume
metadata:
  name: sno-local-static
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
              - <SNO_NODE_NAME>
  storageClassDevices:
    - storageClassName: sno-local-static
      volumeMode: Filesystem
      fsType: xfs
      devicePaths:
        - /dev/disk/by-id/<your-stable-disk-id>
```

Stable identifiers under `/dev/disk/by-id/` are preferred over `/dev/sdX` so device names do not shift across reboots.

---

## 6. Verification

```bash
# Operator and discovery/disk manager pods
oc -n openshift-local-storage get pods

# LocalVolumeSet status
oc -n openshift-local-storage get localvolumesets
oc -n openshift-local-storage describe localvolumeset sno-local-fs

# New StorageClass and PVs
oc get storageclass | grep sno-local
oc get pv

# Test PVC
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lso-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: sno-local-fs
  resources:
    requests:
      storage: 10Gi
EOF

oc get pvc lso-test-pvc -n default
```

If the PVC stays **Pending**, describe the PVC and the `LocalVolumeSet` for events; common causes are no matching free disk, overly broad or overly narrow `deviceInclusionSpec`, or the wrong node name in `nodeSelector`.

---

## 7. Set default StorageClass (optional)

If you want PVCs without `storageClassName` to use local storage:

```bash
oc patch storageclass sno-local-fs -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Remove the default from other classes if more than one is marked default.

---

## 8. Related documentation in this repository

| Document | Topic |
|----------|--------|
| [REGISTRY_STORAGE_SETUP_PLAN.md](REGISTRY_STORAGE_SETUP_PLAN.md) | Image registry PVC / S3 after storage exists |
| [ADD_CATALOG_SOURCE_DISCONNECTED.md](ADD_CATALOG_SOURCE_DISCONNECTED.md) | Operator catalogs in disconnected environments |
| [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md) | SNO bare-metal install context |

---

## 9. References (Red Hat)

- [Persistent storage using local volumes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/storage/persistent-storage-using-local-volumes) — Local Storage Operator, `LocalVolumeSet`, `LocalVolume`
- [Post-installation cluster tasks](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/postinstallation_configuration/post-install-cluster-tasks) — general day-2 configuration

Adjust the documentation version in the URL if your cluster is not on OpenShift 4.20.
