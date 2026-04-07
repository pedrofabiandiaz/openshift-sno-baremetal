# LDAP identity provider (OpenShift 4.20, SNO)

This document describes how to add an **LDAP** identity provider to the cluster OAuth configuration. The steps are the same on **single-node OpenShift (SNO)** as on multi-node clusters: OAuth is served by the **authentication** operator, and LDAP must be reachable from the cluster (typically from pods in `openshift-authentication`).

For upstream concepts and advanced options, see Red Hat’s [Configuring an identity provider](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/authentication_and_authorization/configuring-identity-providers), [Understanding identity provider configuration](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/authentication_and_authorization/understanding-identity-provider), and [Preparing for users](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/postinstallation_configuration/post-install-preparing-for-users). For mapping LDAP groups to OpenShift groups, see [Syncing LDAP groups](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/authentication_and_authorization/ldap-syncing).

**Do not commit bind passwords, CA private keys, or real DNs to this repository.** Store secrets only in the cluster or your secret manager.

## Prerequisites

- `oc` logged in as a user who can edit cluster configuration (for example `kubeadmin` or cluster-admin).
- LDAP server hostname, port, and whether you use **TLS** (`ldaps://` or `STARTTLS` on `ldap://`).
- A **bind DN** and **bind password** for directory searches (service account), unless your directory allows anonymous bind for user lookup (uncommon in production).
- User search **base DN**, **scope** (`sub` is typical), and an LDAP **filter** that matches login users (for example `(objectClass=inetOrgPerson)`).
- Which LDAP attributes map to OpenShift **username**, **display name**, and **email** (defaults below match many `inetOrgPerson` layouts).

### Network (SNO)

From a debug pod or a test pod on the cluster, confirm the API can reach LDAP (DNS, firewall, and TLS):

```bash
# Example: run briefly on the cluster
oc run -it ldap-check --rm --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
  bash -c 'dnf install -y openssl nc >/dev/null 2>&1 || true; nc -vz ldap.example.com 636'
```

Adjust host, port, and tooling to match your environment.

## 1. Create the bind-password secret

The LDAP provider expects a secret in **`openshift-config`** with the key **`bindPassword`**.

```bash
oc create secret generic ldap-bind-secret \
  --from-literal=bindPassword='<bind-password>' \
  -n openshift-config

oc label secret ldap-bind-secret -n openshift-config "auth.openshift.io/managed-by=oauth"
```

To rotate the password later:

```bash
oc set data secret/ldap-bind-secret -n openshift-config --from-literal=bindPassword='<new-password>'
```

## 2. (Recommended) Trust the LDAP server CA

For `ldaps://` or `STARTTLS`, the authentication operator must trust the LDAP server certificate. If the cert is signed by a well-known public CA, you can often skip this. For private CAs or corporate roots, create a **ConfigMap** in `openshift-config` with PEM bundle(s):

```bash
oc create configmap ldap-ca \
  --from-file=ca.crt=/path/to/your/ldap-ca-bundle.pem \
  -n openshift-config

oc label configmap ldap-ca -n openshift-config "auth.openshift.io/managed-by=oauth"
```

If you use a single PEM file, naming the key `ca.crt` is conventional.

## 3. Build the LDAP URL

OpenShift uses an LDAP URL with a **query** part that defines how users are searched. Format:

```text
ldap[s]://<host>:<port>/<base_dn>?<username_attribute>?<scope>?<filter>
```

Example for `ldaps`, subtree search, and `inetOrgPerson` users:

```text
ldaps://ldap.example.com:636/ou=users,dc=example,dc=com?uid?sub?(objectClass=inetOrgPerson)
```

- **base_dn**: where searches start (for example `ou=users,dc=example,dc=com`).
- **username_attribute**: attribute whose value becomes the login name when using the patterns below (often `uid` or `sAMAccountName` for Active Directory).
- **scope**: usually `sub` (subtree).
- **filter**: LDAP filter; parentheses must be URL-encoded if you patch JSON from the shell (see step 4).

Escape characters as required for your shell and for JSON (for example `(objectClass=inetOrgPerson)` may need `\(` in some patch strings).

## 4. Configure OAuth

### 4a. No existing `identityProviders` (merge patch)

Replace placeholders with your values. This example maps:

- **preferredUsername** → `uid`
- **name** → `cn`
- **email** → `mail`
- **id** → `dn` (stable directory unique name)

```bash
oc patch oauth cluster --type merge -p '{
  "spec": {
    "identityProviders": [
      {
        "name": "ldap",
        "mappingMethod": "claim",
        "type": "LDAP",
        "ldap": {
          "attributes": {
            "id": ["dn"],
            "email": ["mail"],
            "name": ["cn"],
            "preferredUsername": ["uid"]
          },
          "bindDN": "uid=openshift-bind,ou=serviceaccounts,dc=example,dc=com",
          "bindPassword": {
            "name": "ldap-bind-secret"
          },
          "ca": {
            "name": "ldap-ca"
          },
          "insecure": false,
          "url": "ldaps://ldap.example.com:636/ou=users,dc=example,dc=com?uid?sub?(objectClass=inetOrgPerson)"
        }
      }
    ]
  }
}'
```

- Omit the entire `"ca": { "name": "ldap-ca" }` block if you rely on the system trust store only.
- Set `"insecure": true` only for **lab** scenarios with `ldap://` and no TLS (not recommended).

### 4b. Active Directory (typical tweaks)

Often you will use:

- **bindDN** like `CN=svc-openshift,OU=Service Accounts,DC=example,DC=com`.
- **url** with `sAMAccountName` and a base under your users OU, for example:
  - `ldaps://ad.example.com:636/OU=Users,DC=example,DC=com?sAMAccountName?sub?(objectClass=user)`
- **preferredUsername**: `["sAMAccountName"]`
- **email** / **name**: map to `mail`, `displayName`, or your directory’s attributes.

### 4c. Already have other identity providers

Export the OAuth object, add this provider to `spec.identityProviders`, and `oc apply -f` the manifest. A merge patch can **replace** the entire `identityProviders` list if you are not careful.

```bash
oc get oauth cluster -o yaml > oauth-cluster.yaml
# edit oauth-cluster.yaml, then:
oc apply -f oauth-cluster.yaml
```

## 5. Wait for authentication

```bash
oc get co authentication
```

Wait until `AVAILABLE` is `True`. Rollout typically takes about one to two minutes.

If the operator reports errors, inspect:

```bash
oc -n openshift-authentication get pods
oc -n openshift-authentication logs deployment/oauth-openshift --tail=100
```

Common issues: wrong bind DN/password, LDAP URL or filter mistakes, TLS trust (missing or wrong CA), or network egress blocked to LDAP.

## 6. Verify login

Use a directory user (not the bind account unless you intentionally allow it):

```bash
oc login -u '<ldap-username>' -p '<ldap-password>' --server=<api-url>
oc whoami
```

Confirm the console login page lists **LDAP** (or the `name` you set on the provider).

## 7. Grant cluster roles (optional)

LDAP authentication creates identities and users; it does **not** grant `cluster-admin`. Example:

```bash
oc adm policy add-cluster-role-to-user cluster-admin '<ldap-username>'
```

Prefer group-based RBAC after you configure [LDAP group sync](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/authentication_and_authorization/ldap-syncing).

## 8. Disable kubeadmin (optional)

After another cluster-admin login path is verified, you can remove the `kubeadmin` secret in `kube-system` per Red Hat documentation if your security policy requires it.

## `mappingMethod`

`claim` associates a given username with the first successful identity for that name. If you merge directories or change provider configuration in non-trivial ways, review Red Hat’s documentation for `claim` versus `add` before changing `mappingMethod`.
