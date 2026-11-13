# Server Extensions V1 — implementation and verification

Implemented against the FROZEN `docs/api/server-extensions-v1.md` in the parent workspace. This document covers the Host only. No SDK upgrade, commit, deployment, root documentation or iOS change was performed.

## Operation

`config.json` may contain:

```json
{
  "extensions": {
    "enabled": false,
    "entries": [
      {
        "id": "reviewed-tools",
        "entryPath": "/srv/pi-extensions/reviewed-tools.ts",
        "name": "Reviewed Tools",
        "version": "1.0.0",
        "enabled": true,
        "compatibility": "headless-reviewed"
      }
    ]
  }
}
```

Only explicitly registered, enabled, readable regular local `.ts`, `.js`, `.mjs` files declared `headless-reviewed` load when the host switch is enabled. Configuration errors fail startup. Missing/unreadable entries and canonical duplicates are diagnosed independently. Queries perform filesystem validation, never module import. No directory discovery, npm/Git installation, UI bridge or extension command invocation is exposed. Names and versions are administrator declarations.

Configuration is immutable for the process. Restart after configuration, entry code or dependency changes. Entry canonical path and filesystem identity/size/change timestamps are pinned during Host initialization; a changed/repaired entry is unavailable until restart with `ENTRY_CHANGED_RESTART_REQUIRED`. This is a change detector, not a code/dependency integrity hash or a security boundary. Dependencies and transitive imports must also be administrator controlled; filesystem checks do not eliminate replacement races.

Limits: 100 configured entries; ID 1–64 characters from `[a-zA-Z0-9._-]`; configured name/version up to 256 characters; path up to 4096 characters. Runtime tool/command lists are capped at 200 names per list and 256 characters per name; diagnostics at 20 per entry/snapshot and 1024 characters per message; snapshot budget 256 KiB including persistence indentation, with explicit truncation diagnostics. Runtime warning events aggregate duplicates and publish at most 20 updates per turn in addition to loading/ready-or-failed/final-cleanup updates. Snapshot queries use disk rather than an unbounded session cache.

SDK errors are untrusted. Host diagnostics use fixed messages and codes and do not return the original error text, stack, key, token or environment value. Existing per-turn provider key handling remains unchanged. Extension code has the Host OS user's permissions: tool approval is not a code sandbox and cannot constrain an extension's direct filesystem/network/process/logging side effects. Only individually reviewed headless, per-turn extensions are supported. An extension must release its own timers/connections in `session_shutdown`.

## Lifecycle and wire behavior

The loader retains `noExtensions:true` and receives only selected canonical explicit paths plus the hidden named internal `host-approval` factory. After reload, SDK results determine actual loaded instances, registration errors and warnings. `bindExtensions` runs once before prompt with no UI, error capture and an internal startup check. Approval absence, registration failure or startup failure blocks prompt; approval callback failure or a missing affirmative decision blocks tools.

Normal completion, errors and cancellation await `session_shutdown` with reason `quit`, unsubscribe and dispose. If construction fails after loading but before an AgentSession exists, a temporary SDK ExtensionRunner emits shutdown and invalidates the loaded runtime. The driver sends its terminal event only after cleanup. Host execution slots also remain occupied until `handle.wait()` settles; cancellation releases pending approvals before awaiting abort, avoiding the tool-approval deadlock. Process signal shutdown waits for the same cleanup. There is deliberately no timeout that pretends arbitrary hanging JavaScript has stopped: an uncooperative extension can keep shutdown/cancel pending and is unsuitable for V1.

`extension/list` and `session/extensions` are authenticated read-only RPCs, require no mutation context, and do not increment session revision or emit session-changed events. Both protocol versions advertise `extensionInventory:true`, `sessionExtensions:true`, `extensionManagement:false`, `extensionUI:false`. `session.extensions.updated` is a session event with Snapshot directly as payload. It uses the existing session mutex, per-turn event chain, journal, ACK and replay path. Late callbacks from previous turns do not replace current snapshots or grow extension event-chain state. `runningTurnId` is process execution state; stored snapshots remain history after restart.

## Storage, migration and rollback

No SQL/database schema migration or separate migration script is required. New sidecars are `<dataDir>/meta/extensions/<sha256(sessionId)>.json`, atomically written with mode 0600. Each stores latestAttempt and previousCompleted; malformed files fail explicitly. Original native session/catalog file formats are unchanged; branches do not copy snapshots. Session/project deletion clears corresponding sidecars under session locks; startup removes orphan sidecars.

Deployment/rollback classification for deploy-engineer:

| Operation | Reversible | Data-loss risk | Downtime |
| --- | --- | --- | --- |
| Introduce the sidecar directory | Yes; old Host ignores retained files | None to original session history | Host restart required for code/config activation |
| Startup reconciliation (`loading` → `failed`, `AGENT_RESTARTED`) | **No automatic inverse; restore a backup to recover the previous sidecar bytes** | Replaces interrupted loading status; does not restore or resume execution | Runs at startup, no additional outage |
| Startup orphan cleanup or explicit session/project deletion | **No automatic inverse; backup required** | Deletes extension snapshot history for deleted sessions | No extra downtime; busy session deletion is rejected |
| Disable extensions and restart | Yes | In-flight work must be stopped/drained; retained extension history remains | Controlled Host restart |

Before rolling back an old Host, back up configuration and sidecars, stop/drain running work, disable/remove the new extensions configuration field and restart with the older binary. Retaining sidecars allows a later upgrade to read them again. Do not describe a restart as preserving in-flight JavaScript execution.

## Verification

SDK version: `@earendil-works/pi-coding-agent` 1.3.0, `@earendil-works/pi-ai` 1.3.0. Tests use isolated temp directories, in-memory SDK settings and a local scripted OpenAI SSE transport. No real model/server or device acceptance run is represented as passed.

Environment: Node v22.22.0, pnpm 12.8.1, Vitest 4.1.11. Commands executed for this implementation:

```bash
pnpm --dir apps/pi-adaptor typecheck
pnpm --dir apps/pi-adaptor exec vitest run test/extensions-sdk.test.ts test/extensions-registry.test.ts test/extensions-snapshot-store.test.ts test/extensions-driver.test.ts test/extensions-api.test.ts test/contract.test.ts
pnpm --dir apps/pi-adaptor exec vitest run test/config.test.ts -t extensions
pnpm --dir apps/pi-adaptor exec vitest run test/approval.test.ts test/ws.test.ts -t 'extension integration'
```


Final results: extension/SDK/contract suites **47 passed, 0 failed, 0 skipped** (SDK 5, registry 9, store 5, driver 11, API 13, contract 4); extension-filtered configuration **14 passed, 0 failed, 13 filtered out**; approval extension integration **5 passed, 0 failed, 2 filtered out**; WebSocket extension integration **2 passed, 0 failed, 6 filtered out**. Total **68 passed, 0 failed, 21 filtered out** across the requested extension checks. Typecheck and `git diff --check` passed. No unfiltered Host suite, Swift suite or UI regression suite was run.

Evidence covers explicit suffix loading exactly once and no default discovery; strict config and reviewed/disabled filtering; canonical conflicts and restart-only entry changes; actual SDK tools/registered versus active tools/no UI; hidden approval initialization failure, denial, callback failure and cancellation; normal/error/canceled repeated cleanup; optional startup/runtime/cleanup errors with fixed diagnostics; bounded/corrupt/restarted/two-attempt storage; late updates; read-only queries; branch/deletion cleanup; queued-turn cleanup ordering; and protocol 1.0/2.0.0 WebSocket event/ACK/reconnect replay without new client capabilities.

SDK observations: conflicts can retain both initialized extension instances while returning per-entry errors; activeTools therefore use the actual SDK tool source. `dispose()` does not replace `session_shutdown`. `SessionManager.open` on a missing file can start a new session, so the construction-failure test injects a failure explicitly rather than assuming missing-file behavior.

Not covered: real provider/model behavior; actual installed third-party extensions; old/new iOS binaries, simulator/device UI, cross-version client decoding/ACK behavior on iOS; process-level forced kill while persisting; arbitrary nonterminating extension code; transitive dependency integrity; performance measurements. The legacy WebSocket tests are server-side client fixtures and do not prove compatibility of an actual old iOS binary. e2e-tester/code-reviewer should consume these fixtures and this limitation list; no further agent delegation was performed.
