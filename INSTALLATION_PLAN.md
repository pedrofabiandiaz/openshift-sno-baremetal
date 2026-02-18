# OpenShift 4.20 Single-Node Bare Metal Installation Plan for HP Server

This document provides a step-by-step plan to install OpenShift Container Platform 4.20 as a Single-Node OpenShift (SNO) cluster on an HP ProLiant bare metal server.

---

## 1. Prerequisites & Requirements

### 1.1 HP Server Hardware Requirements

| Resource | Minimum | Recommended for Production |
|----------|---------|----------------------------|
| **CPU** | 8 vCPUs | 16+ vCPUs |
| **Memory** | 16 GB RAM | 32+ GB RAM |
| **Storage** | 120 GB | 200+ GB SSD |
| **Network** | 1 Gbps NIC | 10 Gbps NIC |
| **BMC** | iLO 5 or iLO 6 (Redfish) | iLO 6 (for Gen11+) |

> **Note:** One vCPU equals one physical core. With SMT/Hyper-Threading, each thread counts as a vCPU.

### 1.2 Administration Host

You need a separate computer (Linux, macOS, or Windows with WSL) to:
- Download tools and ISO images
- Prepare the installation configuration
- Create bootable media or host the ISO for virtual media
- Monitor the installation via `openshift-install wait-for install-complete`

### 1.3 Required Accounts & Resources

- **Red Hat account** with OpenShift subscription (or evaluation)
- **Pull secret** from [Red Hat OpenShift Cluster Manager](https://console.redhat.com/openshift/install/pull-secret)
- **SSH key pair** for cluster access (create with `ssh-keygen`)

---

## 2. Network & DNS Preparation

### 2.1 Decide Your Cluster Parameters

| Parameter | Example | Your Value |
|-----------|---------|------------|
| Base domain | `example.com` | ________________ |
| Cluster name | `sno` | ________________ |
| Full cluster domain | `sno.example.com` | ________________ |

### 2.2 Required DNS Records

Create these records **before** installation. Use either DHCP reservation or static IP.

| Record Type | FQDN | Target |
|-------------|------|--------|
| A/AAAA or CNAME | `api.<cluster_name>.<base_domain>` | Node IP |
| A/AAAA or CNAME | `api-int.<cluster_name>.<base_domain>` | Node IP |
| Wildcard A/AAAA | `*.apps.<cluster_name>.<base_domain>` | Node IP |

**Example:** For `sno.example.com` with node IP `192.168.1.100`:
```
api.sno.example.com        → 192.168.1.100
api-int.sno.example.com    → 192.168.1.100
*.apps.sno.example.com     → 192.168.1.100
```

### 2.3 Network Requirements

- Internet access (or access to a local/air-gapped registry)
- Open firewall ports for OpenShift services
- Ensure `machineNetwork.cidr` in install-config matches your subnet

---

## 3. Air-Gapped / Disconnected Installation

> **Note:** For fully disconnected environments, you **cannot** use the Assisted Installer, as it requires connectivity to Red Hat's cloud services. Use the Manual method (Method B) only.

### 3.1 Overview

In an air-gapped environment, the HP server and mirror registry have **no internet access**. You must:

1. Prepare all content on an **internet-connected host**
2. Transfer content to the disconnected network (USB, secure file transfer, etc.)
3. Deploy the mirror registry and load images in the disconnected environment
4. Create the installation ISO with mirrored registry configuration
5. Boot and install

### 3.2 Architecture

```
[Internet-connected host]                    [Disconnected environment]
        |                                            |
        |  oc-mirror / oc adm release mirror         |  Mirror registry (Quay,
        |  --> mirror to disk (tar)                  |     Harbor, Nexus, or
        |  --> Download RHCOS ISO                    |     Mirror Reg. for RH)
        |  --> Extract openshift-install             |            |
        |                                            |  Load images from disk
        |  ---- Transfer: USB / removable media ---- |  Create install ISO
        |  ---- Tools, ISO, config, pull secret ---- |  Boot HP server
```

### 3.3 Prerequisites for Air-Gapped

| Component | Location | Purpose |
|-----------|----------|---------|
| **Mirror registry** | Disconnected network | Hosts all container images; must be reachable by the HP server |
| **Registry options** | - | Red Hat Quay, Harbor, Nexus, Artifactory, or [Mirror Registry for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/installing-mirror-registry-on-roks) |
| **Internet-connected host** | Outside air-gap | Runs `oc-mirror` or `oc adm release mirror` to pull images |
| **Transfer media** | Physical | USB drives or other removable media for moving content |

> The Mirror Registry for Red Hat OpenShift is included with subscriptions and is suitable for small-scale deployments.

### 3.4 Phase 1: Internet-Connected Host Preparation

#### 3.4.1 Install oc-mirror and oc

```bash
# Download oc and oc-mirror from Red Hat (requires Red Hat account)
# https://console.redhat.com/openshift/downloads
# - OpenShift Client (oc)
# - oc-mirror plugin (same page, "OpenShift disconnected installation tools")
tar xzf oc-mirror.tar.gz
chmod +x oc-mirror
sudo mv oc-mirror /usr/local/bin/

# Verify
oc mirror --v2 --help
```

#### 3.4.2 Create Image Set Configuration

Create `imageset-config.yaml` for oc-mirror:

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
      - name: stable-4.20
        minVersion: 4.20.0
        maxVersion: 4.20.0
    graph: true
```

For Operators (optional, add if needed):

```yaml
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.20
      packages:
        - name: <operator-name>   # Or omit packages to mirror all
```

**Red Hat OpenShift AI (RHOAI):** To install RHOAI in a disconnected environment, use the provided ImageSetConfiguration that includes the required operators and notebook images:

| File | Purpose |
|------|---------|
| [`imageset-rhoai.yaml`](imageset-rhoai.yaml) | Operators: rhods-operator, servicemeshoperator3, nfd, rhcl-operator, kueue-operator, metallb-operator, gpu-operator-certified; plus MODH notebook/workload images |

For a complete air-gapped install with RHOAI, either:
- **Merge** the `operators` and `additionalImages` from `imageset-rhoai.yaml` into your base config (which includes `platform`), or
- **Run oc-mirror twice:** first with platform + base operators for OpenShift install, then with `imageset-rhoai.yaml` to add RHOAI content.

```bash
# Example: Mirror RHOAI operators and images (after OpenShift base)
oc mirror --config imageset-rhoai.yaml file:///path/to/mirror-dir
```

> **Note:** `imageset-rhoai.yaml` uses `apiVersion: mirror.openshift.io/v1alpha2`. If using oc-mirror v2 (`--v2`), you may need to convert to `v2alpha1` or run without the v2 flag. Check [oc-mirror documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/disconnected_environments/about-installing-oc-mirror-v2) for compatibility.

#### 3.4.3 Configure Registry Credentials

```bash
# Create auth.json with pull secret + mirror registry credentials
# 1. Get pull secret from https://console.redhat.com/openshift/install/pull-secret
# 2. Add your mirror registry (that will run in disconnected env):
cat pull-secret | jq . > auth.json

# Add mirror registry entry (base64 of user:password):
# echo -n 'admin:password' | base64 -w0
# Edit auth.json to add:
#   "registry.disconnected.example.com:5000": {
#     "auth": "<base64_credentials>",
#     "email": "you@example.com"
#   }

mkdir -p $XDG_RUNTIME_DIR/containers
cp auth.json $XDG_RUNTIME_DIR/containers/auth.json
```

#### 3.4.4 Mirror Images to Disk

**Option A: oc-mirror (recommended)**

```bash
# Mirror to disk - creates tar archive for transfer
oc mirror --config imageset-config.yaml file:///path/to/mirror-dir --v2

# Output will be in /path/to/mirror-dir/
# Transfer the entire directory to disconnected environment
```

**Option B: oc adm release mirror (release images only)**

```bash
OCP_RELEASE=4.20.0
ARCH=x86_64
LOCAL_REGISTRY='registry.disconnected.example.com:5000'
LOCAL_REPOSITORY='ocp4/openshift4'
LOCAL_SECRET_JSON='./auth.json'

# If mirror registry is NOT reachable from this host, mirror to directory:
oc adm release mirror -a ${LOCAL_SECRET_JSON} \
  --from=quay.io/openshift-release-dev/ocp-release:${OCP_RELEASE}-${ARCH} \
  --to-dir=/path/to/mirror-dir/mirror

# Record the imageContentSources from the output for install-config.yaml
```

#### 3.4.5 Extract openshift-install from Mirrored Release

If using oc adm release mirror to a **reachable** registry:

```bash
oc adm release extract -a ${LOCAL_SECRET_JSON} --command=openshift-install \
  "${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_RELEASE}-${ARCH}"
chmod +x openshift-install
```

If using disk mirror, you must first load images to a registry in the connected environment (e.g., temporary local registry), then extract. Or use `oc` from the standard download to extract once images are loaded in disconnected env.

#### 3.4.6 Download RHCOS ISO

```bash
export OCP_VERSION=4.20.0
export ARCH=x86_64

# Get ISO URL (requires openshift-install from previous step)
export ISO_URL=$(./openshift-install coreos print-stream-json | grep location | grep $ARCH | grep iso | cut -d'"' -f4)
curl -L "$ISO_URL" -o rhcos-live.iso
```

#### 3.4.7 Prepare Transfer Package

Bundle for transfer to disconnected environment:

- `oc`, `openshift-install` binaries
- `oc-mirror` (if using disk-to-mirror in disconnected)
- Mirror directory (from oc mirror / oc adm release mirror)
- `rhcos-live.iso`
- Pull secret (with mirror registry credentials)
- Mirror registry CA certificate (if self-signed)

### 3.5 Phase 2: Disconnected Environment Setup

#### 3.5.1 Deploy Mirror Registry

Install the mirror registry on a host in the disconnected network. Options:

- **Mirror Registry for Red Hat OpenShift:** Follow [Creating a mirror registry with mirror registry for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/installing-mirror-registry-on-roks)
- **Harbor / Quay / Nexus:** Deploy per vendor documentation

Ensure the HP server can reach the mirror registry over the network.

#### 3.5.2 Load Images into Mirror Registry

**If you used oc-mirror mirror-to-disk:**

```bash
# In disconnected env, with mirror archive transferred:
oc mirror --config imageset-config.yaml --from file:///path/to/mirror-dir \
  docker://registry.disconnected.example.com:5000 --v2
```

**If you used oc adm release mirror to-dir:**

```bash
# Copy mirror content to disconnected host, then:
oc image mirror -a auth.json --from-dir=/path/to/mirror-dir/mirror \
  "file://openshift/release:${OCP_RELEASE}*" \
  ${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}
```

#### 3.5.3 Obtain imageContentSources

From the oc-mirror output, use the generated files in `working-dir/cluster-resources/`. For **install-config**, you need `imageContentSources`. oc-mirror v2 produces IDMS/ITMS for post-install; for **install time**, use the mapping from `oc adm release mirror` output, or construct from the mirror layout.

Example `imageContentSources` (adjust for your mirror):

```yaml
imageContentSources:
- mirrors:
  - registry.disconnected.example.com:5000/ocp4/openshift4
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - registry.disconnected.example.com:5000/ocp4/openshift4
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
```

If using `oc adm release mirror` output, copy the exact `imageContentSources` block it prints.

### 3.6 Phase 3: Create install-config for Disconnected

Add these sections to `install-config.yaml`:

```yaml
apiVersion: v1
baseDomain: example.com
compute:
  - name: worker
    replicas: 0
controlPlane:
  - name: master
    replicas: 1
metadata:
  name: sno
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.30.0.0/16
platform:
  none: {}
bootstrapInPlace:
  installationDisk: /dev/disk/by-id/<YOUR_DISK_ID>

# --- Disconnected-specific ---
imageContentSources:
- mirrors:
  - registry.disconnected.example.com:5000/ocp4/openshift4
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - registry.disconnected.example.com:5000/ocp4/openshift4
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev

# If mirror uses self-signed certificate - paste PEM content:
additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  <your-mirror-registry-ca-certificate>
  -----END CERTIFICATE-----

pullSecret: '<pull_secret_with_mirror_registry_credentials>'
sshKey: |
  ssh-rsa AAAAB3... your-user@host
```

**Critical:** The `pullSecret` must include credentials for **both** `registry.redhat.io`/`quay.io` **and** your mirror registry.

### 3.7 Phase 4: Generate Ignition and ISO

```bash
# Use openshift-install extracted from MIRRORED release (pinned to mirrored content)
mkdir -p ocp
cp install-config.yaml ocp/
./openshift-install --dir=ocp create single-node-ignition-config

# Embed ignition into RHCOS ISO
alias coreos-installer='podman run --privileged --pull always --rm \
  -v /dev:/dev -v /run/udev:/run/udev -v $PWD:/data -w /data \
  quay.io/coreos/coreos-installer:release'

coreos-installer iso ignition embed -fi ocp/bootstrap-in-place-for-live-iso.ign rhcos-live.iso
```

> For fully disconnected, use a pre-pulled `coreos-installer` image or binary. Alternatively, embed the ignition on the connected host before transfer and only transfer the final ISO.

### 3.8 Phase 5: Boot and Install

Same as Method B (Section 6): use virtual media or USB to boot the HP server with the customized ISO. Monitor with `openshift-install --dir=ocp wait-for install-complete`.

### 3.9 Post-Install: Apply oc-mirror Cluster Resources

After the cluster is running, apply IDMS/ITMS and any CatalogSource from oc-mirror:

```bash
export KUBECONFIG=ocp/auth/kubeconfig
oc apply -f /path/to/working-dir/cluster-resources/
oc apply -f /path/to/working-dir/cluster-resources/signature-configmap.json  # if release signatures exist
```

### 3.10 Air-Gapped Checklist

- [ ] Mirror registry deployed in disconnected network
- [ ] Images mirrored (oc-mirror or oc adm release mirror) on connected host
- [ ] Content transferred to disconnected environment
- [ ] Images loaded into mirror registry
- [ ] RHCOS ISO downloaded and transferred
- [ ] openshift-install extracted from mirrored release
- [ ] install-config has `imageContentSources`, `additionalTrustBundle` (if needed), mirror credentials in `pullSecret`
- [ ] ISO created with embedded ignition
- [ ] HP server can reach mirror registry during install
- [ ] Post-install: IDMS/ITMS applied to cluster

---

## 4. HP iLO (BMC) Preparation

### 4.1 iLO Configuration

1. **Access iLO:** Connect to the iLO management interface (default: `https://<ilo-ip>`)
2. **Update firmware:** Ensure latest iLO 5/6 firmware for Redfish compatibility
3. **Network:** Configure iLO with a static IP on your management network
4. **Credentials:** Note the iLO username and password for virtual media operations
5. **Virtual Media:** Ensure Virtual Media feature is enabled (typically under iLO → Configuration)

### 4.2 Identify Installation Disk

From the administration host (or via iLO remote console), identify the target disk:

```bash
# If you have console access to the server, after booting a live image:
ls -la /dev/disk/by-id/
```

Look for a stable identifier (e.g., `wwn-0x...` or `scsi-...`). Example:
```
/dev/disk/by-id/wwn-0x64cd98f04fde100024684cf3034da5c2
```

---

## 5. Installation Method Choice

You can use **either** of these methods:

| Method | Pros | Cons |
|--------|------|------|
| **Assisted Installer** | Web UI, guided, discovery ISO auto-generated | Requires Red Hat account, **internet connectivity** |
| **Manual (coreos-installer)** | Fully offline-capable, **required for air-gapped** | More manual steps, need install-config |

> **Air-gapped:** Use Manual method only. See [Section 3](#3-air-gapped--disconnected-installation) for full steps.

---

## 6. Method A: Assisted Installer (Recommended for First-Time)

### 6.1 Steps

1. Open [Red Hat OpenShift Cluster Manager](https://console.redhat.com/openshift/assisted-installer/clusters)
2. Click **Create New Cluster**
3. Select **Install single node OpenShift (SNO)**
4. **Base domain:** Enter your base domain (e.g., `example.com`)
5. **Cluster name:** Enter cluster name (e.g., `sno`)
6. Add networking: subnet, VIPs (or use single-node defaults)
7. Add SSH public key
8. Download the **discovery ISO**
9. Note the ISO URL (for virtual media) or create USB boot drive

### 6.2 HP Server Boot Options

**Option 1 – Virtual Media (Recommended for HP)**

- Host the discovery ISO on an HTTP/HTTPS server accessible from the HP server
- Use iLO Redfish API or iLO web interface to mount the ISO and boot
- Ensure BIOS boot order: target disk first (for after first reboot)

**Option 2 – USB Drive**

- Use `dd` to write the ISO to a USB drive
- Insert USB into the HP server and select USB boot in BIOS/iLO

### 6.3 Virtual Media via iLO Redfish (HP)

The Redfish API for HP iLO differs from Dell. General flow:

1. **Mount ISO** – POST to VirtualMedia with `Image` URL
2. **Set boot source** – PATCH Boot to use Virtual Media
3. **Reset** – POST Reset action

Example (adapt paths for your iLO version):

```bash
# 1. Insert virtual media (ISO must be HTTP/HTTPS accessible from the server)
curl -k -u <ilo_user>:<ilo_password> \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"Image":"http://<your-webserver>/discovery.iso"}' \
  https://<ilo-ip>/redfish/v1/Managers/1/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia

# 2. Set one-time boot from CD
curl -k -u <ilo_user>:<ilo_password> \
  -X PATCH \
  -H "Content-Type: application/json" \
  -d '{"Boot":{"BootSourceOverrideTarget":"Cd","BootSourceOverrideEnabled":"Once"}}' \
  https://<ilo-ip>/redfish/v1/Systems/1

# 3. Reboot
curl -k -u <ilo_user>:<ilo_password> \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"ResetType":"ForceRestart"}' \
  https://<ilo-ip>/redfish/v1/Systems/1/Actions/ComputerSystem.Reset
```

> **Note:** iLO Redfish paths can vary by iLO generation. Consult [HPE iLO Redfish API documentation](https://hewlettpackard.github.io/ilo-rest-api-docs/ilo6/) for your model.

### 6.4 Post-Boot

1. Server boots from discovery ISO and registers with Assisted Installer
2. Wait for host to appear in the Assisted Installer UI
3. Complete the wizard and start installation
4. Server will reboot several times; ensure BIOS is set to boot from disk after first install phase
5. Optionally eject virtual media after first reboot to avoid boot loops

---

## 7. Method B: Manual Installation (coreos-installer)

### 7.1 Prepare Administration Host

```bash
# Install podman
sudo dnf install -y podman   # RHEL/Fedora
# or: sudo apt install podman   # Debian/Ubuntu

# Set version and architecture
export OCP_VERSION=latest-4.20
export ARCH=x86_64
```

### 7.2 Download OpenShift Tools

```bash
# oc client
curl -k -L "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz" -o oc.tar.gz
tar zxf oc.tar.gz && chmod +x oc kubectl

# openshift-install
curl -k -L "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-install-linux.tar.gz" -o openshift-install-linux.tar.gz
tar zxvf openshift-install-linux.tar.gz && chmod +x openshift-install
```

### 7.3 Download RHCOS ISO

```bash
export ISO_URL=$(./openshift-install coreos print-stream-json | grep location | grep $ARCH | grep iso | cut -d'"' -f4)
curl -L "$ISO_URL" -o rhcos-live.iso
```

### 7.4 Create install-config.yaml

Create `install-config.yaml`:

```yaml
apiVersion: v1
baseDomain: example.com
compute:
  - name: worker
    replicas: 0
controlPlane:
  - name: master
    replicas: 1
metadata:
  name: sno
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 10.0.0.0/16   # Match your subnet
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.30.0.0/16
platform:
  none: {}
bootstrapInPlace:
  installationDisk: /dev/disk/by-id/<YOUR_DISK_ID>
pullSecret: '<PASTE_PULL_SECRET_HERE>'
sshKey: |
  ssh-rsa AAAAB3... your-user@host
```

**Replace:**
- `baseDomain`, `metadata.name`
- `machineNetwork.cidr` with your subnet
- `installationDisk` with the disk by-id path
- `pullSecret` from Red Hat
- `sshKey` with your public key

### 7.5 Generate Ignition and Embed in ISO

```bash
mkdir -p ocp
cp install-config.yaml ocp/
./openshift-install --dir=ocp create single-node-ignition-config

# Embed ignition into RHCOS ISO
alias coreos-installer='podman run --privileged --pull always --rm \
  -v /dev:/dev -v /run/udev:/run/udev -v $PWD:/data -w /data \
  quay.io/coreos/coreos-installer:release'

coreos-installer iso ignition embed -fi ocp/bootstrap-in-place-for-live-iso.ign rhcos-live.iso
```

> **Important:** The embedded certificates are valid for ~24 hours. Use the ISO soon after creation.

### 7.6 Boot the HP Server

Use the same options as Method A (Section 6): virtual media or USB drive with the customized `rhcos-live.iso`.

### 7.7 Monitor Installation

```bash
./openshift-install --dir=ocp wait-for install-complete
```

---

## 8. Post-Installation Verification

```bash
export KUBECONFIG=ocp/auth/kubeconfig   # or path from Assisted Installer
oc get nodes
oc get clusteroperators
```

Expected node output:
```
NAME                         STATUS   ROLES           AGE   VERSION
control-plane.example.com    Ready    master,worker   10m   v1.33.x
```

---

## 9. Important Notes

### 9.1 SNO-Specific

- **OVN-Kubernetes** is the only supported network plugin (no OpenShiftSDN)
- **No HA** – single point of failure; suitable for edge, lab, or small workloads
- **Bootstrap-in-place** – no separate bootstrap node

### 9.2 HP Server Tips

- Ensure **UEFI** boot mode (not legacy BIOS)
- Disable Secure Boot if it causes RHCOS boot issues (re-enable after validation)
- Keep iLO firmware current for best Redfish compatibility
- For Gen11 ProLiant, iLO 6 with Redfish is preferred

### 9.3 Troubleshooting

- **Installation hangs:** Check DNS resolution from the node, ensure pull secret is valid
- **Virtual media not booting:** Verify ISO URL is reachable from the server’s network
- **Boot loops:** Eject virtual media after first reboot; ensure disk is first in boot order

---

## 10. Checklist Summary

**General:**
- [ ] HP server meets minimum specs (8 vCPU, 16 GB RAM, 120 GB disk)
- [ ] iLO firmware updated, virtual media enabled
- [ ] DNS records created (api, api-int, *.apps)
- [ ] Pull secret and SSH key ready
- [ ] Network/machineNetwork CIDR matches environment
- [ ] Installation disk by-id identified
- [ ] Chosen method: Assisted Installer or Manual
- [ ] ISO prepared and booted (virtual media or USB)
- [ ] BIOS boot order: disk first (for post-install reboots)
- [ ] Installation monitored until complete
- [ ] `oc get nodes` shows Ready

**If air-gapped (see Section 3):**
- [ ] Mirror registry deployed; images mirrored and loaded
- [ ] `install-config` has `imageContentSources`, `additionalTrustBundle`, mirror creds in pullSecret
- [ ] IDMS/ITMS applied post-install

---

## 11. References

- [OpenShift 4.20 Installing on a single node](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installing_on_a_single_node/)
- [Red Hat OpenShift Cluster Manager](https://console.redhat.com/openshift/assisted-installer/clusters)
- [HPE iLO Redfish API](https://hewlettpackard.github.io/ilo-rest-api-docs/ilo6/)
- [Red Hat OpenShift on HPE Bare Metal](https://catalog.redhat.com/solutions/detail/dc5207e0-a8a1-11ed-b4d6-8794106d92d0)
- [Disconnected installation mirroring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/)
- [oc-mirror plugin v2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/disconnected_environments/about-installing-oc-mirror-v2)
- [Red Hat OpenShift AI disconnected deployment](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/) — use [`imageset-rhoai.yaml`](imageset-rhoai.yaml) for operators and notebook images
