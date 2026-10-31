#!/usr/bin/env bash
# Fail if the working tree appears to contain a live credential or a local identity.
#
# Run before committing / uploading。覆盖四类：
#   1. 服务商风格 API Key（OpenAI / DeepSeek `sk-…`）
#   2. pi-host 配对 / 设备令牌（`ppt2.` / `pdt2.`）
#   3. PEM 私钥块（整行 `-----BEGIN … PRIVATE KEY-----`）
#   4. 本机绝对主目录路径（`/Users/<name>/`）——会泄漏开发机用户名
#
# 说明：
#   - 真实服务器 IP 不写进本脚本（写进来本身就是泄漏）；那类问题靠 docs/qa/ 下的证据
#     文件与发布前人工复核，本脚本只挡可机械识别的形态。
#   - `/home/<name>/` 不作为命中项：`/home/ubuntu`、`/home/deploy` 是云主机默认用户，
#     在契约示例与测试里正常出现，纳入会产生大量假阳性。
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"

# 排除：构建产物、依赖、发布件、测试私钥 fixture，以及本脚本自身（规则文本会自命中）。
# `--hidden` 让 `.env` 这类点文件也进扫描（rg 默认跳过隐藏文件）；.gitignore 规则仍生效。
rg_flags=(
  --hidden
  --glob '!**/.git/**'
  --glob '!**/node_modules/**'
  --glob '!**/.build/**'
  --glob '!**/dist/**'
  --glob '!**/build/**'
  --glob '!**/release/**'
  --glob '!**/Vendor/**'
  --glob '!**/Tests/**/Fixtures/**'
  --glob '!scripts/check-secrets.sh'
)

grep_excludes=(
  --exclude-dir=node_modules --exclude-dir=.build --exclude-dir=dist
  --exclude-dir=build --exclude-dir=release --exclude-dir=Vendor
  --exclude-dir=Fixtures --exclude=check-secrets.sh
)

status=0

# scan <pattern> [skip-pattern]
# skip-pattern 用于滤掉刻意保留的假阳性（测试用示例路径等）。
scan() {
  local pattern="$1"
  local skip="${2:-}"
  local hits

  if command -v rg >/dev/null 2>&1; then
    hits=$(rg -n -e "$pattern" "${rg_flags[@]}" . || true)
    if [[ -n "$skip" && -n "$hits" ]]; then
      hits=$(printf '%s\n' "$hits" | rg -v -e "$skip" || true)
    fi
  else
    hits=$(grep -RInE -- "$pattern" "${grep_excludes[@]}" . || true)
    if [[ -n "$skip" && -n "$hits" ]]; then
      hits=$(printf '%s\n' "$hits" | grep -vE -- "$skip" || true)
    fi
  fi

  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    status=1
  fi
}

scan 'sk-[A-Za-z0-9_-]{30,}'                          # 占位符 sk-REPLACE_ME 不会命中
scan '(ppt2|pdt2)\.[A-Za-z0-9._-]{20,}'
scan '-----BEGIN [A-Z ]*PRIVATE KEY-----[[:space:]]*$'
scan '/Users/[A-Za-z0-9._-]+/' '/Users/(me|user|shared)/'

if [[ $status -ne 0 ]]; then
  echo "✗ 发现疑似凭证或本机身份信息：请删除/轮换，或替换为占位符（见 docs/qa/2026-10-31-deepseek-live-test.md §4）" >&2
  exit 1
fi
echo "✓ 未发现疑似凭证或本机身份信息"
