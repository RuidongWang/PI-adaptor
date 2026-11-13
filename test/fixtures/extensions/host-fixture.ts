import { mkdtemp, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentDriver, AgentTurnRequest } from "../../../src/agent/driver.js";
import { DeterministicAgentDriver } from "../../../src/agent/driver.js";
import { ensureHostDirectories, parseHostConfig } from "../../../src/config.js";
import { HostService } from "../../../src/server/host-service.js";
import type { ExtensionSnapshot } from "../../../src/extensions/types.js";

export async function hostFixture(driver: AgentDriver = new DeterministicAgentDriver(), extensions?: unknown) {
  const root = await mkdtemp(join(tmpdir(), "pi-extensions-host-test-")), project = join(root, "project"); await mkdir(project);
  const config = parseHostConfig(["--home", root], {}, root, { extensions }); await ensureHostDirectories(config);
  const service = new HostService(config, driver); await service.init();
  const pairing = await service.createPairingToken(), paired = await service.pair({ deviceLabel: "extensions-test" }, pairing.token);
  const auth = { device: { deviceId: paired.deviceId, label: "test", role: "owner" as const, tokenHash: "test", createdAt: new Date().toISOString(), lastUsedAt: new Date().toISOString(), revokedAt: null } };
  const record = await service.meta.registerProject(project, "fixture");
  const created = await service.handle("session/create", { projectId: record.id }, auth) as { session: { id: string; revision: number } };
  return { root, config, service, auth, sessionId: created.session.id, projectId: record.id, token: paired.deviceToken };
}
export function snapshotFor(request: AgentTurnRequest, phase: ExtensionSnapshot["phase"] = "loading", revision = 1): ExtensionSnapshot {
  return { id: request.turnId, hostId: request.extensions!.hostId, sessionId: request.sessionId, turnId: request.turnId, configRevision: request.extensions!.registry.configRevision, revision, startedAt: new Date().toISOString(), completedAt: phase === "loading" ? null : new Date().toISOString(), phase, entries: [], diagnostics: [] };
}
export class SnapshotDriver implements AgentDriver {
  readonly appendsPrompt = false;
  requests: AgentTurnRequest[] = [];
  release: Array<() => void> = [];
  constructor(private readonly holdCleanup = false) {}
  start(request: AgentTurnRequest) {
    this.requests.push(request);
    let finish!: () => void;
    const cleanup = this.holdCleanup ? new Promise<void>(resolve => { finish = resolve; this.release.push(resolve); }) : Promise.resolve();
    const wait = (async () => {
      await request.extensions!.publish(snapshotFor(request));
      request.onEvent({ kind: "turn.started", payload: { turnId: request.turnId } });
      await request.extensions!.publish(snapshotFor(request, "ready", 2));
      request.onEvent({ kind: "turn.completed", payload: { turnId: request.turnId } });
      await cleanup;
    })();
    return { turnId: request.turnId, async abort() { finish?.(); await wait; }, wait: () => wait };
  }
}
