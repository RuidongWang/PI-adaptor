# PI-adaptor

Node 22 + TypeScript Host built on `@earendil-works/pi-coding-agent@1.3.0`.
PI-IOS drives this host over RACP v2 (protocol `2.0.0`). The name
**PI-adaptor** applies everywhere: package, environment namespace, systemd unit
and release artifacts.

PI-IOS consumes this repository as a git submodule at `apps/pi-adaptor`; the
submodule commit is the client's version pin. The two projects share no source
code — only the frozen RACP contract and the release layout below.

## Layout

| Path | Contents |
|---|---|
| `src/` | Host implementation (RACP, sessions, providers, media, skills, security) |
| `test/` | Vitest suites, including the frozen v2 contract |
| `scripts/build-release.sh` | Builds both linux architecture release archives |
| `scripts/install.sh` | Installer embedded in each release bundle (`--install/--verify/--rollback`) |
| `deploy/pi-adaptor.service` | systemd user unit example |
| `host-release.json` | Release coordinates: version, tag, artifact names and checksums |
| `docs/api/pi-adaptor.md` | Frozen RACP v2 contract |
| `docs/api/pi-adaptor.schema.json` | Machine-readable request/response schema |
| `docs/api/pi-adaptor.golden.json` | Golden protocol fixtures |
| `docs/api/pi-adaptor-install-release.md` | Install/verify/rollback contract |

## Run

```sh
pnpm install --ignore-scripts
# Self-contained: everything lives under ~/.pi-adaptor (data/agent/logs/run).
pnpm start -- --pair
```

`--pair` prints a one-time `ppt2.` token. The PI-IOS client accepts this token
and uses a v1-compatible handshake on the same WebSocket endpoint, so the
current SwiftUI project/session/turn flows work while the additive v2 methods
are adopted incrementally.

The Host binds only `127.0.0.1`. Reach it through the SSH `direct-tcpip`
tunnel; do not expose the port publicly.

## Release and install

```sh
# Version comes from package.json (single source); the script refuses to build
# bytes whose runtime version differs from host-release.json.
scripts/build-release.sh
# -> release/pi-adaptor-0.0.1-linux-x64.tar.gz(+.sha256)
# -> release/pi-adaptor-0.0.1-linux-arm64.tar.gz(+.sha256)

# The immutable release directory includes the full asset SHA-256.
scripts/install.sh --install \
  --bundle /absolute/path/pi-adaptor-0.0.1-linux-arm64 \
  --home "$HOME/.pi-adaptor" \
  --version 0.0.1 \
  --target linux-arm64 \
  --asset-sha256 <64-lowercase-hex> \
  --manifest-sha256 <64-lowercase-hex>
```

`install.sh` publishes into
`~/.pi-adaptor/releases/0.0.1-<full asset sha256>` and atomically replaces
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
`releases/0.0.1-<full asset sha256>`, the package is
`@pi-ios/pi-adaptor 0.0.1`, the unit is active, and `ExecStart` contains
`~/.pi-adaptor/current/dist/main.js`. A successful bootstrap state also has
`status=ok` and an `error=null`; the app should report RACP
`server.name=pi-adaptor` and `server.version=0.0.1`.

### Publishing

`scripts/build-release.sh` refuses to build when `package.json.version`,
`host-release.json.version` or the release tag disagree, and when the built
`dist/config.js` reports a different `HOST_VERSION`. Publish the two archives
and their checksums on the GitHub release `pi-adaptor-v<version>`.

The cross-repository gate lives in PI-IOS, because it also checks the client's
Swift constants and embedded install script:

```sh
# In a PI-IOS checkout with this submodule initialized:
python3 scripts/check-host-release-consistency.py
python3 scripts/check-host-release-consistency.py --published   # after upload
```

## Isolated configuration (independent of the legacy PI-Desktop host)

This Host is designed to run alongside the legacy PI-Desktop `pi-host` with
**zero shared state**. Full design: `docs/specs/pi-adaptor-isolated-config.md`.

- Single root: `--home <dir>` / `PI_ADAPTOR_HOME` (default `~/.pi-adaptor`).
  Derived defaults: `data/`, `agent/`, `logs/`, `run/`.
- Defaults never point at the legacy `~/.pi-desktop` or the shared `~/.pi/agent`.
- Config layers, high → low: CLI flag → `PI_ADAPTOR_*` env → `<home>/config.json`
  → derived default.
- Config file example: `config.example.json`.
- systemd user unit example: `deploy/pi-adaptor.service` (unit name
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
