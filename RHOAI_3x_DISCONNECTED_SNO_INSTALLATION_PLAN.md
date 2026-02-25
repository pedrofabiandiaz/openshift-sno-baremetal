# RHOAI 3.x Installation Plan: Disconnected Environment — One SNO + One Worker Node (HP Servers with A100 GPUs)

This document outlines the steps, prerequisites, official documentation links, and risks for installing **Red Hat OpenShift AI (RHOAI) 3.x** in a **disconnected** environment on a **two-node cluster: one Single-Node OpenShift (SNO) control plane plus one worker node**, using **two HP servers with NVIDIA A100 GPUs**.

---

## Table of Contents

1. [Architecture and Scope](#1-architecture-and-scope)
2. [Prerequisites](#2-prerequisites)
3. [High-Level Procedure (Document Order)](#3-high-level-procedure-document-order)
4. [Detailed Steps with Documentation Links](#4-detailed-steps-with-documentation-links)
5. [Risks, Issues, and Mitigations](#5-risks-issues-and-mitigations)
6. [Checklists](#6-checklists)
7. [References](#7-references)

---

## 1. Architecture and Scope

### 1.1 Two HP Servers with A100 GPUs — Chosen Topology: One SNO + One Worker Node

- **Chosen topology – One SNO + one worker node:** Install OpenShift with **one control plane node (SNO-style)** on the first HP server and **one worker node** on the second HP server. Both nodes are part of the same cluster. The control plane node runs cluster services and can also run workloads; the worker node runs RHOAI and other workloads. This satisfies RHOAI’s “minimum 2 worker nodes” recommendation (the SNO acts as control plane + worker, and the second node is a dedicated worker). Artifactory (and scan/quarantine if needed) runs elsewhere in the disconnected network (e.g. on a separate host or service).
- **Alternative – Two separate SNOs:** Run two independent SNO clusters (one per server); each would need its own registry and separate RHOAI installs. Not used in this plan.

The rest of this document assumes **one SNO (control plane) + one worker node** on the two HP servers.

### 1.2 Disconnected Environment

- No internet access from the OpenShift cluster or (typically) from the private registry.
- All container images must be brought into the disconnected environment via a **manual image pipeline**: images are **pulled by script** on a connected host, then **scanned**, **quarantined**, and only after approval **manually imported to Artifactory**. The cluster consumes images from Artifactory.
- **oc-mirror is not used** in this environment; image list derivation, pull, scan, quarantine, and import are done outside of oc-mirror.
- **Operator installation** is done by applying **Kustomize artifacts** from a **separate repository** that contains the CRs (Custom Resources) required to install and configure the operators (e.g. Subscriptions, OperatorGroups, and operator instance CRs). This repository is provided separately; you apply it with `kustomize build | oc apply -f -` or equivalent after the cluster is configured to use Artifactory.

---

## 2. Prerequisites

### 2.1 Red Hat and Subscriptions

| Item | Requirement |
|------|-------------|
| **Red Hat account** | With access to [Red Hat OpenShift Cluster Manager](https://console.redhat.com/openshift/) and pull secret |
| **OpenShift subscription** | Valid subscription for OpenShift Container Platform |
| **RHOAI subscription** | **Red Hat OpenShift AI Self-Managed** subscription (contact Red Hat account manager or [request contact](https://www.redhat.com/en/contact/)) |
| **Pull secret** | From [console.redhat.com/openshift/install/pull-secret](https://console.redhat.com/openshift/install/pull-secret); must include Artifactory (and any source registry) credentials for pull and push |

### 2.2 OpenShift Cluster

| Item | Requirement |
|------|-------------|
| **OpenShift version** | **4.20** (stable release); required for RHOAI 3.x and for features such as Distributed Inference with llm-d |
| **Installation** | Cluster installed in disconnected mode with **one control plane node (SNO) + one worker node**; see [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md) and OpenShift docs for 2-node / SNO + worker install on HP bare metal |
| **Network** | Disconnected/restricted network; both nodes and Artifactory (private registry) must be reachable from each other |
| **Cluster admin** | Identity provider configured; **cluster-admin** user (not `kubeadmin`) — see [Creating a cluster admin](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/authentication_and_authorization/using-rbac#creating-cluster-admin_using-rbac) |

### 2.3 Cluster Node Requirements (One SNO + One Worker Node)

| Node | CPU | Memory | Storage | GPU |
|------|-----|--------|---------|-----|
| **Control plane (SNO)** | **32 vCPUs** min | **128 GiB RAM** min | Sufficient for OCP control plane + workloads; default storage class with dynamic provisioning | NVIDIA A100 (data center–grade); drivers via NVIDIA GPU Operator |
| **Worker** | **8 vCPUs** min (32+ recommended for RHOAI workloads) | **32 GiB RAM** min (64+ recommended for RHOAI) | Sufficient for workloads; default storage class | NVIDIA A100; drivers via NVIDIA GPU Operator |

> **Note:** RHOAI requires a minimum of **2 worker nodes** (8 CPUs, 32 GiB RAM each) for installing the Operator, or a **single-node** with 32 CPUs and 128 GiB RAM. With **one SNO + one worker node**, you have two nodes that can run workloads (the SNO is control plane + worker, plus one dedicated worker), which satisfies the 2-node requirement. Size both HP servers accordingly.

### 2.4 Image Acquisition Host (Internet-Connected)

Used to **pull** images only; oc-mirror is **not** used. This host runs the pull script and feeds the scan/quarantine pipeline.

| Item | Requirement |
|------|-------------|
| **OS** | Linux (script execution environment) |
| **Disk** | At least **100 GB** free for pulled images and working directories (RHOAI image set is large) |
| **Network** | Access to: `quay.io`, `registry.redhat.io`, `registry.access.redhat.com` (and optionally `subscription.rhn.redhat.com`, `cdn.redhat.com` for tooling) |
| **Tools** | Script to pull images (e.g. `skopeo`, `podman`, or `crane`); image list derived from [imageset-rhoai.yaml](imageset-rhoai.yaml) or [rhoai-disconnected-install-helper](https://github.com/red-hat-data-services/rhoai-disconnected-install-helper) |
| **Credentials** | Red Hat pull secret (for source registries); no direct push to Artifactory from this host if scan/quarantine runs elsewhere |

### 2.5 Scan, Quarantine, and Artifactory (Disconnected Side)

Images are **scanned** and **quarantined** before being **manually imported** into Artifactory. The OpenShift cluster uses Artifactory as its sole source for disconnected images.

| Item | Requirement |
|------|-------------|
| **Scanning** | Vulnerability/compliance scans on all pulled images before they are approved for import (tooling and policy are organization-specific) |
| **Quarantine** | Quarantine area or registry where images reside after pull and scan until approved; only approved images are promoted/imported to Artifactory |
| **Artifactory** | **Target registry** inside the disconnected network; reachable by **both** the control plane node and the worker node. Repository type and layout must support OCI/container images and the paths expected by OpenShift (see [Risks](#5-risks-issues-and-mitigations)). |
| **Storage** | Enough to hold platform, operator, and RHOAI images (tens to hundreds of GB); plus quarantine space as needed |

> **Constraint:** In this plan, **oc-mirror is not used**. Images are obtained via a **script** (pull from source registries), then **scanned**, **quarantined**, and **manually imported to Artifactory**. The cluster is configured to pull only from Artifactory.

### 2.6 Storage and Identity

- **Default StorageClass** with dynamic provisioning (required for RHOAI). Verify with: `oc get storageclass`.
- **Identity:** Use an IdP and a user with `cluster-admin`; **kubeadmin is not allowed** for RHOAI.
- **Open Data Hub:** Must **not** be installed on the cluster (RHOAI 3.x replaces it).

### 2.7 MetalLB (Required for Bare Metal LoadBalancer Services)

On bare metal (no cloud load balancer), **MetalLB** is required so that Kubernetes `LoadBalancer`-type Services receive external IPs. RHOAI uses LoadBalancer services (e.g. dashboard, model serving). The [imageset-rhoai.yaml](imageset-rhoai.yaml) in this repo includes the **metallb-operator** package; ensure its images are in your Artifactory image set.

| Item | Requirement |
|------|-------------|
| **Operator** | MetalLB Operator installed via the **Kustomize repository** (with other operators); catalog backed by Artifactory |
| **When to install** | As part of the operator Kustomize apply (Step 5) — **before** or **with** RHOAI so LoadBalancer services get IPs as soon as RHOAI creates them |
| **Configuration** | Create at least one **IPAddressPool** (or legacy AddressPool) with a range of IPs in your network that are routable to the cluster nodes; optionally configure BGP if you use it |
| **IP range** | Choose an IP range that does not overlap with cluster `machineNetwork`, service network, or other in-use ranges; ensure the range is reserved for MetalLB in your network plan |

### 2.8 Optional but Common for A100 / RHOAI

- **Object storage** (S3-compatible): For AI pipelines, model serving, workbenches, Kueue-based workloads.
- **NVIDIA GPU Operator:** Installed via catalog (e.g. from mirrored `gpu-operator-certified`); required for GPU workloads.
- **Node Feature Discovery (NFD) Operator:** For GPU/node feature discovery.
- **cert-manager:** Required for model serving (KServe) and other components.

### 2.9 Operator Installation (Kustomize Repository)

Operators (RHOAI, MetalLB, NFD, GPU Operator, and other dependencies) are **not** installed manually via the web console one-by-one. A **separate repository** is provided that contains **Kustomize** artifacts defining the CRs (Custom Resources) required to:

- Install the operators (e.g. **Subscription**, **OperatorGroup**) from the Artifactory-backed catalog.
- Configure operator instances (e.g. MetalLB **MetalLB** instance and **IPAddressPool**, RHOAI **DataScienceCluster** or component CRs).

| Item | Requirement |
|------|-------------|
| **Repository** | Separate repository with Kustomize overlays/directories for each operator or a combined overlay for the full stack. |
| **Contents** | Manifests for Subscriptions (and OperatorGroups where needed), plus any CRs needed after the operator is installed (e.g. MetalLB address pool, RHOAI component config). |
| **Apply order** | Apply in the order required by dependencies (e.g. MetalLB and NFD before or with RHOAI; cert-manager before model serving). Use `kustomize build <overlay> \| oc apply -f -` or `oc apply -k <overlay>`. |
| **Customization** | Overlays or vars for environment-specific values (e.g. MetalLB IP range, RHOAI namespace, channel). |

---

## 3. High-Level Procedure (Document Order)

Execute in this order. **Image flow is script-based: pull → scan → quarantine → manual import to Artifactory** (no oc-mirror).

1. **Confirm cluster requirements** — OpenShift 4.20, resources, storage, identity, no ODH.
2. **Derive image list** — Build the list of images to pull from [imageset-rhoai.yaml](imageset-rhoai.yaml) and/or [rhoai-disconnected-install-helper](https://github.com/red-hat-data-services/rhoai-disconnected-install-helper) (operators + additional images); include platform images if not already in Artifactory.
3. **Pull images by script** — On the connected host, run a script that pulls each image (e.g. with `skopeo copy` or equivalent) from source registries to local storage or to a staging registry.
4. **Scan images** — Run your organization’s vulnerability/compliance scans on all pulled images.
5. **Quarantine** — Keep images in quarantine until scan results are reviewed and approved.
6. **Import to Artifactory** — Manually (or via approved automation) import only approved images from quarantine into Artifactory, preserving tags/digests and repository paths required by OpenShift and RHOAI.
7. **Configure cluster to use Artifactory** — In the disconnected environment: ImageDigestMirrorSet / ImageContentSourcePolicy so the cluster pulls from Artifactory; create CatalogSource(s) for operators if not already defined in the Kustomize repo (see [Step 4](#step-4-configure-cluster-to-use-artifactory) and [Risks](#5-risks-issues-and-mitigations)).
8. **Install and configure operators via Kustomize** — Apply the provided **Kustomize repository** to install and configure the required operators (MetalLB, RHOAI, NFD, GPU Operator, etc.) and their CRs. This includes MetalLB Operator + IPAddressPool (or AddressPool) for LoadBalancer services, and the Red Hat OpenShift AI Operator (channel **fast-3.x**) plus any dependency operators. Apply in the order defined by the repository (see [Step 5](#step-5-install-and-configure-operators-via-kustomize)).
9. **Install OpenShift AI components** — Create/configure the OpenShift AI instance and enable desired components (workbenches, pipelines, Kueue, model serving, etc.), either via the same Kustomize repo (CRs for DataScienceCluster/components) or via console/CLI.
11. **Configure cluster for disconnected** — Samples Operator for restricted network; user/administrator groups; any component-specific config (object storage, custom namespaces, etc.).
12. **Enable and verify GPUs** — NVIDIA GPU Operator, NFD, and optional KMM; verify A100s are visible and usable by RHOAI.

---

## 4. Detailed Steps with Documentation Links

### Step 1: Confirm OpenShift Cluster Requirements

- **Procedure:** [Requirements for OpenShift AI Self-Managed](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/deploying-openshift-ai-in-a-disconnected-environment_install#requirements-for-openshift-ai-self-managed_install) (disconnected guide, Section 3.1).
- **Check:** OCP 4.20; control plane node (SNO) with 32 CPUs / 128 GiB RAM, worker node with at least 8 CPUs / 32 GiB RAM (more recommended for RHOAI); default StorageClass; IdP and cluster-admin user; no ODH.
- **Restricted network:** [Configuring Samples Operator for a restricted cluster](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/images/configuring-samples-operator#samples-operator-restricted-network-install).

### Step 2: Derive Image List and Pull Images by Script

Because **oc-mirror is not used**, you must obtain the list of images from another source and pull them with a script.

- **Image list source:** Use this repo’s [imageset-rhoai.yaml](imageset-rhoai.yaml) and/or the [rhoai-disconnected-install-helper](https://github.com/red-hat-data-services/rhoai-disconnected-install-helper) to get the full set of image references (operator catalog images, RHOAI operator, NFD, GPU Operator, and all `additionalImages` such as MODH notebooks). Red Hat’s disconnected doc describes the required set: [Mirroring images to a private registry for a disconnected installation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/deploying-openshift-ai-in-a-disconnected-environment_install#mirroring-images-to-a-private-registry-for-a-disconnected-installation_install).
- **Script:** Implement or use a script that, given the image list, pulls each image from source registries (e.g. `quay.io`, `registry.redhat.io`) using `skopeo copy`, `podman pull` + save, or `crane copy`. Use Red Hat pull secret for authentication. Output can be to a directory (OCI layout or tar) or to a staging registry.
- **Scope:** Include platform (OCP) images if not already in Artifactory; include all operators and additional images required for RHOAI 3.x. The list is large; ensure sufficient disk and stable networking.

### Step 3: Scan, Quarantine, and Manually Import to Artifactory

- **Scan:** Run your organization’s container image scans (vulnerability/compliance) on every pulled image. No Red Hat–specific procedure; use your existing scan tooling and policies.
- **Quarantine:** Keep images in a quarantine area or registry until scans are reviewed and approved. Only approved images should be eligible for import to Artifactory.
- **Manual import to Artifactory:** For each approved image, push/copy it into Artifactory preserving the repository path and tag/digest that OpenShift and the RHOAI Operator will expect (e.g. same path structure as in `registry.redhat.io`, `quay.io`, etc., or align ImageDigestMirrorSet/ICSP and CatalogSource to your Artifactory layout). Use `skopeo copy`, Artifactory’s import UI/API, or your approved transfer process.
- **Catalog sources:** oc-mirror normally generates CatalogSource manifests; without it, you must either build and host an operator catalog image in Artifactory and create a CatalogSource pointing at it, or install operators from bundle/custom catalog. See [Risks](#5-risks-issues-and-mitigations) and Step 4.

### Step 4: Configure Cluster to Use Artifactory

- **Transfer (if needed):** Any install tools or config (e.g. IDMS/ICSP manifests) into the disconnected environment via your approved transfer method.
- **Image pull configuration:** Create **ImageDigestMirrorSet** (or ImageContentSourcePolicy on older OCP) so that pulls for `registry.redhat.io`, `quay.io`, etc. are redirected to your Artifactory host and repository paths. Add **additionalTrustBundle** if Artifactory uses a custom CA.
- **Pull secret:** Ensure the cluster’s pull secret includes Artifactory credentials (and any other registries the cluster needs to pull from).
- **CatalogSource:** Create a CatalogSource that references the operator catalog image in Artifactory (if you built one), or include it in the **Kustomize repository** (see §2.9 and Step 5) so it is applied with the rest of the operator CRs.

### Step 5: Install and Configure Operators via Kustomize

Operators (MetalLB, RHOAI, NFD, GPU Operator, and dependencies) are installed and configured by applying a **separate repository of Kustomize artifacts** that define the required CRs (Subscriptions, OperatorGroups, and operator instance CRs such as MetalLB IPAddressPool and RHOAI component config).

- **Repository:** Use the provided **operators Kustomize repository**. It contains (or references) the CRs needed for:
  - **MetalLB** — Subscription (and OperatorGroup if needed), MetalLB instance, and **IPAddressPool** (or AddressPool) with the IP range for LoadBalancer services. Required so RHOAI dashboard and other LoadBalancer services get external IPs on bare metal.
  - **Red Hat OpenShift AI Operator** — Subscription (channel **fast-3.x**), and optionally the CRs to create the DataScienceCluster or enable components.
  - **Dependency operators** — NFD, GPU Operator, cert-manager, Kueue, Service Mesh, etc., as required by your RHOAI components.
- **Apply:** From the repository root or the appropriate overlay, run `kustomize build <overlay> | oc apply -f -` or `oc apply -k <overlay>`. Apply in the order specified by the repository (e.g. MetalLB and NFD before RHOAI if dependencies are layered).
- **Customization:** Set environment-specific values (e.g. MetalLB IP range, Artifactory catalog source name, namespaces) via Kustomize overlays, `configMapGenerator`, or replacement/patches in the repo.
- **MetalLB reference:** [Installing the MetalLB Operator (OKD 4.20)](https://docs.okd.io/4.20/networking/networking_operators/metallb-operator/metallb-operator-install.html), [Configuring MetalLB address pools (OKD 4.20)](https://docs.okd.io/4.20/networking/ingress_load_balancing/metallb/metallb-configure-address-pools.html). The Kustomize repo should emit equivalent CRs.
- **Verify:** Operators become ready (`oc get csv` or Installed Operators in console); MetalLB assigns IPs to LoadBalancer Services (`oc get svc -A | grep LoadBalancer`); RHOAI Operator is installed and components can be enabled.

### Step 6: Install OpenShift AI Components (if not in Kustomize)

If the operators Kustomize repository does **not** include the CRs that create the OpenShift AI instance or enable components (workbenches, pipelines, model serving, etc.), create them manually:

- **Procedure:** [Installing and managing Red Hat OpenShift AI components](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/deploying-openshift-ai-in-a-disconnected-environment_install#installing-and-managing-openshift-ai-components_component-install).
- Enable the components you need: workbenches, AI Pipelines, Kueue-based workloads, model serving (KServe), etc. Dependency operators (cert-manager, Kueue, Service Mesh, GPU Operator, NFD) should already be installed via the Kustomize repo (Step 5); if not, add them to the repo or install separately as per the [Requirements](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/deploying-openshift-ai-in-a-disconnected-environment_install#requirements-for-openshift-ai-self-managed_install) and component docs.

### Step 7: Configure Users and Post-Install

- **Dashboard:** [Accessing the OpenShift AI dashboard](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/accessing-the-dashboard_install).
- **Users/groups:** [Adding users to OpenShift AI user groups](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/managing_openshift_ai/managing-users-and-groups#adding-users-to-user-groups_managing-rhoai).

### Step 8: Enable and Verify NVIDIA A100 GPUs

- **Enabling GPUs:** [Enabling NVIDIA GPUs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/working_with_accelerators/enabling-nvidia-gpus_accelerators).
- **Accelerators overview:** [Provision hardware configurations and resources for data science projects](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html-single/working_with_accelerators/index).
- **Supported configs:** [Red Hat OpenShift AI: Supported Configurations for 3.x](https://access.redhat.com/articles/rhoai-supported-configs-3.x) (Customer Portal).
- Install **NVIDIA GPU Operator** and **Node Feature Discovery** from the catalog that uses Artifactory; ensure A100s are detected on **both** the control plane and worker nodes and that workloads can request GPUs and schedule on the worker (and control plane if desired).

---

## 5. Risks, Issues, and Mitigations

| Risk / Issue | Mitigation |
|--------------|------------|
| **Control plane single point of failure** | With one SNO (control plane) + one worker, the control plane is still a single point of failure; the worker adds capacity for workloads. Accept for dev/test/edge or use a full multi-control-plane cluster for production HA. |
| **RHOAI “2 worker nodes”** | With **one SNO + one worker node**, you have two nodes that can run workloads (SNO is cp+worker, plus one dedicated worker), which satisfies RHOAI’s minimum. Size control plane node at 32 CPU / 128 GiB RAM, worker at 8+ CPU / 32+ GiB RAM (or higher for heavy RHOAI use). |
| **No oc-mirror** | Image list must be derived manually from [imageset-rhoai.yaml](imageset-rhoai.yaml) or rhoai-disconnected-install-helper. Operator catalog image must be built or obtained separately and passed through scan/quarantine and imported to Artifactory. Operator installation is done via the **provided Kustomize repository** (CRs for Subscriptions, OperatorGroups, and instance CRs); CatalogSource can be part of that repo or created separately. |
| **Scan and quarantine delay** | Pull → scan → quarantine → import can add significant time and gates. Plan cycles for scan results, approval, and import; avoid assuming “mirror run”–style one-shot completion. |
| **Artifactory layout and OpenShift** | ImageDigestMirrorSet/ICSP must map source registry paths to Artifactory paths correctly. Operator catalog in Artifactory must be OCI-compliant and referenced by CatalogSource. Verify Artifactory supports the pull patterns OpenShift and OLM use (e.g. by digest, tag, and multi-arch). |
| **Image list completeness** | RHOAI requires many images (operators + notebooks). Ensure the script’s image list includes every image referenced by the chosen RHOAI version and operators; missing images will cause install or runtime failures. |
| **kubeadmin not allowed** | Configure an IdP and a cluster-admin user before installing RHOAI. |
| **No upgrade from 2.x to 3.0** | RHOAI 3.0 is new-install only. No in-place upgrade from 2.25 or earlier. See [Why upgrades to OpenShift AI 3.0 are not supported](https://access.redhat.com/articles/7133758). |
| **Default StorageClass** | Ensure a default StorageClass exists before installing RHOAI; fix with [Changing the default storage class](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/storage/dynamic-provisioning#change-default-storage-class_dynamic-provisioning) if needed. |
| **Samples Operator in disconnected** | Configure Samples Operator for restricted network after install so it uses the mirror registry. |
| **A100 driver and compatibility** | Use the **NVIDIA GPU Operator** from the mirrored catalog (e.g. `gpu-operator-certified`); ensure OpenShift and RHCOS versions are supported for the driver version shipped by the operator. |
| **MetalLB IP pool** | Choose an IP range for MetalLB that does not overlap with cluster `machineNetwork`, service network (172.30.0.0/16), or existing DHCP/static assignments. Ensure the range is routable to both nodes. Too small a pool can exhaust IPs as RHOAI creates LoadBalancer services. |
| **DNS in private/restricted clouds** | In environments without integrated external DNS (e.g. OpenStack, CRC), you may need to configure DNS after the LoadBalancer IP is known: [Configuring External DNS for RHOAI 3.x on OpenStack and Private Clouds](https://access.redhat.com/articles/7133770). |
| **Object storage** | Pipelines, model serving, and workbenches often need S3-compatible object storage; plan and configure it per component. |
| **Two servers in cluster** | Both HP servers are cluster nodes (control plane + worker). Artifactory runs elsewhere in the disconnected network. Ensure network and firewall allow **both** the control plane node and the worker node to reach Artifactory. |

---

## 6. Checklists

### Pre-Install (Cluster and Environment)

- [ ] OpenShift 4.20 installed and running (disconnected) with **one control plane node (SNO) + one worker node**.
- [ ] Control plane node has ≥32 vCPUs and ≥128 GiB RAM; worker node has ≥8 vCPUs and ≥32 GiB RAM (or higher for RHOAI).
- [ ] Default StorageClass present; dynamic provisioning works.
- [ ] Identity provider configured; cluster-admin user exists (not relying on kubeadmin).
- [ ] Open Data Hub not installed.
- [ ] Artifactory deployed in disconnected network and reachable from the cluster.
- [ ] Cluster configured to use Artifactory (ImageDigestMirrorSet/ICSP and CatalogSource applied).

### Operators (Kustomize repository)

- [ ] **Operators Kustomize repository** available (separate repo with Kustomize artifacts for operator CRs).
- [ ] CatalogSource(s) for Artifactory-backed catalog applied (from repo or manually).
- [ ] Kustomize overlay applied in correct order; MetalLB Operator + IPAddressPool (or AddressPool) configured; RHOAI Operator (fast-3.x) and dependency operators (NFD, GPU Operator, etc.) installed.
- [ ] LoadBalancer Services receive external IPs from MetalLB (`oc get svc -A | grep LoadBalancer`).

### Image Pipeline (Script → Scan → Quarantine → Artifactory)

- [ ] Image list derived from [imageset-rhoai.yaml](imageset-rhoai.yaml) and/or rhoai-disconnected-install-helper (platform if needed, rhods-operator, NFD, GPU Operator, and all RHOAI additional images).
- [ ] Pull script runs successfully on connected host; all images pulled to staging/quarantine.
- [ ] Scans run on all pulled images; results reviewed.
- [ ] Approved images only: manually imported to Artifactory with correct paths/tags/digests.
- [ ] Operator catalog image (if used) built/obtained, scanned, quarantined, and imported to Artifactory; CatalogSource created.

### RHOAI Install

- [ ] Operators (MetalLB, RHOAI, NFD, GPU Operator, etc.) installed and configured via the **Kustomize repository** (see [Step 5](#step-5-install-and-configure-operators-via-kustomize)); MetalLB provides IPs for LoadBalancer services.
- [ ] Red Hat OpenShift AI Operator installed (channel fast-3.x) via Kustomize CRs.
- [ ] OpenShift AI components installed and configured (workbenches, pipelines, serving, etc.), via Kustomize repo or console/CLI.
- [ ] User and administrator groups configured; dashboard accessible.
- [ ] Samples Operator configured for restricted network.

### GPU (A100)

- [ ] NVIDIA GPU Operator and NFD installed (via Kustomize repo) and running.
- [ ] A100(s) detected on both nodes (e.g. `nvidia-smi` in a test pod or node labels).
- [ ] RHOAI workbenches or workloads can request GPUs and run on the worker (and control plane if configured).

---

## 7. References

| Topic | Link |
|-------|------|
| **RHOAI 3.0 disconnected (main guide)** | [Deploy or decommission OpenShift AI in disconnected environments](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/) |
| **RHOAI 3.2 docs** | [Red Hat OpenShift AI Self-Managed 3.2](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/) |
| **OpenShift 4.20 SNO** | [Installing on a single node](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installing_on_a_single_node/) |
| **OpenShift 4.20 – adding workers / 2-node** | [Adding compute nodes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installing_on_bare_metal/installing-restricted-network-baremetal) or platform-specific install (bare metal, etc.) for control plane + worker topology |
| **OpenShift 4.20 disconnected** | [Disconnected environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/) |
| **OpenShift / OKD 4.20 MetalLB** | [MetalLB Operator install (OKD 4.20)](https://docs.okd.io/4.20/networking/networking_operators/metallb-operator/metallb-operator-install.html), [MetalLB address pools (OKD 4.20)](https://docs.okd.io/4.20/networking/ingress_load_balancing/metallb/metallb-configure-address-pools.html) — use for bare metal LoadBalancer; OCP docs under Networking if available for your release |
| **RHOAI image list (no oc-mirror)** | [Mirroring images for disconnected RHOAI](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/deploying-openshift-ai-in-a-disconnected-environment_install#mirroring-images-to-a-private-registry-for-a-disconnected-installation_install) (required image set); [rhoai-disconnected-install-helper](https://github.com/red-hat-data-services/rhoai-disconnected-install-helper); this repo’s [imageset-rhoai.yaml](imageset-rhoai.yaml) |
| **Manual image copy (skopeo, etc.)** | [Copying images to a registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/openshift_images/copying-images-to-registry) (e.g. `oc image mirror` / skopeo) for reference when building your pull script |
| **RHOAI supported configs 3.x** | [Supported Configurations for 3.x](https://access.redhat.com/articles/rhoai-supported-configs-3.x) |
| **RHOAI 3.0 upgrade not supported** | [Why upgrades to OpenShift AI 3.0 are not supported](https://access.redhat.com/articles/7133758) |
| **RHOAI disconnected install helper** | [rhoai-disconnected-install-helper](https://github.com/red-hat-data-services/rhoai-disconnected-install-helper) |
| **This repo – SNO + worker + disconnected** | [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md), [imageset-rhoai.yaml](imageset-rhoai.yaml) |
| **Operators (Kustomize)** | A **separate repository** is provided with Kustomize artifacts for the CRs required to install and configure operators (Subscriptions, OperatorGroups, MetalLB, RHOAI, NFD, GPU Operator, etc.). Apply with `kustomize build \| oc apply -f -` or `oc apply -k` in the order defined by the repo. |

---

*This plan is for planning and preparation; always follow the official Red Hat documentation for the exact procedures and versions applicable to your release.*
