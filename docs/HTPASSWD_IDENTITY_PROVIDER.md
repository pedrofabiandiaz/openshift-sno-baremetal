# HTPasswd identity provider (OpenShift 4.20)

This document describes how to enable **HTPasswd** authentication on OpenShift **4.20.x** when no `identityProviders` are configured yet. It matches the procedure validated for **4.20.18**.

For general OAuth and user concepts, see Red Hat’s [Configuring an HTPasswd identity provider](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/authentication_and_authorization/configuring-the-htpasswd-identity-provider) and [Preparing for users](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/postinstallation_configuration/post-install-preparing-for-users).

**Do not commit real passwords or `htpasswd` files to this repository.** Use a strong password and rotate it if it was ever shared.

## Prerequisites

- `oc` logged in as a user who can edit cluster configuration (for example `kubeadmin` or an existing cluster-admin).
- `htpasswd` installed (Fedora/RHEL: `dnf install httpd-tools`).

## 1. Create the htpasswd file (bcrypt)

Use **bcrypt** (`-B`); OpenShift expects this format.

Replace `'<your-password>'` with the password you choose for each user (they can all use the same password if desired).

```bash
HTPASSWD_FILE=/tmp/htpasswd-ocp
rm -f "$HTPASSWD_FILE"

htpasswd -c -B -b "$HTPASSWD_FILE" javier '<your-password>'
htpasswd -B -b "$HTPASSWD_FILE" andrew '<your-password>'
htpasswd -B -b "$HTPASSWD_FILE" fabian '<your-password>'
```

To add or change a user later, edit the same file with `htpasswd -B -b` (omit `-c` except for the first user) and update the secret in step 2.

## 2. Create the secret in `openshift-config`

**New secret:**

```bash
oc create secret generic htpasswd-secret \
  --from-file=htpasswd="$HTPASSWD_FILE" \
  -n openshift-config

oc label secret htpasswd-secret -n openshift-config "auth.openshift.io/managed-by=oauth"
```

**Update an existing secret** after changing the file:

```bash
oc set data secret/htpasswd-secret -n openshift-config --from-file=htpasswd="$HTPASSWD_FILE"
```

## 3. Configure OAuth

When **no** `identityProviders` exist yet, a merge patch is sufficient:

```bash
oc patch oauth cluster --type merge -p '{
  "spec": {
    "identityProviders": [
      {
        "name": "htpasswd",
        "mappingMethod": "claim",
        "type": "HTPasswd",
        "htpasswd": {
          "fileData": {
            "name": "htpasswd-secret"
          }
        }
      }
    ]
  }
}'
```

If you already have other identity providers, export `oauth cluster`, append this provider to `spec.identityProviders`, and `oc apply` the manifest instead of using the patch above (a merge patch can replace the whole list).

## 4. Wait for authentication

```bash
oc get co authentication
```

Proceed when `AVAILABLE` is `True`. The rollout usually takes about one to two minutes.

## 5. Verify login

```bash
oc login -u javier -p '<your-password>' --server=<api-url>
oc whoami
```

## 6. Grant cluster roles (optional)

HTPasswd only creates identities; it does not grant `cluster-admin`. Example:

```bash
oc adm policy add-cluster-role-to-user cluster-admin javier
oc adm policy add-cluster-role-to-user cluster-admin andrew
oc adm policy add-cluster-role-to-user cluster-admin fabian
```

Use narrower roles or project-scoped bindings as appropriate.

## 7. Disable kubeadmin (optional)

After you confirm another cluster-admin path works, follow Red Hat documentation to remove the `kubeadmin` secret in `kube-system` if your security policy requires it.

## `mappingMethod`

`claim` binds a username to the first identity that logs in with that name. If you later recreate users or secrets in non-trivial ways, review Red Hat’s documentation for `mappingMethod` (`claim` vs `add`) before changing configuration.
