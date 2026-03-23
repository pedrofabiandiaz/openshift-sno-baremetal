# oc-mirror-worker

A **linux/amd64** container image with the OpenShift CLI (`oc`, `kubectl`) and **`oc-mirror`**, built from Red Hat UBI 9 and client binaries published on [mirror.openshift.com](https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/). Use it when your workstation cannot run `oc-mirror` natively (for example **macOS**).

**Typical use here:** run **`oc-mirror --v2 --dry-run`** against one or more **ImageSet YAML** files (`apiVersion: mirror.openshift.io/v2alpha1`) to resolve **operator catalog image SHAs** and related references, without pulling full image layers. The wrapper defaults to dry-run; use a real mirror only when you intend to populate `mirror-output/`.

The repository wires this image to **[`scripts/run-oc-mirror-podman.sh`](../../scripts/run-oc-mirror-podman.sh)**, which builds the image, mounts your repo and output directory, and always runs **`oc-mirror --v2`** (no `--v1`).

## Choosing an ImageSet file

Point the wrapper at **any ImageSet YAML under this repository** (paths are relative to the repo root, or absolute paths that start with the repo root):

```bash
# Default file is imageset-rhoai.yaml
PULL_SECRET=~/pull-secret.json ./scripts/run-oc-mirror-podman.sh

# Another file in the repo (examples: imageset-platform.yaml, imageset-rhoai.yaml)
PULL_SECRET=~/pull-secret.json ./scripts/run-oc-mirror-podman.sh --config imageset-platform.yaml
# equivalent
CONFIG=imageset-platform.yaml PULL_SECRET=~/pull-secret.json ./scripts/run-oc-mirror-podman.sh

# Nested path
PULL_SECRET=~/pull-secret.json ./scripts/run-oc-mirror-podman.sh -c configs/my-imageset.yaml
```

`--config` / `-c` overrides the `CONFIG` environment variable for that invocation. The file must exist under the repo so it is visible inside the container at `/workspace/…`.

## Prerequisites

- **Podman** (with a running machine on macOS).
- A **pull secret** JSON from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) (or equivalent) so `oc-mirror` can authenticate to `registry.redhat.io` and other Red Hat registries. The wrapper defaults to `~/pull-secret.json`; override with `PULL_SECRET` if your file lives elsewhere.

## Build the image

From the repository root:

```bash
podman build --platform linux/amd64 \
  -f containers/oc-mirror/Containerfile \
  -t localhost/oc-mirror-worker:latest .
```

The build downloads `openshift-client-linux.tar.gz` and `oc-mirror.tar.gz` for the OCP version in the `Containerfile` (`ARG OCP_VERSION`, default **4.20.0**). To pin another z-stream:

```bash
podman build --platform linux/amd64 \
  --build-arg OCP_VERSION=4.19.5 \
  -f containers/oc-mirror/Containerfile \
  -t localhost/oc-mirror-worker:latest .
```

`--platform linux/amd64` keeps behavior consistent on **Apple Silicon** (Podman runs the image inside its Linux VM).

## Run (recommended)

Use the wrapper from the repo root; it rebuilds the image each run (so client versions stay aligned with the `Containerfile` unless you change the workflow).

**Dry-run by default** (catalog resolution and image references, including catalog-related SHAs, without pulling image layers):

```bash
PULL_SECRET=~/pull-secret.json ./scripts/run-oc-mirror-podman.sh
```

**Full mirror to disk** (disable dry-run):

```bash
OC_MIRROR_DRY_RUN=0 PULL_SECRET=~/pull-secret.json ./scripts/run-oc-mirror-podman.sh
```

**Build only** (no `oc-mirror` run):

```bash
./scripts/run-oc-mirror-podman.sh --build
```

**Custom command** inside the container (paths are under `/workspace` for the mounted repo, `/mirror` for output):

```bash
PULL_SECRET=~/pull-secret.json ./scripts/run-oc-mirror-podman.sh -- \
  oc-mirror --v2 --help
```

**List operator channels** (`oc-mirror list` only exists in the legacy code path; it does **not** take `--v1` or `--v2` — those flags apply to the main mirror command and produce `unknown flag: --v1` if you put them on `list`). Use:

```bash
PULL_SECRET=~/pull-secret.json ./scripts/run-oc-mirror-podman.sh -- \
  oc-mirror list operators \
    --catalog=registry.redhat.io/redhat/redhat-operator-index:v4.20 \
    --package=rhods-operator
```

The wrapper mounts your pull secret as **`/tmp/.docker/config.json`** (`HOME=/tmp`) because `list` has no `--authfile` flag.

## Environment variables (wrapper)

| Variable | Default | Meaning |
|----------|---------|---------|
| `PULL_SECRET` | `$HOME/pull-secret.json` | Registry auth JSON: mounted as `/run/secrets/pull-secret` (for `oc-mirror --v2 --authfile`) and as `/tmp/.docker/config.json` (for `oc-mirror list`, which has no `--authfile`). |
| `CONFIG` | `imageset-rhoai.yaml` | Image set config path **under the repo root** (overridden by `--config` / `-c`). |
| `MIRROR_OUT` | `<repo>/mirror-output` | Host directory for `file:///mirror` output. |
| `OC_MIRROR_IMAGE` | `localhost/oc-mirror-worker:latest` | Image name/tag the wrapper builds and runs. |
| `OC_MIRROR_DRY_RUN` | `1` | If not `0`, the wrapper adds `--dry-run`. Set to `0` for a real mirror. |

## ImageSet configuration

Use **`apiVersion: mirror.openshift.io/v2alpha1`** in your ImageSet YAML. This repo includes **[`imageset-rhoai.yaml`](../../imageset-rhoai.yaml)** (RHOAI-related operators and additional images) and **[`imageset-platform.yaml`](../../imageset-platform.yaml)** (platform release only). Add your own YAML under the repo, then pass it with `--config` or `CONFIG=`. If you still have legacy **`v1alpha2`** configs, migrate them for **`oc-mirror --v2`** using **[`INSTALLATION_PLAN.md`](../../INSTALLATION_PLAN.md)** and the [oc-mirror v2 documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/about-installing-oc-mirror-v2).

## Files in this directory

| File | Role |
|------|------|
| `Containerfile` | Defines `localhost/oc-mirror-worker` (UBI 9 + `oc` + `oc-mirror`). |

The Podman entrypoint for day-to-day use is **`scripts/run-oc-mirror-podman.sh`** at the repository root.
