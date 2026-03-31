#!/usr/bin/env python3
"""
Resolve a container image digest to manifest metadata (labels, created time, etc.)
by talking to the registry OCI/Docker HTTP API.

Examples:
  %(prog)s --reference 'nvcr.io/nvidia/gpu-operator@sha256:2e86875d61c030a9bd348a18bde8c4caa3d0c430a1aac642086b9cb1b3e3b015'
  %(prog)s --registry nvcr.io --repository nvidia/gpu-operator \\
      --digest sha256:2e86875d61c030a9bd348a18bde8c4caa3d0c430a1aac642086b9cb1b3e3b015
  %(prog)s --reference 'quay.io/org/app@sha256:...' --platform linux/amd64

  %(prog)s --registry nvcr.io --repository nvidia/gpu-operator --list-tags --semver-only --tag-sort semver-desc
  %(prog)s --compare-semver v25.3.3 v25.3.4
"""

from __future__ import annotations

import argparse
import json
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

# Loose semver / CalVer-friendly: optional v, major.minor.patch, optional -prerelease, optional +build
_SEMVER_TAG = re.compile(
    r"^v?(?P<maj>\d+)(?:\.(?P<min>\d+))?(?:\.(?P<pat>\d+))?"
    r"(?:-(?P<pre>[0-9A-Za-z.-]+))?(?:\+(?P<build>[0-9A-Za-z.-]+))?$",
    re.ASCII,
)
_TAGS_PAGE_N = 1000

# OCI / Docker manifest media types
_ACCEPT_MANIFEST = (
    "application/vnd.oci.image.index.v1+json,"
    "application/vnd.docker.distribution.manifest.list.v2+json,"
    "application/vnd.oci.image.manifest.v1+json,"
    "application/vnd.docker.distribution.manifest.v2+json"
)


def _parse_reference(ref: str) -> tuple[str, str, str]:
    """
    Parse 'registry/repo/path@sha256:...' or 'registry/repo/path@sha512:...'.
    Returns (registry_host, repository, digest_with_algo).
    """
    ref = ref.strip()
    if "://" in ref:
        _, _, rest = ref.partition("://")
        ref = rest.split("/", 1)[-1] if "/" in rest else rest
    if "@" not in ref:
        raise ValueError("reference must include @<digest>, e.g. image@sha256:...")
    name, digest = ref.rsplit("@", 1)
    digest = digest.strip()
    if not re.match(r"^(sha256|sha512):[a-f0-9]+$", digest, re.I):
        raise ValueError(f"unsupported digest form: {digest!r} (expected sha256:... or sha512:...)")

    slash = name.find("/")
    if slash == -1:
        raise ValueError(f"could not parse registry/repo from: {name!r}")
    host_candidate = name[:slash]
    remainder = name[slash + 1 :]
    if "." in host_candidate or host_candidate == "localhost" or ":" in host_candidate:
        registry, repository = host_candidate, remainder
    else:
        registry, repository = "docker.io", name
    if registry == "docker.io" and "/" not in repository:
        repository = "library/" + repository
    return registry, repository, digest.lower() if digest.startswith("sha") else digest


def _pre_identifier(part: str) -> tuple[int, int | str]:
    if part.isdigit():
        return (0, int(part))
    return (1, part)


def _prerelease_sort_key(prerelease: str) -> tuple[tuple[int, int | str], ...]:
    return tuple(_pre_identifier(p) for p in prerelease.split(".") if p)


def semver_sort_key(tag: str) -> tuple[Any, ...] | None:
    """
    Return a tuple sortable with normal tuple comparison, or None if the tag
    does not look like a semver/calver-style version (major.minor.patch...).
    Release builds sort after prereleases for the same core version.
    """
    m = _SEMVER_TAG.match(tag.strip())
    if not m:
        return None
    maj, min_, pat = int(m["maj"]), int(m["min"] or 0), int(m["pat"] or 0)
    pre = m["pre"]
    # 1 = release, 0 = prerelease (so (..., 1, ()) > (..., 0, ...))
    if pre:
        return (maj, min_, pat, 0, _prerelease_sort_key(pre))
    return (maj, min_, pat, 1, ())


def compare_semver(a: str, b: str) -> int:
    """Return -1 if a < b, 0 if equal, 1 if a > b. Raises ValueError if a tag is not semver-like."""
    ka, kb = semver_sort_key(a), semver_sort_key(b)
    if ka is None:
        raise ValueError(f"not a semver-shaped tag: {a!r}")
    if kb is None:
        raise ValueError(f"not a semver-shaped tag: {b!r}")
    if ka < kb:
        return -1
    if ka > kb:
        return 1
    return 0


def list_repository_tags(
    registry: str,
    repository: str,
    token: str | None = None,
    page_size: int = _TAGS_PAGE_N,
) -> tuple[list[str], str | None]:
    """Fetch all tag names via Docker Registry tags/list pagination. Returns (tags, bearer_token)."""
    all_tags: list[str] = []
    effective: str | None = token
    last: str | None = None
    while True:
        q: dict[str, str] = {"n": str(page_size)}
        if last is not None:
            q["last"] = last
        resource = "tags/list?" + urllib.parse.urlencode(q)
        code, _, body, effective = _registry_get(
            registry, repository, resource, accept="application/json", token=effective
        )
        if code != 200:
            raise RuntimeError(f"tags/list: HTTP {code}: {body[:300]!r}")
        data = json.loads(body.decode())
        batch: list[str] = list(data.get("tags") or [])
        if not batch:
            break
        all_tags.extend(batch)
        if len(batch) < page_size:
            break
        last = batch[-1]
    return all_tags, effective


def _registry_url(registry: str, path: str) -> str:
    scheme = "https"
    return f"{scheme}://{registry}/v2/{path}"


def _request(
    url: str,
    headers: dict[str, str],
    method: str = "GET",
    data: bytes | None = None,
) -> tuple[int, dict[str, str], bytes]:
    ctx = ssl.create_default_context()
    req = urllib.request.Request(url, method=method, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
            body = resp.read()
            hdrs = {k.lower(): v for k, v in resp.headers.items()}
            return resp.status, hdrs, body
    except urllib.error.HTTPError as e:
        body = e.read()
        hdrs = {k.lower(): v for k, v in e.headers.items()}
        return e.code, hdrs, body


def _parse_www_authenticate(value: str) -> dict[str, str]:
    # Bearer realm="https://...",service="...",scope="..."
    out: dict[str, str] = {}
    m = re.match(r"^\s*Bearer\s+(.+)$", value, re.I)
    if not m:
        return out
    parts = re.findall(r'(\w+)="([^"]*)"', m.group(1))
    for k, v in parts:
        out[k.lower()] = v
    return out


def _fetch_bearer_token(registry: str, repo: str, auth_params: dict[str, str]) -> str | None:
    realm = auth_params.get("realm")
    if not realm:
        return None
    service = auth_params.get("service", "")
    scope = auth_params.get("scope") or f"repository:{repo}:pull"
    q = urllib.parse.urlencode({"service": service, "scope": scope})
    token_url = f"{realm}?{q}"
    code, _, body = _request(token_url, {"Accept": "application/json"})
    if code != 200:
        return None
    try:
        data = json.loads(body.decode())
    except json.JSONDecodeError:
        return None
    return data.get("token") or data.get("access_token")


def _registry_get(
    registry: str,
    repository: str,
    resource: str,
    accept: str | None,
    token: str | None = None,
) -> tuple[int, dict[str, str], bytes, str | None]:
    """GET /v2/{repository}/{resource}. Returns (status, headers, body, bearer_token_used)."""
    path = f"{repository}/{resource}"
    url = _registry_url(registry, path)
    headers: dict[str, str] = {}
    if accept:
        headers["Accept"] = accept
    if token:
        headers["Authorization"] = f"Bearer {token}"
    code, hdrs, body = _request(url, headers)
    effective = token
    if code == 401 and "www-authenticate" in hdrs:
        params = _parse_www_authenticate(hdrs["www-authenticate"])
        new_token = _fetch_bearer_token(registry, repository, params)
        if new_token:
            effective = new_token
            headers["Authorization"] = f"Bearer {new_token}"
            if accept:
                headers["Accept"] = accept
            code, hdrs, body = _request(url, headers)
    return code, hdrs, body, effective


def _manifest_get(
    registry: str,
    repository: str,
    reference: str,
    accept: str,
    token: str | None,
) -> tuple[int, dict[str, str], bytes, str | None, str | None]:
    code, hdrs, body, effective = _registry_get(
        registry,
        repository,
        f"manifests/{urllib.parse.quote(reference, safe=':')}",
        accept,
        token=token,
    )
    digest = hdrs.get("docker-content-digest")
    return code, hdrs, body, digest, effective


def _pick_platform_manifest(
    manifest: dict[str, Any], os_: str, arch: str
) -> str | None:
    media_type = manifest.get("mediaType", "")
    if media_type in (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    ):
        for m in manifest.get("manifests", []):
            plat = m.get("platform") or {}
            if plat.get("os") == os_ and plat.get("architecture") == arch:
                return m.get("digest")
        # fallback: first manifest with digest
        for m in manifest.get("manifests", []):
            if m.get("digest"):
                return m["digest"]
    return None


def _config_digest_from_image_manifest(manifest: dict[str, Any]) -> str | None:
    mt = manifest.get("mediaType", "")
    if mt in (
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ) or (
        manifest.get("schemaVersion") == 2
        and "layers" in manifest
        and "config" in manifest
    ):
        cfg = manifest.get("config")
        if isinstance(cfg, dict) and cfg.get("digest"):
            return cfg["digest"]
    return None


def _fetch_blob_json(
    registry: str, repository: str, digest: str, token: str | None
) -> tuple[dict[str, Any], str | None]:
    resource = f"blobs/{urllib.parse.quote(digest, safe=':')}"
    code, _, body, effective = _registry_get(
        registry,
        repository,
        resource,
        accept="application/vnd.oci.image.config.v1+json",
        token=token,
    )
    if code != 200:
        code2, _, body2, effective2 = _registry_get(
            registry, repository, resource, accept=None, token=effective or token
        )
        if code2 != 200:
            raise RuntimeError(f"blob {digest}: HTTP {code} / retry {code2}")
        body = body2
        effective = effective2
    return json.loads(body.decode()), effective


def inspect_digest(
    registry: str,
    repository: str,
    digest: str,
    platform_os: str,
    platform_arch: str,
) -> dict[str, Any]:
    token: str | None = None
    code, _, raw, _, token = _manifest_get(
        registry, repository, digest, _ACCEPT_MANIFEST, token
    )
    if code != 200:
        raise RuntimeError(f"manifest {digest}: HTTP {code}: {raw[:500]!r}")
    manifest = json.loads(raw.decode())
    inner_digest = _pick_platform_manifest(manifest, platform_os, platform_arch)
    if inner_digest:
        code2, _, raw2, _, token = _manifest_get(
            registry, repository, inner_digest, _ACCEPT_MANIFEST, token
        )
        if code2 != 200:
            raise RuntimeError(f"platform manifest {inner_digest}: HTTP {code2}")
        manifest = json.loads(raw2.decode())

    cfg_digest = _config_digest_from_image_manifest(manifest)
    if not cfg_digest:
        return {
            "registry": registry,
            "repository": repository,
            "digest": digest,
            "manifest_media_type": manifest.get("mediaType"),
            "note": "no single-image manifest config found (unexpected media type)",
        }

    cfg, _ = _fetch_blob_json(registry, repository, cfg_digest, token)
    labels = (cfg.get("config") or {}).get("Labels") or {}
    return {
        "registry": registry,
        "repository": repository,
        "digest": digest,
        "config_digest": cfg_digest,
        "created": cfg.get("created"),
        "architecture": cfg.get("architecture"),
        "os": cfg.get("os"),
        "labels": labels,
    }


def _sort_tags(tags: list[str], tag_sort: str) -> list[str]:
    if tag_sort == "lex-asc":
        return sorted(tags)
    if tag_sort == "lex-desc":
        return sorted(tags, reverse=True)
    semver_tags = [t for t in tags if semver_sort_key(t) is not None]
    rest = [t for t in tags if semver_sort_key(t) is None]

    def _semver_key(t: str) -> tuple[Any, ...]:
        k = semver_sort_key(t)
        assert k is not None
        return k

    semver_tags.sort(key=_semver_key)
    if tag_sort == "semver-desc":
        semver_tags.reverse()
    rest.sort()
    return semver_tags + rest


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument(
        "--reference",
        help="Full image reference: host/repo@sha256:... (optional https:// prefix)",
    )
    p.add_argument(
        "--registry",
        help="Registry host (e.g. nvcr.io). Use with --repository and --digest if not using --reference.",
    )
    p.add_argument(
        "--repository",
        help="Repository path (e.g. nvidia/gpu-operator). Use with --registry and --digest.",
    )
    p.add_argument(
        "--digest",
        help="Digest sha256:... or sha512:.... Use with --registry and --repository.",
    )
    p.add_argument(
        "--platform",
        default="linux/amd64",
        help="OS/arch when the manifest is an index/list (default: %(default)s)",
    )
    p.add_argument(
        "--list-tags",
        action="store_true",
        help="List tags for --registry/--repository (no digest). Combine with --semver-only / --tag-sort.",
    )
    p.add_argument(
        "--semver-only",
        action="store_true",
        help="With --list-tags: keep only semver-shaped tags (e.g. v1.2.3, 25.3.4-rc.1).",
    )
    p.add_argument(
        "--tag-sort",
        choices=("semver-asc", "semver-desc", "lex-asc", "lex-desc"),
        default="semver-desc",
        help="Ordering for --list-tags (default: %(default)s). Non-semver tags follow semver tags when using semver-*.",
    )
    p.add_argument(
        "--compare-semver",
        nargs=2,
        metavar=("A", "B"),
        help="Compare two tag strings by semver rules; prints order (no registry call).",
    )
    p.add_argument("--json", action="store_true", dest="as_json", help="Print JSON only")
    args = p.parse_args()

    if args.compare_semver:
        a, b = args.compare_semver[0], args.compare_semver[1]
        try:
            cmp_val = compare_semver(a, b)
        except ValueError as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        labels = {-1: "less_than", 0: "equal", 1: "greater_than"}
        if args.as_json:
            print(
                json.dumps(
                    {
                        "a": a,
                        "b": b,
                        "cmp": cmp_val,
                        "relation": labels[cmp_val],
                    },
                    indent=2,
                )
            )
        else:
            human = {-1: f"{a!r} is older than {b!r}", 0: f"{a!r} and {b!r} are equal", 1: f"{a!r} is newer than {b!r}"}
            print(human[cmp_val])
        return 0

    if args.list_tags:
        if args.reference or args.digest:
            p.error("--list-tags does not use --reference or --digest")
        if not args.registry or not args.repository:
            p.error("--list-tags requires --registry and --repository")
        registry = args.registry.strip().rstrip("/")
        repository = args.repository.strip().lstrip("/")
        try:
            tags, _ = list_repository_tags(registry, repository)
        except Exception as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        if args.semver_only:
            tags = [t for t in tags if semver_sort_key(t) is not None]
        ordered = _sort_tags(tags, args.tag_sort)
        if args.as_json:
            print(json.dumps({"registry": registry, "repository": repository, "tags": ordered}, indent=2))
        else:
            for t in ordered:
                print(t)
        return 0

    if args.reference:
        if args.registry or args.repository or args.digest:
            p.error("do not combine --reference with --registry/--repository/--digest")
        registry, repository, digest = _parse_reference(args.reference)
    else:
        if not args.registry or not args.repository or not args.digest:
            p.error("provide --reference or all of --registry, --repository, and --digest")
        registry = args.registry.strip().rstrip("/")
        repository = args.repository.strip().lstrip("/")
        digest = args.digest.strip().lower()
        if not re.match(r"^(sha256|sha512):[a-f0-9]+$", digest, re.I):
            p.error("digest must look like sha256:... or sha512:...")

    plat = args.platform.split("/", 1)
    if len(plat) != 2:
        p.error("--platform must be os/arch, e.g. linux/amd64")
    os_, arch = plat[0], plat[1]

    try:
        result = inspect_digest(registry, repository, digest, os_, arch)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if args.as_json:
        print(json.dumps(result, indent=2))
        return 0

    print(f"registry:    {result['registry']}")
    print(f"repository:  {result['repository']}")
    print(f"digest:      {result['digest']}")
    if "config_digest" in result:
        print(f"config:      {result['config_digest']}")
        print(f"created:     {result.get('created')}")
        print(f"os/arch:     {result.get('os')}/{result.get('architecture')}")
        labels = result.get("labels") or {}
        if labels:
            print("labels:")
            for k in sorted(labels):
                print(f"  {k}: {labels[k]}")
    else:
        print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
