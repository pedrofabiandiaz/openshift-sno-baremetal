# Updating API and Ingress TLS Certificates (SNO)

This document describes how to replace the **Kubernetes API** serving certificate and the **default Ingress Controller (router)** certificate on a Single Node OpenShift (SNO) cluster. It matches the DNS layout used in [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md): `api.<cluster_name>.<base_domain>` and `*.apps.<cluster_name>.<base_domain>`.

For full product detail, see Red Hat documentation for your OpenShift version (this repo targets **OpenShift 4.20**): [Replacing the default ingress certificate](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/security_and_compliance/configuring-certificates) and [Adding API server certificates](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/security_and_compliance/configuring-certificates#api-server-certificates).

---

## Prerequisites

- `oc` logged in as a user with **cluster-admin** (e.g. `kubeadmin` or an equivalent admin).
- A **TLS private key** and **certificate** (PEM) issued for the correct names:
  - **API:** Subject Alternative Name (SAN) must include the public API hostname, e.g. `api.sno.example.com` (and any other names clients use to reach the API).
  - **Ingress:** SAN must cover the **wildcard apps** name and the **non-wildcard** apps hostname, e.g. `*.apps.sno.example.com` and `apps.sno.example.com`.
- **Full chain in `tls.crt`:** Concatenate **leaf + intermediate(s)** in one file; order is leaf first, then intermediates. Keep the key unencrypted for Kubernetes secrets (or decode/decrypt before encoding to base64).
- **SNO impact:** The API and router pods run on the single control-plane node. Expect a **short disruption** to the API and console while certificates roll out; plan a maintenance window if operators or CI depend on the cluster.

Set placeholders for your environment:

```bash
export API_HOSTNAME="api.sno.example.com"           # your api FQDN
export APPS_WILDCARD="*.apps.sno.example.com"       # SAN on ingress cert
export APPS_HOSTNAME="apps.sno.example.com"         # optional but recommended SAN
```

---

## 1. API server certificate

The cluster `APIServer` object references a TLS secret in the **`openshift-config`** namespace. That secret holds `tls.crt` and `tls.key`.

### 1.1 Prepare the secret

From files on your workstation (`api.tls`, `api.key`). The same command creates the secret on first run and replaces it on later runs:

```bash
oc create secret tls api-server-custom-cert \
  --cert=api.tls \
  --key=api.key \
  -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -
```

> **Note:** The secret name `api-server-custom-cert` is an example; use any name and reference it in the `APIServer` patch below.

### 1.2 Point the API server at the secret

```bash
oc patch apiserver cluster --type=merge -p '
{
  "spec": {
    "servingCerts": {
      "namedCertificates": [
        {
          "names": [
            "'"${API_HOSTNAME}"'"
          ],
          "servingCertificate": {
            "name": "api-server-custom-cert"
          }
        }
      ]
    }
  }
}'
```

If you already had `namedCertificates` and need to **replace** the entry, edit instead of merge:

```bash
oc edit apiserver cluster
```

Under `spec.servingCerts.namedCertificates`, ensure one entry lists your API hostname and `servingCertificate.name` matches your secret name.

### 1.3 Wait and verify

The `kube-apiserver` operator rolls out the change (several minutes on SNO is normal).

```bash
oc get clusteroperator kube-apiserver
# Wait until AVAILABLE=True, PROGRESSING=False

openssl s_client -connect "${API_HOSTNAME}:6443" -servername "${API_HOSTNAME}" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Confirm `oc` still works:

```bash
oc whoami
oc get nodes
```

---

## 2. Default Ingress (router) certificate

The Ingress Operator uses a TLS secret named **`router-certs-default`** in the **`openshift-ingress`** namespace when present. The certificate must be valid for routes under your apps domain (wildcard + `apps.` hostname as above).

### 2.1 Create or update the secret

From `ingress.tls` and `ingress.key`:

```bash
oc create secret tls router-certs-default \
  --cert=ingress.tls \
  --key=ingress.key \
  -n openshift-ingress \
  --dry-run=client -o yaml | oc apply -f -
```

### 2.2 Wait for the router to reload

```bash
oc get clusteroperator ingress
# Wait until AVAILABLE=True, PROGRESSING=False

oc -n openshift-ingress get pods -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default
```

### 2.3 Verify

Pick any HTTPS route (e.g. console):

```bash
export CONSOLE_ROUTE="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
openssl s_client -connect "${CONSOLE_ROUTE}:443" -servername "${CONSOLE_ROUTE}" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Or with `curl`:

```bash
curl -vI "https://${CONSOLE_ROUTE}/" 2>&1 | grep -E 'subject|issuer|expire'
```

---

## 3. Reverting to operator-managed certificates

### API

Remove custom serving certs from the API server (restore operator-managed defaults):

```bash
oc patch apiserver cluster --type=json -p '[{"op":"remove","path":"/spec/servingCerts/namedCertificates"}]'
```

If that fails because the field is already absent, use `oc edit apiserver cluster` and delete the `namedCertificates` list under `spec.servingCerts`. You may delete the TLS secret in `openshift-config` after the rollout completes if it is no longer referenced.

### Ingress

Delete the default router secret so the operator generates one again:

```bash
oc delete secret router-certs-default -n openshift-ingress
```

Wait for the ingress operator and default router deployment to reconcile.

---

## 4. Troubleshooting (short)

| Symptom | Things to check |
|--------|------------------|
| `oc` fails with x509 / certificate errors after API change | SAN must include the hostname in `oc`’s `--server` / kubeconfig; chain complete in `tls.crt`; wait for `kube-apiserver` rollout. |
| Console or routes show wrong or old cert | Secret name must be exactly `router-certs-default` in `openshift-ingress`; cert must include `*.apps...` and `apps...`; check `oc get clusteroperator ingress` and router pod logs. |
| Merge patch refused or duplicate names | Use `oc edit apiserver cluster` and fix `namedCertificates` manually. |

---

## 5. See also

- [INSTALLATION_PLAN.md](INSTALLATION_PLAN.md) — DNS records for `api` and `*.apps`.
- [Day2-operations.md](Day2-operations.md) — Post-installation task index and doc links.
