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

## 3. HP iLO (BMC) Preparation

### 3.1 iLO Configuration

1. **Access iLO:** Connect to the iLO management interface (default: `https://<ilo-ip>`)
2. **Update firmware:** Ensure latest iLO 5/6 firmware for Redfish compatibility
3. **Network:** Configure iLO with a static IP on your management network
4. **Credentials:** Note the iLO username and password for virtual media operations
5. **Virtual Media:** Ensure Virtual Media feature is enabled (typically under iLO → Configuration)

### 3.2 Identify Installation Disk

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

## 4. Installation Method Choice

You can use **either** of these methods:

| Method | Pros | Cons |
|--------|------|------|
| **Assisted Installer** | Web UI, guided, discovery ISO auto-generated | Requires Red Hat account, cloud-based |
| **Manual (coreos-installer)** | Fully offline-capable, no external dependencies | More manual steps, need install-config |

---

## 5. Method A: Assisted Installer (Recommended for First-Time)

### 5.1 Steps

1. Open [Red Hat OpenShift Cluster Manager](https://console.redhat.com/openshift/assisted-installer/clusters)
2. Click **Create New Cluster**
3. Select **Install single node OpenShift (SNO)**
4. **Base domain:** Enter your base domain (e.g., `example.com`)
5. **Cluster name:** Enter cluster name (e.g., `sno`)
6. Add networking: subnet, VIPs (or use single-node defaults)
7. Add SSH public key
8. Download the **discovery ISO**
9. Note the ISO URL (for virtual media) or create USB boot drive

### 5.2 HP Server Boot Options

**Option 1 – Virtual Media (Recommended for HP)**

- Host the discovery ISO on an HTTP/HTTPS server accessible from the HP server
- Use iLO Redfish API or iLO web interface to mount the ISO and boot
- Ensure BIOS boot order: target disk first (for after first reboot)

**Option 2 – USB Drive**

- Use `dd` to write the ISO to a USB drive
- Insert USB into the HP server and select USB boot in BIOS/iLO

### 5.3 Virtual Media via iLO Redfish (HP)

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

### 5.4 Post-Boot

1. Server boots from discovery ISO and registers with Assisted Installer
2. Wait for host to appear in the Assisted Installer UI
3. Complete the wizard and start installation
4. Server will reboot several times; ensure BIOS is set to boot from disk after first install phase
5. Optionally eject virtual media after first reboot to avoid boot loops

---

## 6. Method B: Manual Installation (coreos-installer)

### 6.1 Prepare Administration Host

```bash
# Install podman
sudo dnf install -y podman   # RHEL/Fedora
# or: sudo apt install podman   # Debian/Ubuntu

# Set version and architecture
export OCP_VERSION=latest-4.20
export ARCH=x86_64
```

### 6.2 Download OpenShift Tools

```bash
# oc client
curl -k -L "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz" -o oc.tar.gz
tar zxf oc.tar.gz && chmod +x oc kubectl

# openshift-install
curl -k -L "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-install-linux.tar.gz" -o openshift-install-linux.tar.gz
tar zxvf openshift-install-linux.tar.gz && chmod +x openshift-install
```

### 6.3 Download RHCOS ISO

```bash
export ISO_URL=$(./openshift-install coreos print-stream-json | grep location | grep $ARCH | grep iso | cut -d'"' -f4)
curl -L "$ISO_URL" -o rhcos-live.iso
```

### 6.4 Create install-config.yaml

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

### 6.5 Generate Ignition and Embed in ISO

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

### 6.6 Boot the HP Server

Use the same options as Method A: virtual media or USB drive with the customized `rhcos-live.iso`.

### 6.7 Monitor Installation

```bash
./openshift-install --dir=ocp wait-for install-complete
```

---

## 7. Post-Installation Verification

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

## 8. Important Notes

### 8.1 SNO-Specific

- **OVN-Kubernetes** is the only supported network plugin (no OpenShiftSDN)
- **No HA** – single point of failure; suitable for edge, lab, or small workloads
- **Bootstrap-in-place** – no separate bootstrap node

### 8.2 HP Server Tips

- Ensure **UEFI** boot mode (not legacy BIOS)
- Disable Secure Boot if it causes RHCOS boot issues (re-enable after validation)
- Keep iLO firmware current for best Redfish compatibility
- For Gen11 ProLiant, iLO 6 with Redfish is preferred

### 8.3 Troubleshooting

- **Installation hangs:** Check DNS resolution from the node, ensure pull secret is valid
- **Virtual media not booting:** Verify ISO URL is reachable from the server’s network
- **Boot loops:** Eject virtual media after first reboot; ensure disk is first in boot order

---

## 9. Checklist Summary

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

---

## 10. References

- [OpenShift 4.20 Installing on a single node](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installing_on_a_single_node/)
- [Red Hat OpenShift Cluster Manager](https://console.redhat.com/openshift/assisted-installer/clusters)
- [HPE iLO Redfish API](https://hewlettpackard.github.io/ilo-rest-api-docs/ilo6/)
- [Red Hat OpenShift on HPE Bare Metal](https://catalog.redhat.com/solutions/detail/dc5207e0-a8a1-11ed-b4d6-8794106d92d0)
