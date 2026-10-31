# 测试用 SSH 私钥 fixture

这些文件是**临时生成**的测试密钥，不是任何真实服务器在用的密钥，也没有被任何地方部署。

## 生成方式

```bash
cd apps/ios/PIiOSKit/Tests/PIiOSNetTests/Fixtures
for spec in "ed25519 ed25519_none" "ed25519 ed25519_pass" \
            "ecdsa-256 ecdsa256_none" "ecdsa-256 ecdsa256_pass" \
            "ecdsa-384 ecdsa384_none" "ecdsa-521 ecdsa521_none" \
            "rsa-2048 rsa2048_none" "rsa-2048 rsa2048_pass" "rsa-3072 rsa3072_none"; do
  set -- $spec
  case "$2" in *_pass) P="pi-test-passphrase";; *) P="";; esac
  ssh-keygen -q -t "${1%%-*}" -b "$(echo "$1" | grep -o '[0-9]*$')" -f "$2" -N "$P" -C "pi-ios-test-fixture"
  mv "$2" "$2.key"; mv "$2.pub" "$2.key.pub"
done
```

- 未加密：`*_none.key`
- 带口令：`*_pass.key`，口令统一是 `pi-test-passphrase`
- 对应的 `.key.pub` 是 `ssh-keygen` 写出的公钥，测试用它逐字节校验解析结果

## 为什么提交进仓库

没有这些文件就无法验证「私钥能被解析、公钥与 `ssh-keygen` 一致、口令解密正确」——
而这正是 spec E6 的验收点。它们是消耗品，泄露也没有任何影响。
