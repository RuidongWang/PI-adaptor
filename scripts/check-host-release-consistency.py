#!/usr/bin/env python3
"""host-release.json 一致性校验（发布前的唯一闸门）。

`host-release.json` 是 pi-host 发布坐标的唯一权威源。这个脚本把它和其余会“说出”版本的
地方逐一比对，避免「版本号改了、资产还是旧的」这类只能靠人眼发现的不一致：

  1. 结构自检：tag == v<version>、资产名 == <bundleDirectory>.tar.gz、sha256 格式。
  2. iOS 常量：`apps/ios/PIiOSKit/Sources/PIiOSCore/Bootstrap/BootstrapRelease.swift`
     的 `patchedReleaseVersion`、`patchedRepository`、`patchedChecksums`。
  3. 发布脚本：`server/scripts/assemble-pi-host-bundles.sh` 必须从本 JSON 读版本，
     不得再硬编码 `BUNDLE_VERSION=`（否则重建出来的包版本会与 App 期望不一致）。
  4. 若本地存在 `server/dist/<file>`，其 sha256 必须与 JSON 一致（防止发出了旧字节）。
  5. 若本地存在 `server/dist/pi-host-<version>-manifest.json`，其声明的版本与资产摘要
     必须与 JSON 一致。

用法：`python3 scripts/check-host-release-consistency.py`
退出码：0 一致；1 存在不一致（打印每条差异）。
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "host-release.json")
SWIFT = os.path.join(ROOT, "apps/ios/PIiOSKit/Sources/PIiOSCore/Bootstrap/BootstrapRelease.swift")
ASSEMBLE = os.path.join(ROOT, "server/scripts/assemble-pi-host-bundles.sh")
DIST = os.path.join(ROOT, "server/dist")

problems: list[str] = []


def fail(message: str) -> None:
    problems.append(message)


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    with open(MANIFEST, encoding="utf-8") as handle:
        manifest = json.load(handle)

    version = manifest["version"]
    tag = manifest["releaseTag"]
    repository = manifest["repository"]
    artifacts = manifest["artifacts"]
    upstream = manifest["upstreamVersion"]
    min_host = manifest["minHostVersion"]

    # 1. 结构自检
    if tag != f"v{version}":
        fail(f"releaseTag({tag}) != v<version>(v{version})")
    if not version.startswith(upstream):
        fail(f"version({version}) 必须以 upstreamVersion({upstream}) 为前缀")
    if min_host != upstream:
        fail(f"minHostVersion({min_host}) 必须等于 upstreamVersion({upstream})")
    if set(artifacts) != {"linux-x64", "linux-arm64"}:
        fail(f"artifacts 只允许 linux-x64/linux-arm64，实际 {sorted(artifacts)}")
    for key, entry in artifacts.items():
        if entry["file"] != f"{entry['bundleDirectory']}.tar.gz":
            fail(f"{key}: file 必须是 <bundleDirectory>.tar.gz")
        if not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            fail(f"{key}: sha256 必须是 64 位小写十六进制")
        if version not in entry["bundleDirectory"]:
            fail(f"{key}: bundleDirectory 必须包含版本号 {version}")

    # 2. iOS 常量
    swift = open(SWIFT, encoding="utf-8").read()
    match = re.search(r'patchedReleaseVersion\s*=\s*"([^"]+)"', swift)
    if not match:
        fail("BootstrapRelease.swift 缺少 patchedReleaseVersion")
    elif match.group(1) != version:
        fail(f"BootstrapRelease.patchedReleaseVersion({match.group(1)}) != manifest({version})")

    match = re.search(r'patchedRepository\s*=\s*"([^"]+)"', swift)
    if not match:
        fail("BootstrapRelease.swift 缺少 patchedRepository")
    elif match.group(1) != repository:
        fail(f"BootstrapRelease.patchedRepository({match.group(1)}) != manifest({repository})")

    checksums = dict(re.findall(r'\.(linuxX64|linuxArm64):\s*"([0-9a-f]{64})"', swift))
    expected_checksums = {
        "linuxX64": artifacts["linux-x64"]["sha256"],
        "linuxArm64": artifacts["linux-arm64"]["sha256"],
    }
    if checksums != expected_checksums:
        fail(f"patchedChecksums({checksums}) != manifest({expected_checksums})")

    # 3. 发布脚本不得再硬编码版本
    assemble = open(ASSEMBLE, encoding="utf-8").read()
    if "host-release.json" not in assemble:
        fail("assemble-pi-host-bundles.sh 没有读取 host-release.json")
    # 允许 `BUNDLE_VERSION=$(manifest_field version)`；只要出现字面量版本号就是漂移源。
    for line in assemble.splitlines():
        match = re.match(r"^\s*(BUNDLE_VERSION|VERSION)=(.+)$", line)
        if match and not match.group(2).startswith("$("):
            fail(f"assemble-pi-host-bundles.sh 仍把 {match.group(1)} 写成字面量：{line.strip()}")

    # 4./5. 本地产物（存在才校验）
    for key, entry in artifacts.items():
        path = os.path.join(DIST, entry["file"])
        if os.path.exists(path):
            actual = sha256_of(path)
            if actual != entry["sha256"]:
                fail(f"{entry['file']} 本地摘要 {actual} != manifest {entry['sha256']}")

    local_manifest = os.path.join(DIST, f"pi-host-{version}-manifest.json")
    if os.path.exists(local_manifest):
        with open(local_manifest, encoding="utf-8") as handle:
            built = json.load(handle)
        if built.get("version") != version:
            fail(f"{os.path.basename(local_manifest)} version({built.get('version')}) != {version}")
        # 该字段在构建产物里指上游 tag（v0.21.0），在本项目的 host-release.json 里指我们的 tag；
        # 两者都接受，其余一律视为漂移。
        allowed_tags = {tag, f"v{upstream}"}
        if built.get("releaseTag") not in (None, *allowed_tags):
            fail(f"{os.path.basename(local_manifest)} releaseTag({built.get('releaseTag')}) 既不是 {tag} 也不是 v{upstream}")
        if built.get("upstreamVersion") not in (None, upstream):
            fail(f"{os.path.basename(local_manifest)} upstreamVersion({built.get('upstreamVersion')}) != {upstream}")
        built_artifacts = built.get("artifacts") or {}
        if isinstance(built_artifacts, dict):
            for key, entry in built_artifacts.items():
                if key not in artifacts:
                    fail(f"本地 manifest 含未登记的目标 {key}")
                    continue
                if entry.get("file") != artifacts[key]["file"]:
                    fail(f"{key}: 本地 manifest file({entry.get('file')}) != {artifacts[key]['file']}")
                if entry.get("sha256") != artifacts[key]["sha256"]:
                    fail(f"{key}: 本地 manifest sha256({entry.get('sha256')}) != {artifacts[key]['sha256']}")
                if entry.get("topLevel") != artifacts[key]["bundleDirectory"]:
                    fail(f"{key}: 本地 manifest topLevel({entry.get('topLevel')}) != {artifacts[key]['bundleDirectory']}")

    if problems:
        print("host-release 一致性检查失败：")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(f"host-release 一致：version={version} tag={tag} artifacts={','.join(sorted(artifacts))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
