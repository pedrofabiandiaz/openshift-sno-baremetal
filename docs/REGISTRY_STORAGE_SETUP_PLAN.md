# OpenShift Image Registry Storage Setup Plan

This document describes how to configure the **OpenShift integrated image registry** with persistent storage. On bare metal and other user-provisioned platforms, the registry does not get storage automatically—you must configure it after installation.

Two storage options are covered:

| Option | Storage Type | Use Case |
|--------|--------------|----------|
| **Option 1: Local Storage** | PVC (PersistentVolumeClaim) using local or block storage | Single-node, small clusters; uses cluster storage |
| **Option 2: S3 Object Storage** | S3 or S3-compatible object storage | Scalable, shared storage; AWS, MinIO, Ceph RGW, OpenShift Data Foundation |

---

## 1. Overview

### 1.1 Registry State on Bare Metal

On bare metal (and platforms without built-in object storage), the Image Registry Operator installs in **Removed** state. The registry does not run until you:

1. Change `managementState` from `Removed` to `Managed`
2. Configure storage (PVC or S3)

### 1.2 Storage Requirements

| Requirement | Value |
|-------------|-------|
| **Minimum capacity** | 100 Gi |
| **Single replica (SNO)** | ReadWriteOnce (RWO) |
| **Multiple replicas (HA)** | ReadWriteMany (RWX) |

---

## 2. Prerequisites

| Item | Requirement |
|------|-------------|
| **Cluster** | OpenShift cluster installed and running |
| **Access** | `cluster-admin` role |
| **Storage** | Provisioned storage (for Option 1) or S3 bucket (for Option 2) |

---

## 3. Common Step: Enable the Registry

Before configuring storage, enable the Image Registry Operator:

```bash
oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
  --patch '{"spec":{"managementState":"Managed"}}'
```

> **Note:** If the config does not exist yet (e.g., cluster just installed), wait a few minutes and retry.

---

## 4. Option 1: Local Storage (PVC)

Use a **PersistentVolumeClaim** backed by local storage, block storage, or your default StorageClass. Suitable for SNO and small clusters.

### 4.1 Option 1A: Automatic PVC (Default StorageClass)

If your cluster has a **default StorageClass** (e.g., from Local Storage Operator, OpenShift Data Foundation, or another provisioner), you can let the registry create its own PVC:

```bash
oc edit configs.imageregistry.operator.openshift.io cluster
```

Ensure the storage section is:

```yaml
spec:
  storage:
    pvc:
      claim:   # Leave blank for automatic image-registry-storage PVC
```

The operator creates a PVC named `image-registry-storage` using the default StorageClass (minimum 100Gi).

### 4.2 Option 1B: Custom PVC (Explicit StorageClass)

Create a PVC with a specific StorageClass and size:

**Create `registry-pvc.yaml`:**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: image-registry-storage
  namespace: openshift-image-registry
  annotations:
    imageregistry.openshift.io: "true"
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: <your-storage-class>   # e.g. local-block, ocs-storagecluster-ceph-rbd
```

Apply and configure the registry to use it:

```bash
oc create -f registry-pvc.yaml

# Point the registry at the PVC
oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
  --patch '{"spec":{"storage":{"pvc":{"claim":"image-registry-storage"}}}}'
```

### 4.3 Option 1C: emptyDir (Non-Production Only)

For **non-production** clusters (e.g., lab, POC), you can use ephemeral storage. **All images are lost when the registry pod restarts.**

```bash
oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
  --patch '{"spec":{"storage":{"emptyDir":{}}}}'
```

> **Warning:** Do not use emptyDir for production. Use only for temporary or disposable clusters.

### 4.4 Single Replica and Recreate (Block Storage)

If using **block storage** (ReadWriteOnce, single replica), set the rollout strategy:

```bash
oc patch config.imageregistry.operator.openshift.io/cluster --type=merge \
  -p '{"spec":{"rolloutStrategy":"Recreate","replicas":1}}'
```

---

## 5. Option 2: S3 Object Storage

Use **S3** or **S3-compatible** object storage (AWS S3, MinIO, Ceph RGW, OpenShift Data Foundation NooBaa/MCG). Suitable for scalable, shared storage.

### 5.1 Create S3 Credentials Secret

Create a secret with S3 access credentials:

```bash
oc create secret generic image-registry-private-configuration-user \
  --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY=<access_key> \
  --from-literal=REGISTRY_STORAGE_S3_SECRETKEY=<secret_key> \
  --namespace openshift-image-registry
```

### 5.2 Configure Registry for S3

Edit the registry config:

```bash
oc edit configs.imageregistry.operator.openshift.io cluster
```

**For AWS S3:**

```yaml
spec:
  storage:
    s3:
      bucket: <bucket_name>
      region: <region_name>   # e.g. us-east-1
```

**For S3-compatible storage (MinIO, Ceph RGW, etc.):**

```yaml
spec:
  storage:
    s3:
      bucket: <bucket_name>
      region: us-east-1
      regionEndpoint: <s3_endpoint_url>
      virtualHostedStyle: false
```

### 5.3 S3 Endpoint Examples

| Backend | regionEndpoint Example |
|---------|------------------------|
| **AWS S3** | Omit (uses default AWS endpoints) |
| **MinIO** | `http://minio.example.com:9000` or `https://minio.example.com` |
| **Ceph RGW (ODF)** | `http://rook-ceph-rgw-ocs-storagecluster-cephobjectstore.openshift-storage.svc.cluster.local` |
| **OpenShift Data Foundation NooBaa** | Use the S3 endpoint from the ODF console or route |

> **Note:** For Ceph RGW, do **not** specify a port in the URL. Use the service DNS name only.

### 5.4 S3 Bucket Lifecycle (Recommended)

Configure a **bucket lifecycle policy** to abort incomplete multipart uploads older than one day. This avoids orphaned data and storage bloat.

**AWS S3 example:**

```json
{
  "Rules": [
    {
      "ID": "AbortIncompleteMultipartUpload",
      "Status": "Enabled",
      "Filter": {},
      "AbortIncompleteMultipartUpload": {
        "DaysAfterInitiation": 1
      }
    }
  ]
}
```

### 5.5 Self-Signed Certificate (S3-Compatible)

If your S3 endpoint uses a **self-signed certificate**, add the CA to the cluster trust bundle:

```bash
oc create configmap registry-ca -n openshift-config \
  --from-file=ca-bundle.crt=/path/to/s3-ca.crt

oc patch image.config.openshift.io/cluster --type=merge -p '
spec:
  additionalTrustedCA:
    name: registry-ca
'
```

Then reference the CA in the registry config:

```yaml
spec:
  storage:
    s3:
      bucket: <bucket_name>
      region: us-east-1
      regionEndpoint: https://minio.example.com
      trustedCA:
        name: registry-ca
```

---

## 6. Verification

### 6.1 Check Registry Operator Status

```bash
oc get clusteroperator image-registry
```

Expected: `AVAILABLE=True`, `DEGRADED=False`.

### 6.2 Check Registry Pod

```bash
oc get pods -n openshift-image-registry -l docker-registry=default
```

Expected: Pod running and Ready.

### 6.3 Check Storage (PVC)

For Option 1:

```bash
oc get pvc -n openshift-image-registry
```

Expected: PVC in `Bound` status.

### 6.4 Test Push

```bash
# Log in to the registry
oc whoami -t | podman login -u unused --password-stdin $(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')

# Pull, tag, and push a test image
podman pull quay.io/openshift/origin-hello-openshift
podman tag quay.io/openshift/origin-hello-openshift $(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')/openshift/hello:test
podman push $(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')/openshift/hello:test
```

---

## 7. Comparison Summary

| Aspect | Option 1: Local Storage (PVC) | Option 2: S3 Object Storage |
|--------|-------------------------------|------------------------------|
| **Complexity** | Lower | Higher (S3 setup, credentials) |
| **Scalability** | Limited by PVC size | Scales with bucket |
| **HA (multi-replica)** | Requires RWX storage | Native support |
| **Backup/DR** | PVC/volume backup | Bucket replication, versioning |
| **Typical use** | SNO, small clusters | Larger clusters, ODF, cloud |

---

## 8. Troubleshooting

| Issue | Possible Cause | Action |
|-------|----------------|--------|
| Registry pod not starting | No storage configured | Configure PVC or S3 (Sections 4 or 5) |
| PVC stuck Pending | No StorageClass or no PV | Create StorageClass/PV or use different storage |
| S3 access denied | Wrong credentials | Verify secret; check bucket policy |
| x509 certificate error (S3) | Self-signed CA | Add CA to additionalTrustBundle and trustedCA |
| Registry Degraded | Storage full or unreachable | Check PVC capacity; verify S3 endpoint |

---

## 9. References

- [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md) — OpenShift SNO install on bare metal
- [OpenShift: Setting up and configuring the registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/registry/setting-up-and-configuring-the-registry) (Red Hat)
- [OpenShift: Registry — Setting up and configuring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/registry/setting-up-and-configuring-the-registry) (Red Hat) — includes bare metal, AWS, S3
- [OpenShift Data Foundation: Registry with Ceph RGW](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/) (Red Hat)
