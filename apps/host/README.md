# PI-adaptor

Node 22 + TypeScript Host built on `@earendil-works/pi-coding-agent@1.3.0`.
This is the host that PI-IOS drives over RACP v2 (protocol `2.0.0`). The project
name **PI-adaptor** applies everywhere: package, directories, environment
namespace, systemd unit and release artifacts.

## Run

```sh
cd apps/host
pnpm install --ignore-scripts
# Self-contained: everything lives under ~/.pi-adaptor (data/agent/logs/run).
pnpm start -- --pair
```

`--pair` prints a one-time `ppt2.` token. The existing PI-IOS client also
accepts this token and uses a v1-compatible handshake on the same WebSocket
endpoint, so the current SwiftUI project/session/turn flows work while the
additive v2 methods are adopted incrementally.

The Host binds only `127.0.0.1`. Reach it through the existing SSH
`direct-tcpip` tunnel; do not expose the port publicly.

## Release and install

```sh
# Version comes from package.json (single source); the script refuses to build
# bytes whose runtime version differs from the release manifest.
scripts/build-release.sh
# -> release/pi-adaptor-2.0.1-linux-x64.tar.gz(+.sha256)
# -> release/pi-adaptor-2.0.1-linux-arm64.tar.gz(+.sha256)

# The immutable release directory includes the full asset SHA-256.
scripts/install.sh --install \
  --bundle /absolute/path/pi-adaptor-2.0.1-linux-arm64 \
  --home "$HOME/.pi-adaptor" \
  --version 2.0.1 \
  --target linux-arm64 \
  --asset-sha256 <64-lowercase-hex> \
  --manifest-sha256 <64-lowercase-hex>
```

`install.sh` publishes into
`~/.pi-adaptor/releases/2.0.1-<full asset sha256>` and atomically replaces
`~/.pi-adaptor/current`. It also implements `--verify` and `--rollback` as
defined in `docs/api/pi-adaptor-install-release.md`. The generated bootstrap
uses the architecture-specific tarball selected from the server's `uname -m`.

Verify the active installation on the Linux server:

```sh
readlink -f "$HOME/.pi-adaptor/current"
node -p 'require(process.argv[1]).name + " " + require(process.argv[1]).version' \
  "$HOME/.pi-adaptor/current/package.json"
systemctl --user show pi-adaptor.service \
  --property=ActiveState --property=ExecStart --value
jq '{step,status,error}' "$HOME/.pi-adaptor/.bootstrap/state.json"
```

The expected active directory ends in
`releases/2.0.1-<full asset sha256>`, the package is
`@pi-ios/pi-adaptor 2.0.1`, the unit is active, and `ExecStart` contains
`~/.pi-adaptor/current/dist/main.js`. A successful bootstrap state also has
`status=ok` and an `error=null`; the app should report RACP
`server.name=pi-adaptor` and `server.version=2.0.1`.

The release gate checks the manifest, Swift constants, both deterministic
archives, archive layout and target native dependency before publication:

```sh
# Local gate: both architecture archives and adjacent checksums are mandatory.
python3 ../../scripts/check-host-release-consistency.py

# Pre-publication gate: also verifies the GitHub tag, both assets, and
# downloaded checksums through gh/GitHub HTTP.
python3 ../../scripts/check-host-release-consistency.py --published
```

## Isolated configuration (independent of the legacy PI-Desktop host)

This Host is designed to run alongside the legacy PI-Desktop `pi-host` with
**zero shared state**. Full design: `docs/specs/pi-adaptor-isolated-config.md`.

- Single root: `--home <dir>` / `PI_ADAPTOR_HOME` (default `~/.pi-adaptor`).
  Derived defaults: `data/`, `agent/`, `logs/`, `run/`.
- Defaults never point at the legacy `~/.pi-desktop` or the shared `~/.pi/agent`.
- Config layers, high → low: CLI flag → `PI_ADAPTOR_*` env → `<home>/config.json`
  → derived default.
- Config file example: `apps/host/config.example.json`.
- systemd user unit example: `apps/host/deploy/pi-adaptor.service` (unit name
  `pi-adaptor.service`; never touches the legacy host's unit/socket/locks).

```sh
pnpm start -- --home "$HOME/.pi-adaptor" --port 19445 --pair
```

## Security

- Data directories are `0700`; token and secret files are `0600`.
- Device and pairing tokens are stored only as SHA-256 hashes.
- Provider keys are never returned by API responses and are stored outside the
  provider index.
- Revoking a device closes its active WebSocket connections.
- WebSocket frames are text-only and bounded to 1 MiB.

## Tests

```sh
pnpm typecheck
pnpm test
pnpm build
```

The test suite includes the frozen v2 contract, real Pi v3 JSONL append/branch,
project/session metadata, token rotation, media uploads/GC, provider secrets,
Skill versions, WebSocket pairing, turn streaming and approval gating.
