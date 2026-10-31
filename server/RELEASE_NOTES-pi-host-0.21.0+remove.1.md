# pi-host 0.21.0+remove.1

Pinned Linux bundles for the PI-IOS client. They retain the upstream
v0.21.0 `host-core`, Node, agent runtime, and `node-pty` bytes and replace only
the architecture-independent `pi-host.js` with the provider-remove increment.

## Artifacts

| Target | File | SHA-256 |
| --- | --- | --- |
| linux-x64 | `pi-host-0.21.0+remove.1-linux-x64.tar.gz` | `53b25d752258fb4d02c7092c54b9daf6c649aade8c4899959a7cb00b1c44c856` |
| linux-arm64 | `pi-host-0.21.0+remove.1-linux-arm64.tar.gz` | `d4c77cadf9bcf5f9364176ed6e72bcd3d4557ad10d79bb6796cc7398b206737a` |

The `.sha256`, manifest, verification record, patch, and build scripts are
published alongside the bundles.

## Verification

- arm64 was installed and exercised natively on Ubuntu aarch64.
- x64 was installed and exercised under QEMU user-mode emulation in an amd64
  `ubuntu:22.04` container. It has not yet been exercised on native x64
  hardware.
- Both bundles passed installer self-verification, Host startup, provider
  import, remove/status checks, repeated-remove idempotency, and graceful
  shutdown.
- Assembly was repeated and produced identical bundle and manifest hashes.

## Source and license

- Upstream: `https://github.com/vastsa/PI-Desktop`
- Base commit: `d2c9fc44087f24260521c66530c4f92c04790105`
- Corresponding upstream source archive is attached to this release.
- Our patch and the three build/verification scripts are attached.
- Upstream license: LGPL-3.0; the license text is attached as `PI-Desktop-LICENSE`.

The source archive hash is
`509f6e77c01a0bd7afc167e1657ac104d6446ff4247fb65940d9137dfbbf1225`.

## Installation

The PI-IOS bootstrap installer selects the artifact for the server
architecture, verifies the pinned SHA-256, installs under
`~/.pi-desktop/pi-host/sha256-*`, and atomically switches `current`.
