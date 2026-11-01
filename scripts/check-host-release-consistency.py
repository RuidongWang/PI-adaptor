#!/usr/bin/env python3
"""Validate the single PI-adaptor release contract.

This is the pre-release gate for host-release.json. It checks the Swift
constants, host package version, architecture-specific asset names/checksums,
and any locally built release artifacts before anything is uploaded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST_PATH = os.path.join(ROOT, "host-release.json")
PACKAGE_PATH = os.path.join(ROOT, "apps/host/package.json")
SWIFT_PATH = os.path.join(
    ROOT,
    "apps/ios/PIiOSKit/Sources/PIiOSCore/Bootstrap/BootstrapRelease.swift",
)
BUILD_SCRIPT_PATH = os.path.join(ROOT, "apps/host/scripts/build-release.sh")
INSTALL_SCRIPT_PATH = os.path.join(ROOT, "apps/host/scripts/install.sh")
SERVICE_PATH = os.path.join(ROOT, "apps/host/deploy/pi-adaptor.service")
DIST = os.path.join(ROOT, "apps/host/release")

problems: list[str] = []


def fail(message: str) -> None:
    problems.append(message)


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def swift_string(source: str, name: str) -> str | None:
    match = re.search(rf"{re.escape(name)}\s*=\s*\"([^\"]+)\"", source)
    return match.group(1) if match else None


def validate_archive(
    path: str,
    target: str,
    bundle: str,
    version: str,
    expected_installer: bytes,
) -> None:
    required_native = (
        f"{bundle}/node_modules/@earendil-works/pi-tui/native/"
        f"linux/prebuilds/linux-{'x64' if target == 'linux-x64' else 'arm64'}/"
        "linux-platform-x11.node"
    )
    try:
        with tarfile.open(path, "r:gz") as archive:
            names: set[str] = set()
            roots: set[str] = set()
            digests: dict[str, str] = {}
            package_bytes: bytes | None = None
            manifest_bytes: bytes | None = None
            installer_bytes: bytes | None = None
            for member in archive:
                name = member.name.rstrip("/")
                names.add(name)
                if name:
                    roots.add(name.split("/", 1)[0])
                normalized = posixpath.normpath(member.name)
                if normalized.startswith("../") or normalized.startswith("/"):
                    fail(f"{os.path.basename(path)} contains unsafe path {member.name}")
                if member.issym() or member.islnk():
                    fail(f"{os.path.basename(path)} contains symbolic link {member.name}")
                if not member.isfile():
                    continue
                relative = member.name[len(bundle) + 1 :] if member.name.startswith(f"{bundle}/") else member.name
                stream = archive.extractfile(member)
                if relative in {"package.json", "SHA256SUMS", "scripts/install.sh"}:
                    payload = stream.read() if stream else b""
                    if relative == "package.json":
                        package_bytes = payload
                    elif relative == "SHA256SUMS":
                        manifest_bytes = payload
                    else:
                        installer_bytes = payload
                    digests[relative] = hashlib.sha256(payload).hexdigest()
                else:
                    digest = hashlib.sha256()
                    if stream is not None:
                        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                            digest.update(chunk)
                    digests[relative] = digest.hexdigest()
            if roots != {bundle}:
                fail(f"{os.path.basename(path)} top-level roots({sorted(roots)}) != [{bundle}]")
                return
            if required_native not in names:
                fail(f"{os.path.basename(path)} is missing target native dependency {required_native}")
            foreign = [
                name
                for name in names
                if "/@earendil-works/pi-tui/native/" in name
                and name.endswith(".node")
                and name != required_native
            ]
            if foreign:
                fail(f"{os.path.basename(path)} contains foreign native dependencies: {foreign[:3]}")

            if package_bytes is None:
                fail(f"{os.path.basename(path)} is missing package.json")
            else:
                package = json.loads(package_bytes.decode("utf-8"))
                if package.get("name") != "@pi-ios/pi-adaptor":
                    fail(f"{os.path.basename(path)} package name is not @pi-ios/pi-adaptor")
                if package.get("version") != version:
                    fail(f"{os.path.basename(path)} package version({package.get('version')}) != {version}")
            if installer_bytes != expected_installer:
                fail(f"{os.path.basename(path)} contains a stale install.sh")

            if manifest_bytes is None:
                fail(f"{os.path.basename(path)} is missing SHA256SUMS")
                return
            try:
                manifest_text = manifest_bytes.decode("utf-8")
            except UnicodeDecodeError:
                fail(f"{os.path.basename(path)} SHA256SUMS is not UTF-8")
                return
            rows: list[tuple[str, str]] = []
            for line in manifest_text.splitlines():
                match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
                if not match:
                    fail(f"{os.path.basename(path)} has malformed SHA256SUMS line")
                    break
                digest, relative = match.groups()
                if relative.startswith("/") or "../" in relative.split("/"):
                    fail(f"{os.path.basename(path)} has unsafe SHA256SUMS path {relative}")
                    break
                rows.append((relative, digest))
            if [relative for relative, _ in rows] != sorted(
                (relative for relative, _ in rows), key=lambda value: value.encode("utf-8")
            ):
                fail(f"{os.path.basename(path)} SHA256SUMS is not bytewise path-sorted")
            expected_paths = sorted(name for name in digests if name != "SHA256SUMS")
            if [relative for relative, _ in rows] != expected_paths:
                fail(f"{os.path.basename(path)} SHA256SUMS does not cover the archive exactly")
                return
            for relative, expected_digest in rows:
                if relative not in digests or digests[relative] != expected_digest:
                    fail(f"{os.path.basename(path)} checksum mismatch for {relative}")
                    return
    except (OSError, tarfile.TarError, json.JSONDecodeError) as error:
        fail(f"{os.path.basename(path)} could not be validated: {error}")


def validate_local_artifacts(
    artifacts: dict,
    version: str,
    expected_installer: bytes,
    dist: str,
) -> None:
    for target, entry in artifacts.items():
        archive = os.path.join(dist, entry["file"])
        checksum_file = archive + ".sha256"
        if not os.path.isfile(archive):
            fail(f"{entry['file']} is missing from {dist}")
            continue
        actual = sha256_of(archive)
        if actual != entry["sha256"]:
            fail(f"{entry['file']} local sha256({actual}) != manifest({entry['sha256']})")
            continue
        validate_archive(
            archive,
            target,
            entry["bundleDirectory"],
            version,
            expected_installer,
        )
        if not os.path.isfile(checksum_file):
            fail(f"{entry['file']}.sha256 is missing from {dist}")
            continue
        with open(checksum_file, encoding="ascii") as handle:
            line = handle.read().strip()
        expected = f"{entry['sha256']}  {entry['file']}"
        if line.lower() != expected:
            fail(f"{entry['file']}.sha256 content does not bind the manifest digest")


def github_release(repository: str, tag: str) -> dict:
    endpoint = f"repos/{repository}/releases/tags/{tag}"
    gh = shutil.which("gh")
    if gh:
        result = subprocess.run(
            [gh, "api", endpoint],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
        gh_error = result.stderr.strip() or f"gh exited {result.returncode}"
    else:
        gh_error = "gh executable unavailable"

    url = f"https://api.github.com/{endpoint}"
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "PI-IOS-release-gate"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        raise RuntimeError(f"GitHub release API failed ({gh_error}): {error}") from error


def download_url(url: str, *, text: bool = False, limit: int | None = None) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "PI-IOS-release-gate"})
    digest = hashlib.sha256()
    chunks = bytearray()
    with urllib.request.urlopen(request, timeout=30) as response:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            if text:
                chunks.extend(chunk)
                if limit is not None and len(chunks) > limit:
                    raise RuntimeError(f"downloaded response exceeds {limit} bytes")
    return chunks.decode("utf-8") if text else digest.hexdigest()


def validate_published(manifest: dict) -> None:
    repository = manifest["repository"]
    tag = manifest["releaseTag"]
    artifacts = manifest["artifacts"]
    try:
        release = github_release(repository, tag)
    except (RuntimeError, json.JSONDecodeError) as error:
        fail(str(error))
        return
    if not isinstance(release, dict):
        fail(f"published release response for {tag} is not a JSON object")
        return
    if release.get("tag_name") != tag:
        fail(f"published release tag({release.get('tag_name')}) != {tag}")
    if release.get("draft") is True:
        fail(f"published release {tag} is still a draft")

    assets = {
        str(asset.get("name")): asset
        for asset in release.get("assets", [])
        if isinstance(asset, dict) and asset.get("name")
    }
    expected_names = {
        entry["file"] for entry in artifacts.values()
    } | {
        entry["file"] + ".sha256" for entry in artifacts.values()
    }
    missing = sorted(expected_names - assets.keys())
    if missing:
        fail(f"published release {tag} is missing assets: {', '.join(missing)}")
        return

    for target, entry in artifacts.items():
        artifact_asset = assets[entry["file"]]
        checksum_asset = assets[entry["file"] + ".sha256"]
        artifact_url = artifact_asset.get("browser_download_url")
        checksum_url = checksum_asset.get("browser_download_url")
        if not isinstance(artifact_url, str) or not artifact_url.startswith("https://"):
            fail(f"{target} artifact has no HTTPS browser_download_url")
            continue
        if not isinstance(checksum_url, str) or not checksum_url.startswith("https://"):
            fail(f"{target} checksum has no HTTPS browser_download_url")
            continue
        try:
            actual = download_url(artifact_url)
            checksum_text = download_url(checksum_url, text=True, limit=4096)
        except (OSError, urllib.error.URLError, RuntimeError) as error:
            fail(f"{entry['file']} published download failed: {error}")
            continue
        if actual != entry["sha256"]:
            fail(f"{entry['file']} published sha256({actual}) != manifest({entry['sha256']})")
        expected_checksum = f"{entry['sha256']}  {entry['file']}"
        if checksum_text.strip().lower() != expected_checksum:
            fail(f"{entry['file']}.sha256 published content is inconsistent")


def parse_arguments(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--published",
        action="store_true",
        help="also verify the GitHub release metadata, both dual-architecture assets, and checksums",
    )
    parser.add_argument(
        "--dist",
        default=DIST,
        help="local release directory to validate",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    with open(MANIFEST_PATH, encoding="utf-8") as handle:
        manifest = json.load(handle)
    with open(PACKAGE_PATH, encoding="utf-8") as handle:
        package = json.load(handle)
    with open(SWIFT_PATH, encoding="utf-8") as handle:
        swift = handle.read()
    with open(BUILD_SCRIPT_PATH, encoding="utf-8") as handle:
        build_script = handle.read()
    with open(INSTALL_SCRIPT_PATH, encoding="utf-8") as handle:
        install_script = handle.read()
    with open(SERVICE_PATH, encoding="utf-8") as handle:
        service = handle.read()

    if manifest.get("schemaVersion") != 2:
        fail("host-release.json schemaVersion must be 2")

    version = manifest.get("version")
    tag = manifest.get("releaseTag")
    repository = manifest.get("repository")
    runtime = manifest.get("runtime") or {}
    install = manifest.get("install") or {}
    artifacts = manifest.get("artifacts") or {}

    if version != package.get("version"):
        fail(f"manifest version({version}) != apps/host/package.json({package.get('version')})")
    if package.get("name") != "@pi-ios/pi-adaptor":
        fail(f"apps/host/package.json name({package.get('name')}) != @pi-ios/pi-adaptor")
    if tag != f"pi-adaptor-v{version}":
        fail(f"releaseTag({tag}) != pi-adaptor-v<version>")
    if repository != "RuidongWang/PI-adaptor":
        fail(f"repository({repository}) != RuidongWang/PI-adaptor")
    if manifest.get("protocolVersion") != "2.0.0":
        fail("protocolVersion must be 2.0.0")
    if runtime.get("serverName") != "pi-adaptor":
        fail("runtime.serverName must be pi-adaptor")

    expected_install = {
        "home": "~/.pi-adaptor",
        "versionsDirectory": "~/.pi-adaptor/releases",
        "currentLink": "~/.pi-adaptor/current",
        "unitName": "pi-adaptor.service",
        "entrypoint": "dist/main.js",
        "installer": "scripts/install.sh",
        "packageManifest": "package.json",
        "minimumNodeVersion": "22.19.0",
    }
    for key, expected in expected_install.items():
        if install.get(key) != expected:
            fail(f"install.{key}({install.get(key)}) != {expected}")

    expected_cpu = {"linux-x64": "x64", "linux-arm64": "arm64"}
    if set(artifacts) != set(expected_cpu):
        fail(f"artifacts must be exactly {sorted(expected_cpu)}, got {sorted(artifacts)}")
    for key in expected_cpu:
        entry = artifacts.get(key) or {}
        bundle = f"pi-adaptor-{version}-{key}"
        file = f"{bundle}.tar.gz"
        if entry.get("bundleDirectory") != bundle:
            fail(f"{key}.bundleDirectory must be {bundle}")
        if entry.get("file") != file:
            fail(f"{key}.file must be {file}")
        if not re.fullmatch(r"[0-9a-f]{64}", str(entry.get("sha256", ""))):
            fail(f"{key}.sha256 must be 64 lowercase hex characters")
        if entry.get("sha256") == "0" * 64:
            fail(f"{key}.sha256 is still a placeholder")

    swift_expected = {
        "releaseRepository": repository,
        "releaseVersion": version,
        "releaseTag": tag,
        "runtimeServerName": runtime.get("serverName"),
        "unitName": install.get("unitName"),
        "entrypoint": install.get("entrypoint"),
        "minimumNodeVersion": install.get("minimumNodeVersion"),
    }
    for name, expected in swift_expected.items():
        actual = swift_string(swift, name)
        if actual != expected:
            fail(f"BootstrapRelease.{name}({actual}) != {expected}")

    checksums = dict(
        re.findall(r"\.(linuxX64|linuxArm64):\s*\"([0-9a-f]{64})\"", swift)
    )
    expected_checksums = {
        "linuxX64": artifacts.get("linux-x64", {}).get("sha256"),
        "linuxArm64": artifacts.get("linux-arm64", {}).get("sha256"),
    }
    if checksums != expected_checksums:
        fail(f"Swift patchedChecksums({checksums}) != manifest({expected_checksums})")

    if "pi-adaptor-$VERSION-$target" not in build_script:
        fail("build-release.sh does not name architecture-specific PI-adaptor assets")
    for action in ("--install", "--verify", "--rollback"):
        if action not in install_script:
            fail(f"install.sh does not implement {action}")
    for build_token in (
        '--cpu="$cpu"',
        "--os=linux",
        "SHA256SUMS",
        "prune_target_native_dependencies",
        "linux-platform-x11.node",
    ):
        if build_token not in build_script:
            fail(f"build-release.sh is missing {build_token}")
    if "current/dist/main.js" not in service:
        fail("pi-adaptor.service does not use current/dist/main.js")
    if "pi-host.js" in service or ".pi-desktop/pi-host" in service:
        fail("pi-adaptor.service still references the legacy pi-host runtime")

    validate_local_artifacts(
        artifacts,
        version,
        install_script.encode("utf-8"),
        os.path.abspath(arguments.dist),
    )

    if arguments.published and not problems:
        validate_published(manifest)

    if problems:
        print("PI-adaptor release consistency failed:")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    print(
        "PI-adaptor release consistency passed: "
        f"version={version} tag={tag} artifacts={','.join(sorted(artifacts))} "
        f"mode={'local+published' if arguments.published else 'local'}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
