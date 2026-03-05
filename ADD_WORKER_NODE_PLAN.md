# Plan: Add Bare Metal Worker Host to OpenShift 4.20 Single-Node Bare Metal (HP Server)

This document provides a step-by-step plan to **add a bare metal worker host** to an existing OpenShift 4.20 Single-Node OpenShift (SNO) cluster running on bare metal. Both the existing SNO and the new worker are **physical HP ProLiant servers** (user-provisioned infrastructure). The result is a **two-node bare metal cluster**: one control plane node (SNO) + one worker node.

---

## 1. Overview

### 1.1 Scope: Bare Metal SNO + Bare Metal Worker

| Component | Type | Description |
|-----------|------|-------------|
| **Existing cluster** | Bare metal SNO | OpenShift 4.20 SNO installed on a physical HP server (see [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md)) |
| **New node** | Bare metal worker | A second physical HP server, manually provisioned with RHCOS and joined as a worker |

This plan applies to **user-provisioned bare metal infrastructure** only. Both nodes are physical servers; there is no virtualization layer or cloud provider.

### 1.2 Resulting Topology

| Node | Role | Description |
|------|------|-------------|
| **Existing SNO** | control-plane, master, worker | Your current bare metal HP server running OpenShift 4.20 SNO |
| **New worker** | worker | Additional bare metal HP server for running workloads |

The SNO continues to run control plane services and can also run workloads. The new bare metal worker adds compute capacity for additional workloads (e.g., RHOAI, general applications).

### 1.3 Important Notes

- **Control plane remains single-node** — The control plane is still a single point of failure; the worker adds compute capacity only.
- **Same procedure for connected or disconnected** — The flow is the same; in disconnected environments you use the mirrored RHCOS ISO and ensure the worker ignition is served from within your network.
- **HP iLO** — Use virtual media or USB boot as with the initial SNO install (see [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md)).

### 1.4 Two Approaches: Manual vs Metal³/BareMetalHost

You can add a bare metal worker using either approach:

| Approach | Description | BMC Support |
|----------|-------------|-------------|
| **Method A: Manual UPI** | Boot RHCOS ISO (virtual media or USB), run `coreos-installer`, approve CSRs. No BareMetalHost CR. | Any BMC (HP iLO, Dell iDRAC, etc.) |
| **Method B: Metal³/BareMetalHost** | Create a `BareMetalHost` CR with BMC credentials. Ironic provisions the node via virtual media. Automated. | **Redfish-compatible BMCs only** (HP iLO 5/6, Dell iDRAC 8+, generic Redfish) |

> **Metal³ is not Dell-specific.** It supports HP iLO 5/6 (`redfish-virtualmedia` or `ilo5-virtualmedia`), Dell iDRAC 8+ (`idrac-virtualmedia`), and any Redfish-compatible BMC. For user-provisioned clusters, only **virtual media** boot is supported (no provisioning network), so your BMC must support Redfish virtual media.

**When to use Method B:** If the Bare Metal Operator is available in your cluster and your worker has a Redfish-compatible BMC (e.g., HP iLO 5/6), Method B automates provisioning—you create a BareMetalHost CR and Ironic handles the rest.

**When to use Method A:** If Metal³ is not available, your BMC lacks Redfish virtual media support, or you prefer full manual control.

---

## 2. Prerequisites

### 2.1 Cluster Requirements

| Item | Requirement |
|------|-------------|
| **Existing cluster** | OpenShift 4.20 SNO installed and running on bare metal (see [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md)) |
| **Access** | `cluster-admin` role (or equivalent) |
| **Tools** | `oc` CLI, `coreos-installer` (or podman to run it) |

### 2.2 Bare Metal Worker Server Requirements

The new worker must be a **physical HP ProLiant server** (bare metal), not a virtual machine.

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **CPU** | 8 vCPUs | 16+ vCPUs |
| **Memory** | 16 GB RAM | 32+ GB RAM |
| **Storage** | 120 GB | 200+ GB SSD |
| **Network** | 1 Gbps NIC | Same network as SNO |
| **BMC** | iLO 5 or iLO 6 | For virtual media boot |

### 2.3 Network & DNS

| Item | Requirement |
|------|-------------|
| **Worker IP** | DHCP reservation or static IP in `machineNetwork.cidr` |
| **DNS** | Forward and reverse DNS for the worker hostname (optional but recommended) |
| **Connectivity** | Worker must reach: SNO (API, etcd), mirror registry (if disconnected), HTTP server hosting worker ignition |

### 2.4 HTTP Server for Worker Ignition (Method A only)

For Method A, you need an HTTP (or HTTPS) server reachable from the **worker node** to serve the worker ignition file. Options:

- A simple web server on the administration host
- The SNO node itself (if you expose a static file server)
- Any host in the same network as the worker

---

## 3. Method A: Manual UPI (ISO + coreos-installer)

This method does **not** use BareMetalHost. You manually boot the worker from RHCOS ISO and run `coreos-installer`.

### 3.1 Phase 1: Preparation (Administration Host)

Set environment variables:

```bash
export KUBECONFIG=/path/to/ocp/auth/kubeconfig   # From your SNO install
export OCP_VERSION=4.20.0
export ARCH=x86_64
```

Obtain RHCOS ISO:

**Connected environment:**

```bash
# Get ISO URL from the cluster
export ISO_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | jq -r '.architectures.x86_64.artifacts.metal.formats.iso.disk.location')

# Download
curl -L "$ISO_URL" -o rhcos-live.iso
```

**Disconnected environment:**

- Use the same RHCOS ISO you used for the SNO install (from your mirror or transfer package).
- Ensure the ISO version matches or is compatible with the cluster (nodes auto-upgrade on first boot).

Extract worker ignition:

```bash
# Extract worker ignition from the cluster
oc extract -n openshift-machine-api secret/worker-user-data-managed --keys=userData --to=- > worker.ign

# Verify the file
cat worker.ign | jq . > /dev/null && echo "Valid JSON" || echo "Check worker.ign"
```

(Optional) Embed SSH ignition for live ISO:

If you want SSH access to the worker during the live boot (before installation), create an SSH ignition and embed it into the ISO:

```bash
SSH_PUB=$(cat ~/.ssh/id_rsa.pub)
cat <<EOF > ssh.ign
{
  "ignition": {
    "version": "3.1.0"
  },
  "passwd": {
    "users": [
      {
        "groups": ["sudo"],
        "name": "core",
        "passwordHash": "!",
        "sshAuthorizedKeys": ["${SSH_PUB}"]
      }
    ]
  }
}
EOF

# Embed into ISO (creates a new ISO with SSH enabled for live session)
coreos-installer iso ignition embed -fi ssh.ign rhcos-live.iso -o rhcos-live-ssh.iso
# Use rhcos-live-ssh.iso for booting if you need SSH during live session
```

> **Note:** The SSH ignition is only for the live environment. The worker will use `worker.ign` during `coreos-installer install` to join the cluster.

Serve worker ignition via HTTP:

Upload `worker.ign` to your HTTP server so the worker can fetch it during installation.

**Example with Python (simple HTTP server):**

```bash
# On administration host or any reachable host
python3 -m http.server 9000 --directory /path/to/dir/containing/worker.ign
# worker.ign must be in that directory
# Worker will use: http://<server-ip>:9000/worker.ign
```

**Example with podman (if no Python):**

```bash
podman run -d --name ignition-server -p 9000:8080 \
  -v /path/to/dir/containing/worker.ign:/var/www:ro \
  docker.io/library/nginx:alpine
# Ensure nginx serves the directory; adjust as needed
```

Record the URL, e.g. `http://192.168.1.50:9000/worker.ign`.

Compute ignition hash (recommended for security):

When using `--ignition-url`, `coreos-installer` can validate the file with `--ignition-hash`:

```bash
sha512sum worker.ign
# Use output like: sha512-a5a2d43879223273c9b60af66b44202a1d1248fc01cf156c46d4a79f552b6bad47bc8cc78ddf0116e80c59d2ea9e32ba53bc807afbca581aa059311def2c3e3b
```

---

### 3.2 Phase 2: Boot Bare Metal Worker HP Server

Boot from RHCOS ISO:

Boot the **physical worker server** using the same method as the SNO install (see [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md) Section 6):

**Option A – Virtual Media (iLO):**

1. Host the RHCOS ISO on an HTTP/HTTPS server reachable from the worker.
2. Use iLO Redfish API or web UI to mount the ISO and set one-time boot from CD.
3. Reboot the server.

**Option B – USB Drive:**

```bash
# Write ISO to USB (replace /dev/sdX with your USB device)
sudo dd if=rhcos-live.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Insert USB into the bare metal worker HP server and select USB boot in BIOS/iLO.

Wait for live environment:

Boot the server and wait until you see the RHCOS live shell prompt. Do **not** interrupt the boot to add kernel arguments if you will use `coreos-installer` (see next step).

---

### 3.3 Phase 3: Install RHCOS on the Bare Metal Worker

Identify installation disk:

From the live environment on the physical worker (console or SSH if you embedded SSH ignition):

```bash
ls -la /dev/disk/by-id/
```

Choose a stable disk identifier (e.g. `wwn-0x...` or `scsi-...`). Example: `/dev/disk/by-id/wwn-0x64cd98f04fde100024684cf3034da5c2`

Run coreos-installer:

Replace placeholders with your values:

```bash
# With ignition hash (recommended)
sudo coreos-installer install /dev/disk/by-id/<YOUR_DISK_ID> \
  --ignition-url http://<HTTP_SERVER_IP>:9000/worker.ign \
  --ignition-hash sha512-<DIGEST_FROM_SHA512SUM>

# Without ignition hash (use --insecure-ignition only if necessary, e.g. HTTP without TLS)
# sudo coreos-installer install /dev/disk/by-id/<YOUR_DISK_ID> \
#   --ignition-url http://<HTTP_SERVER_IP>:9000/worker.ign --insecure-ignition
```

**Example:**

```bash
sudo coreos-installer install /dev/sda \
  --ignition-url http://192.168.1.50:9000/worker.ign \
  --ignition-hash sha512-a5a2d43879223273c9b60af66b44202a1d1248fc01cf156c46d4a79f552b6bad47bc8cc78ddf0116e80c59d2ea9e32ba53bc807afbca581aa059311def2c3e3b
```

Eject virtual media (if used):

Before rebooting, eject the virtual media from iLO so the server boots from the local disk.

Reboot:

```bash
sudo reboot
```

The worker will reboot once or twice during first boot. It will then request to join the cluster (CSR).

---

### 3.4 Phase 4: Approve Certificate Signing Requests (CSRs)

Watch for new nodes and CSRs:

From your administration host:

```bash
export KUBECONFIG=/path/to/ocp/auth/kubeconfig

# Watch nodes (worker may appear as NotReady initially)
oc get nodes -w

# In another terminal, watch CSRs
oc get csr -w
```

Approve pending CSRs:

When you see CSRs in `Pending` status:

**Approve all pending CSRs:**

```bash
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs --no-run-if-empty oc adm certificate approve
```

**Or approve individually:**

```bash
oc get csr | grep Pending
oc adm certificate approve <csr_name>
```

You typically need to approve:
1. **Client CSRs** — `system:serviceaccount:openshift-machine-config-operator:node-bootstrapper`
2. **Server CSRs** — `system:node:worker-0` (or similar)

> **Important:** Approve CSRs within about an hour of the node joining. If delayed, certificates may rotate and you may need to approve multiple CSRs per node.

Verify worker joined:

```bash
oc get nodes
```

Expected output:

```
NAME                         STATUS   ROLES                         AGE   VERSION
control-plane.example.com    Ready    control-plane,master,worker   5h    v1.33.x
worker-0.example.com         Ready    worker                         10m   v1.33.x
```

---

## 4. Method B: Metal³/BareMetalHost (Automated)

This method uses the **Bare Metal Operator** and **Ironic** to provision the worker by creating a `BareMetalHost` CR. The BMC must support **Redfish virtual media** (HP iLO 5/6, Dell iDRAC 8+, or generic Redfish).

### 4.1 Prerequisites for Method B

- Bare Metal Operator available in the cluster (create `Provisioning` CR to deploy Metal³ if needed)
- Worker has a Redfish-compatible BMC (HP iLO 5/6, Dell iDRAC 8+, etc.)
- BMC credentials (username/password)
- Boot MAC address of the worker's primary NIC
- No provisioning network (user-provisioned clusters use virtual media only)

### 4.2 Create Provisioning CR (if not already present)

Create a `Provisioning` CR to enable Metal³ with `provisioningNetwork: "Disabled"`:

```yaml
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  provisioningNetwork: "Disabled"
  watchAllNamespaces: false
```

```bash
oc create -f provisioning.yaml
```

Verify Metal³ pods are running:

```bash
oc get pods -n openshift-machine-api
# Look for: metal3-*, ironic-*, cluster-baremetal-operator
```

### 4.3 Create BMC Secret and BareMetalHost

**For DHCP (simpler):**

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: openshift-worker-0-bmc-secret
  namespace: openshift-machine-api
type: Opaque
data:
  username: <base64_of_ilo_username>
  password: <base64_of_ilo_password>
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: openshift-worker-0
  namespace: openshift-machine-api
spec:
  online: true
  bootMACAddress: <worker_nic_mac_address>
  bmc:
    address: redfish-virtualmedia://<ilo_ip>/redfish/v1/Systems/1
    credentialsName: openshift-worker-0-bmc-secret
    disableCertificateVerification: true
  customDeploy:
    method: install_coreos
  userData:
    name: worker-user-data-managed
    namespace: openshift-machine-api
  rootDeviceHints:
    deviceName: /dev/sda
```

**BMC address formats for HP iLO:**

| BMC | Address format |
|-----|----------------|
| HP iLO 5/6 | `redfish-virtualmedia://<ilo_ip>/redfish/v1/Systems/1` or `ilo5-virtualmedia://<ilo_ip>/redfish/v1/Systems/1` |
| Dell iDRAC 8+ | `idrac-virtualmedia://<idrac_ip>/redfish/v1/Systems/System.Embedded.1` |

Base64 encode credentials: `echo -n 'admin' | base64 -w0` and `echo -n 'password' | base64 -w0`.

**For static IP:** Add a `preprovisioningNetworkDataName` secret with NMState config (see [Red Hat: Scaling a user-provisioned cluster with the Bare Metal Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/installing_on_bare_metal/scaling-a-user-provisioned-cluster-with-the-bare-metal-operator)).

### 4.4 Apply and Monitor

```bash
oc create -f bmh.yaml
oc get bmh -n openshift-machine-api -w
```

The Bare Metal Operator will power on the host, mount the RHCOS image via virtual media, and provision the node. When the node joins, approve CSRs:

```bash
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs --no-run-if-empty oc adm certificate approve
oc get nodes
```

### 4.5 Method B Limitations

- **No provisioning network** — Only virtual media drivers work (`redfish-virtualmedia`, `idrac-virtualmedia`, `ilo5-virtualmedia`).
- **SNO consideration** — SNO clusters installed with `platform: none` may not have the Bare Metal Operator by default. Creating the `Provisioning` CR deploys Metal³ if the cluster-baremetal-operator is present. If Metal³ does not deploy, use Method A.

---

## 5. Disconnected Environment Considerations

### 5.1 RHCOS ISO

- Use the RHCOS ISO from your mirror or transfer package (same as SNO install).
- Ensure the worker can pull container images from your mirror registry (same `imageContentSources` / IDMS as the cluster).

### 5.2 Worker Ignition

- Serve `worker.ign` from an HTTP server **inside** the disconnected network.
- The worker must be able to reach this URL during `coreos-installer install`.

### 5.3 Image Pulls

- The worker inherits cluster-wide mirror configuration (ImageDigestMirrorSet / ImageContentSourcePolicy).
- Ensure the mirror registry is reachable from the worker's network.

---

## 6. HP Server Tips

- **UEFI boot** — Use UEFI, not legacy BIOS.
- **Secure Boot** — Disable if RHCOS has boot issues; re-enable after validation.
- **iLO firmware** — Keep current for Redfish compatibility.
- **Virtual media** — Eject after first reboot to avoid boot loops.
- **Boot order** — After install, ensure local disk is first in boot order.

---

## 7. Troubleshooting

| Issue | Possible Cause | Action |
|-------|----------------|--------|
| Worker not appearing in `oc get nodes` | CSR not approved, or ignition/network issue | Check `oc get csr`; approve pending CSRs; verify worker can reach API |
| `coreos-installer` fails to fetch ignition | Worker cannot reach HTTP server | Verify firewall, network, and URL from worker's network |
| Worker stuck in NotReady | CSR not approved, or kubelet not ready | Approve all CSRs; check `oc describe node <worker>` |
| Boot loop | Virtual media still mounted | Eject virtual media from iLO |
| Image pull errors on worker | Mirror not reachable or misconfigured | Verify mirror registry connectivity and IDMS/ICSP |
| BareMetalHost stuck in "registering" or "inspecting" | BMC unreachable, wrong credentials, or driver | Verify BMC address format (e.g. `redfish-virtualmedia://` for HP iLO); check secret; ensure virtual media supported |

---

## 8. Checklist Summary

**Method A (Manual):**
- [ ] Bare metal SNO cluster running OpenShift 4.20
- [ ] RHCOS ISO obtained; worker ignition extracted and served via HTTP
- [ ] Worker booted from ISO; `coreos-installer install` run
- [ ] Virtual media ejected; worker rebooted
- [ ] Pending CSRs approved; worker shows `Ready`

**Method B (Metal³/BareMetalHost):**
- [ ] Provisioning CR created; Metal³ pods running
- [ ] BMC secret and BareMetalHost CR created (Redfish-compatible BMC)
- [ ] BareMetalHost provisions node; pending CSRs approved

---

## 9. References

- [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md) — OpenShift 4.20 SNO install on bare metal HP server
- [RHOAI_3x_DISCONNECTED_SNO_INSTALLATION_PLAN.md](RHOAI_3x_DISCONNECTED_SNO_INSTALLATION_PLAN.md) — One SNO + one worker topology for RHOAI
- [Red Hat: How to Scale Single Node OpenShift Cluster](https://www.redhat.com/en/blog/how-to-scale-single-node-openshift-cluster)
- [Red Hat: Add additional worker node to RHOCP 4 SNO cluster](https://access.redhat.com/solutions/6978402) (subscription required)
- [OpenShift 4.20: Machine management](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/machine_management/) — Adding and maintaining cluster machines
- [OpenShift 4.20: Installing on a single node](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installing_on_a_single_node/)
- [OpenShift 4.20: Installing on bare metal — User-provisioned infrastructure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installing_on_bare_metal/user-provisioned-infrastructure)
- [OpenShift: Scaling a user-provisioned cluster with the Bare Metal Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/installing_on_bare_metal/scaling-a-user-provisioned-cluster-with-the-bare-metal-operator)
- [Metal³: Supported hardware](https://book.metal3.io/bmo/supported_hardware.html) — HP iLO, Dell iDRAC, Redfish
- [HPE iLO Redfish API](https://hewlettpackard.github.io/ilo-rest-api-docs/ilo6/)
