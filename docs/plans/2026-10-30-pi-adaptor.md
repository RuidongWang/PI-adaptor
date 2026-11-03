# PI-adaptor Implementation Plan

> **For the implementing agent:** REQUIRED SUB-SKILL: use `executing-plans` when this plan is executed task-by-task.

**Goal:** Build a new Ubuntu aarch64 Host on top of Pi `1.3.0` and connect PI-IOS to it for projects, native sessions, streaming, approvals, providers, global Skills, images, and reconnect recovery.

**Architecture:** `` is a Node 22 + TypeScript service. It owns v2 authentication, durable event replay, provider/secret metadata, Skill installs and media blobs; Pi owns native v3 JSONL sessions and agent execution. The iOS client adds a v2 RACP adapter while retaining the existing SwiftUI design system and offline cache.

**Tech Stack:** Node 22, TypeScript, `ws`, Vitest, `@earendil-works/pi-coding-agent@1.3.0`, Swift 6, SwiftNIO SSH, XCTest, Xcode 27.

---

## Task 1: Freeze the v2 contract

**Files:**
- Create: `docs/api/pi-adaptor.md`
- Create: `docs/api/pi-adaptor.schema.json`
- Read: `docs/specs/pi-adaptor.md`
- Read: `docs/api/ios-client.md`
- Test: `test/contract.test.ts`

**Steps:**
1. Write the operation inventory, JSON-RPC envelopes, request/response schemas, event kinds, error codes and version rules.
2. Generate method-discriminated JSON Schema for every request/response and event payload.
3. Complete the Pi 1.3.0 spike for `SessionManager`, v3 append/branch, `resourceLoader.reload()` and lease behavior.
4. Obtain `advisor` review and resolve every BLOCK.
5. Mark the contract `FROZEN` with protocol version `2.0.0`.
6. Add contract tests that validate golden fixtures and every documented example against the schema.

**Verification:** `pnpm test -- contract`.

## Task 2: Scaffold the Host and local security boundary

**Files:**
- Create: `package.json`
- Create: `tsconfig.json`
- Create: `vitest.config.ts`
- Create: `src/main.ts`
- Create: `src/config.ts`
- Create: `src/security/secrets.ts`
- Create: `src/security/tokens.ts`
- Test: `test/config.test.ts`
- Test: `test/tokens.test.ts`

**Steps:**
- Parse `--data-dir`, `--port`, `--pair`, `--host-id` and environment overrides.
- Enforce owner-only data directories and 0600 token/secret files.
- Store device and pairing tokens as SHA-256 hashes; use constant-time comparison.
- Implement pairing-token expiry, one-time consumption and device revocation.
- Refuse non-loopback binds.

**Verification:** `pnpm test -- config tokens`.

## Task 3: Implement the native Pi session adapter

**Files:**
- Create: `src/pi/model-runtime.ts`
- Create: `src/pi/session-catalog.ts`
- Create: `src/pi/session-runtime.ts`
- Create: `src/pi/native-lease.ts`
- Test: `test/session-catalog.test.ts`
- Test: `test/session-runtime.test.ts`
- Test: `test/native-lease.test.ts`

**Steps:**
- Discover default and configured `sessionDir` JSONL files with real-path containment.
- Project v3 sessions into immutable summaries and histories.
- Open a persistent `SessionManager` only when a prompt is accepted.
- Implement cooperative lease acquisition and append prefix/fingerprint checks.
- Return corrupt, unreadable and unsupported sessions as read-only with reasons.
- Implement rename, archive metadata, branch and file deletion in non-running states.

**Verification:** `pnpm test -- session catalog lease`.

## Task 4: Implement the durable event journal and snapshots

**Files:**
- Create: `src/events/journal.ts`
- Create: `src/events/subscriptions.ts`
- Create: `src/sessions/snapshot.ts`
- Test: `test/events.test.ts`
- Test: `test/snapshot.test.ts`

**Steps:**
- Persist monotonic durable events per session and host scope.
- Implement subscribe, ack, cursor expiry, replay and snapshot fallback.
- Define item identity and delta/completion projection.
- Mark unfinished turns interrupted only after proving the old process group stopped; otherwise mark `uncertain`.
- Bound journal size and apply slow-client eviction.

**Verification:** `pnpm test -- events snapshot`.

## Task 5: Implement turns, permissions and approvals

**Files:**
- Create: `src/sessions/turns.ts`
- Create: `src/sessions/permissions.ts`
- Create: `src/sessions/approvals.ts`
- Create: `src/sessions/inputs.ts`
- Test: `test/turns.test.ts`
- Test: `test/permissions.test.ts`
- Test: `test/approvals.test.ts`

**Steps:**
- Map `ask`/`auto`, allow-once/allow-session/deny and Plan/Goal to Pi tool hooks.
- Implement idempotent turn start, queue, interrupt and cancel.
- Stream text, tool update/result and terminal events.
- Keep approvals across disconnects and invalidate after turn settlement.
- Implement AskTool input requests and revision checks.

**Verification:** `pnpm test -- turns permissions approvals`.

## Task 6: Implement provider and model management

**Files:**
- Create: `src/providers/store.ts`
- Create: `src/providers/service.ts`
- Create: `src/providers/discovery.ts`
- Test: `test/providers.test.ts`

**Steps:**
- Store provider metadata and secrets in owner-only atomic files with mode 0600; return only `hasApiKey` and masks.
- Register providers/models with `ModelRuntime`.
- Implement list/create/update/delete/test and optional model discovery.
- Fail closed on missing provider, disabled provider, removed model or missing secret.
- Never fall back silently when a bound provider is removed.

**Verification:** `pnpm test -- providers`.

## Task 7: Implement global Skill management

**Files:**
- Create: `src/skills/sources.ts`
- Create: `src/skills/installer.ts`
- Create: `src/skills/registry.ts`
- Test: `test/skills.test.ts`

**Steps:**
- Validate public Git URL, optional subdir and branch/tag/commit.
- Clone into a temporary directory, run bounded subprocesses and verify the resulting `SKILL.md`.
- Publish to an immutable version directory and atomically switch the global skill pointer.
- Implement update, explicit same-name replacement, delete and failure states.
- Load installed Skills through Pi's `DefaultResourceLoader` and call `reload()` before every new turn.

**Verification:** `pnpm test -- skills`.

## Task 8: Implement attachment storage and cleanup

**Files:**
- Create: `src/media/blob-store.ts`
- Create: `src/media/attachments.ts`
- Create: `src/media/references.ts`
- Test: `test/media.test.ts`

**Steps:**
- Validate MIME, 20 MiB boundary, 10-image count and SHA-256.
- Stream base64 chunks into a temp file, verify length/hash and atomically publish a blob.
- Use committed message/session references as the authoritative media graph; reference counts are only a rebuildable cache.
- Convert images to Pi `ImageContent` only for the active prompt.
- Delete unreferenced session blobs immediately and sweep orphan temp blobs after 24 hours.
- Implement bounded chunk reads for iOS display/save.

**Verification:** `pnpm test -- media`.

## Task 9: Implement the RACP v2 WebSocket server

**Files:**
- Create: `src/server/ws.ts`
- Create: `src/server/dispatch.ts`
- Create: `src/server/errors.ts`
- Create: `src/server/schema.ts`
- Test: `test/ws.test.ts`
- Test: `test/dispatch.test.ts`

**Steps:**
- Bind only `127.0.0.1`, require `pi-racp.v2.jsonrpc` and Bearer auth.
- Reject binary frames and malformed/oversized JSON before dispatch.
- Enforce method roles, schemas, idempotency and revision checks.
- Broadcast host/session events and journal durable events.
- Redact credentials from every log and error response.

**Verification:** `pnpm test -- ws dispatch`.

## Task 10: Add the iOS v2 adapter and feature gates

**Files:**
- Modify: `apps/ios/PIiOSKit/Sources/PIiOSCore/RACP/RACPWire.swift`
- Create: `apps/ios/PIiOSKit/Sources/PIiOSCore/RACP/RACPV2Wire.swift`
- Modify: `apps/ios/PIiOSKit/Sources/PIiOSNet/RACPWebSocket.swift`
- Modify: `apps/ios/PIiOSKit/Sources/PIiOSNet/RACPClient.swift`
- Create: `apps/ios/PIiOSKit/Sources/PIiOSNet/HostV2Client.swift`
- Test: `apps/ios/PIiOSKit/Tests/PIiOSCoreTests/HostV2WireTests.swift`
- Test: `apps/ios/PIiOSKit/Tests/PIiOSNetTests/HostV2ClientTests.swift`

**Steps:**
- Negotiate `pi-racp.v2.jsonrpc` while retaining v1 code paths for the old Host.
- Decode provider/Skill/attachment/session operations and event kinds.
- Preserve existing idempotency, cursor, snapshot rebuild and reconnect behavior.
- Disable unsupported controls based on server capabilities, not assumptions.
- Add protocol major version to Host records, Keychain accounts and SQLite composite keys; v1 Hosts remain offline-read-only and never share v2 tokens or cursors.

**Verification:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

## Task 11: Add iOS provider, Skill and image UI

**Files:**
- Modify: `apps/ios/PI-IOS/Screens/ModelsScreen.swift`
- Create: `apps/ios/PI-IOS/Screens/SkillsScreen.swift`
- Modify: `apps/ios/PI-IOS/Screens/SettingsScreen.swift`
- Modify: `apps/ios/PI-IOS/Screens/ConversationScreen.swift`
- Modify: `apps/ios/PI-IOS/Model/ConnectionModel.swift`
- Modify: `apps/ios/PI-IOS/Model/SessionController.swift`
- Test: `apps/ios/PIiOSKit/Tests/PIiOSCoreTests/HostV2FeaturePolicyTests.swift`

**Steps:**
- Move provider create/edit/delete from SSH CLI calls to v2 Host operations.
- Add Skill list/detail/install/update/delete and failure states.
- Add photo/file picker, 10-file limit, 20 MiB preflight and upload progress.
- Render image attachments with save/share and retry.
- Preserve loading, empty, error, success, disabled and selected states.

**Verification:** `xcodebuild test` on iPhone 18 Pro with isolated fixtures.

## Task 12: Build, E2E and release gates

**Files:**
- Create: `scripts/build-release.sh`
- Create: `scripts/install.sh`
- Create: `test/e2e/host.e2e.test.ts`
- Create: `docs/qa/pi-adaptor-evidence.md`
- Modify: `apps/ios/scripts/build-unsigned-ipa.sh`

**Steps:**
- Build a Linux arm64 bundle with pinned Node/native dependencies and checksums.
- Run E2E in an isolated temp home with a local mock OpenAI-compatible provider.
- Cover create/continue native session, stream/reconnect, approval, provider CRUD, Skill install/update/delete, image input/output/cleanup and restart recovery.
- Run code review, fix findings, rerun the final E2E.
- Run acceptance against every AC and produce the unsigned IPA.
- Record deployment, smoke and rollback commands.

**Verification:**

```sh
pnpm test
cd apps/ios/PIiOSKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/ios/PI-IOS.xcodeproj -scheme PI-IOS \
  -destination 'platform=iOS Simulator,id=CA7D66A3-7C3C-4874-9CDC-19750EECF546'
apps/ios/scripts/build-unsigned-ipa.sh
```

