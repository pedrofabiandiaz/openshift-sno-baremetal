# Adding Catalog Source to OpenShift in a Disconnected Environment

This document describes how to add **CatalogSource** resources to an OpenShift cluster in a disconnected (air-gapped) environment. CatalogSources tell the Operator Lifecycle Manager (OLM) where to find operator catalogs—in a disconnected cluster, they must point to your mirror registry instead of `registry.redhat.io` or `quay.io`.

---

## 1. Overview

### 1.1 What is a CatalogSource?

A **CatalogSource** is a Kubernetes resource that defines an operator catalog for OLM. It specifies:

- The registry and image containing the catalog index
- The catalog type (typically `grpc` for OLM)
- Display name and publisher

In a disconnected environment, the catalog image must be hosted in your mirror registry (e.g., Quay, Harbor, Mirror Registry for Red Hat OpenShift, Artifactory).

### 1.2 Why CatalogSource in Disconnected?

| Environment | Default behavior |
|-------------|------------------|
| **Connected** | OLM uses default CatalogSources pointing to `registry.redhat.io` and `quay.io` |
| **Disconnected** | Cluster cannot reach Red Hat registries. You must provide CatalogSources that point to your mirror registry |

Without a CatalogSource pointing at your mirror, you cannot install operators from the OpenShift Console or via `oc`/`kubectl` Subscriptions.

### 1.3 Two Scenarios

| Scenario | How CatalogSource is obtained |
|----------|-------------------------------|
| **oc-mirror** | oc-mirror generates CatalogSource manifests in `working-dir/cluster-resources/`. Apply them to the cluster. |
| **Manual / other registry** | Mirror the catalog image to your registry, then create a CatalogSource YAML that references it. |

---

## 2. Prerequisites

| Item | Requirement |
|------|-------------|
| **Cluster** | OpenShift cluster installed and running (SNO or multi-node) |
| **Mirror registry** | Deployed in your disconnected network, reachable by the cluster |
| **Catalog images** | Operator catalog(s) mirrored to your registry (via oc-mirror or other method) |
| **IDMS/ITMS** | ImageDigestMirrorSet (or ImageContentSourcePolicy) applied so the cluster pulls from your mirror |
| **Pull secret** | Cluster pull secret includes credentials for your mirror registry |
| **additionalTrustBundle** | If the mirror uses a self-signed certificate, the mirror CA must be in the cluster trust bundle |

---

## 3. Method A: Apply CatalogSource from oc-mirror

When you use **oc-mirror** to mirror images, it generates CatalogSource manifests (and IDMS/ITMS) in the `cluster-resources` directory.

### 3.1 oc-mirror Output Structure

After running oc-mirror, the output typically looks like:

```
/path/to/mirror-dir/
├── mirror_seq.sqlite
└── working-dir/
    └── cluster-resources/
        ├── image-digest-mirror-set-*.yaml
        ├── image-tag-mirror-set-*.yaml  (if used)
        ├── catalogsource-*.yaml
        ├── cluster-catalog-*.yaml
        └── signature-configmap.json     (if release signing)
```

### 3.2 Apply Cluster Resources

From a host that can reach the cluster (administration host with `KUBECONFIG`):

```bash
export KUBECONFIG=/path/to/auth/kubeconfig

# Apply all cluster resources (IDMS, ITMS, CatalogSource, etc.)
oc apply -f /path/to/working-dir/cluster-resources/

# If release signatures exist
oc apply -f /path/to/working-dir/cluster-resources/signature-configmap.json
```

### 3.3 Verify

```bash
oc get catalogsource -n openshift-marketplace
oc get imagedigestmirrorset
oc get imagetagmirrorset
```

---

## 4. Method B: Manually Create CatalogSource

Use this method when:

- You did **not** use oc-mirror (e.g., you used a different mirroring workflow, Artifactory, or custom scripts)
- You need to add or customize a CatalogSource
- You are pointing at a catalog image you built or imported separately

### 4.1 Catalog Image Location

Your mirror registry must host the operator catalog index image. Typical paths after oc-mirror or equivalent:

| Catalog | Typical mirror path |
|---------|----------------------|
| Red Hat operators | `<mirror-registry>/olm/redhat-operators:v<tag>` |
| Certified operators | `<mirror-registry>/olm/certified-operators:v<tag>` |
| Community operators | `<mirror-registry>/olm/community-operators:v<tag>` |

Example: `registry.disconnected.example.com:5000/olm/redhat-operators:v1`

### 4.2 Create CatalogSource YAML

Create a file `catalogsource-redhat-operators.yaml`:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: <mirror-registry>/olm/redhat-operators:v1
  displayName: Red Hat Operators (Disconnected)
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 30m
```

Replace `<mirror-registry>` with your actual registry (e.g. `registry.disconnected.example.com:5000`).

### 4.3 Multiple CatalogSources

If you have certified operators as well:

```yaml
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: certified-operators
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: <mirror-registry>/olm/certified-operators:v1
  displayName: Certified Operators (Disconnected)
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 30m
```

### 4.4 Apply

```bash
oc apply -f catalogsource-redhat-operators.yaml
oc apply -f catalogsource-certified-operators.yaml  # if used
```

---

## 5. Disable Default OperatorHub Sources

In a disconnected cluster, the default CatalogSources (which point to Red Hat registries) will fail. Disable them by configuring the OperatorHub cluster:

```bash
oc patch operatorhub cluster --type merge -p '
spec:
  disableAllDefaultSources: true
'
```

Or patch individually to disable only the defaults you have replaced.

### 5.1 Verify Default Sources Disabled

```bash
oc get operatorhub cluster -o yaml
```

---

## 6. Self-Signed Certificate (additionalTrustBundle)

If your mirror registry uses a **self-signed certificate**, the cluster must trust it.

### 6.1 Add CA to Cluster Trust Bundle

```bash
# Create a configmap with the mirror registry CA certificate
oc create configmap registry-ca -n openshift-config \
  --from-file=ca-bundle.crt=/path/to/mirror-registry-ca.crt

# Patch the image config to reference the CA
oc patch image.config.openshift.io/cluster --type=merge -p '
spec:
  additionalTrustedCA:
    name: registry-ca
'
```

### 6.2 Restart Machine Config Pool (if needed)

After changing the trust bundle, nodes may need to drain/reboot. The cluster usually applies this automatically.

---

## 7. Verification

### 7.1 Check CatalogSource Status

```bash
oc get catalogsource -n openshift-marketplace
```

Expected: `READY` = `True` for your catalog(s).

### 7.2 Check CatalogSource Pod

```bash
oc get pods -n openshift-marketplace -l olm.catalogSource=<catalog-name>
```

The catalog runs as a pod that serves the catalog index via gRPC.

### 7.3 Install a Test Operator

From the OpenShift Console: **Operators** → **OperatorHub**. Your disconnected catalog(s) should appear. Try installing a simple operator to confirm.

---

## 8. Troubleshooting

| Issue | Possible Cause | Action |
|-------|----------------|--------|
| CatalogSource `READY` = False | Image pull failure | Check `oc describe catalogsource <name> -n openshift-marketplace`; verify IDMS, pull secret, and registry reachability |
| ImagePullBackOff on catalog pod | Cannot pull from mirror | Verify mirror URL, pull secret has mirror credentials, IDMS maps source to mirror |
| x509 certificate signed by unknown authority | Self-signed mirror CA | Add mirror CA to `additionalTrustBundle` (see Section 6) |
| Operators not appearing in OperatorHub | Default sources still enabled, or catalog not ready | Disable default sources; wait for CatalogSource to be READY |
| CatalogSource created but no operators shown | Catalog image empty or wrong format | Ensure catalog image is a valid OLM catalog index (e.g. from oc-mirror or `oc adm catalog build`) |

---

## 9. Checklist

- [ ] Mirror registry deployed and reachable from cluster
- [ ] Operator catalog(s) mirrored to registry (oc-mirror or equivalent)
- [ ] IDMS/ITMS applied so cluster pulls from mirror
- [ ] Pull secret includes mirror registry credentials
- [ ] additionalTrustBundle configured if mirror uses self-signed CA
- [ ] CatalogSource(s) applied (from oc-mirror or manually)
- [ ] Default OperatorHub sources disabled
- [ ] `oc get catalogsource` shows READY=True
- [ ] Test operator install from OperatorHub

---

## 10. References

- [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md) — OpenShift SNO install; Section 3.9 describes applying oc-mirror cluster resources
- [imageset-platform.yaml](imageset-platform.yaml), [imageset-rhoai.yaml](imageset-rhoai.yaml) — Example oc-mirror image set configs
- [OpenShift: Disconnected environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/) (Red Hat)
- [OpenShift: Mirroring images for a disconnected installation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/about-installing-oc-mirror-v2) (Red Hat)
- [oc-mirror plugin v2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/disconnected_environments/about-installing-oc-mirror-v2) (Red Hat)
