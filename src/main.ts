import { createHash } from "node:crypto";
import { join } from "node:path";
import { readFile, writeFile } from "node:fs/promises";
import { ensureHostDirectories, loadHostConfig } from "./config.js";
import { DeterministicAgentDriver, PiAgentDriver } from "./agent/driver.js";
import { applyProviderSeed, loadProviderSeed } from "./providers/seed.js";
import { directTrustLine, invalidateDirectTrustFile, pairingTokenLine, readyLine, removeDirectTrustFile, removeStaleDirectTrustFile, writeDirectTrustFile, type DirectTrustOutput } from "./bootstrap-output.js";
import { DirectTlsError } from "./security/direct-tls.js";
import { HostService } from "./server/host-service.js";
import { SocketDeviceRegistry, startDirectWebSocketServer, startWebSocketServer, type RunningDirectServer } from "./server/ws.js";

async function currentBootstrapAttempt(home: string): Promise<string | null> {
  try {
    const state = JSON.parse(await readFile(join(home, ".bootstrap", "state.json"), "utf8")) as {
      attemptId?: unknown;
      status?: unknown;
    };
    return state.status === "running" && typeof state.attemptId === "string" && state.attemptId.length > 0
      ? state.attemptId
      : null;
  } catch {
    return null;
  }
}

const config = loadHostConfig(process.argv.slice(2));
await ensureHostDirectories(config);
const bootstrapAttemptId = await currentBootstrapAttempt(config.home);
if (bootstrapAttemptId) {
  await removeStaleDirectTrustFile(config.home, bootstrapAttemptId).catch(() => undefined);
  // A new process never inherits stdout trust from its previous run, even when
  // the attemptId is unchanged. Fresh metadata is rebuilt only after direct starts.
  await removeDirectTrustFile(config.home, bootstrapAttemptId).catch(() => undefined);
} else {
  await invalidateDirectTrustFile(config.home).catch(() => undefined);
}
// Record the running pid under the isolated run dir so a systemd unit or an
// operator can find this instance without touching any other host's state.
await writeFile(join(config.runDir, "host.pid"), `${process.pid}\n`, { mode: 0o600 }).catch(() => undefined);
const useDeterministic = process.env.PI_ADAPTOR_DETERMINISTIC === "1";
const driver = useDeterministic
  ? new DeterministicAgentDriver()
  : new PiAgentDriver(config.agentDir, [join(config.dataDir, "skills", "versions")]);
const service = new HostService(config, driver);
await service.init();
// Seed providers from a key file (test/bootstrap), if configured. Runs before
// the server accepts connections so a session can bind immediately. Errors are
// fatal: a misconfigured seed file must fail loudly, not silently skip.
if (config.providerSeedFile) {
  const entries = await loadProviderSeed(config.providerSeedFile);
  const seeded = await applyProviderSeed(service.providers, entries);
  process.stdout.write(`PI_HOST_PROVIDER_SEED ${JSON.stringify({ file: config.providerSeedFile, ...seeded })}\n`);
}
// Reclaim expired uploads and unreferenced blobs on startup and hourly.
service.startMaintenance();
const registry = new SocketDeviceRegistry(service);
const server = await startWebSocketServer(service, config.port, registry);
let directServer: RunningDirectServer | undefined;
if (config.direct.enabled) {
  try {
    directServer = await startDirectWebSocketServer(service, config.direct, registry);
  } catch (error) {
    if (bootstrapAttemptId) await removeDirectTrustFile(config.home, bootstrapAttemptId).catch(() => undefined);
    else await invalidateDirectTrustFile(config.home).catch(() => undefined);
    const reason = error instanceof DirectTlsError ? "certificate_invalid" : "listener_unavailable";
    process.stderr.write(`PI_HOST_DIRECT_ERROR ${JSON.stringify({ code: "DIRECT_UNAVAILABLE", reason })}\n`);
  }
}
if (directServer) {
  if (bootstrapAttemptId) {
    const trust: DirectTrustOutput = {
      schemaVersion: 1,
      attemptId: bootstrapAttemptId,
      hostId: service.hostId,
      ...directServer.trust
    };
    try {
      await writeDirectTrustFile(config.home, trust);
      process.stdout.write(directTrustLine(trust));
    } catch {
      await removeDirectTrustFile(config.home, bootstrapAttemptId).catch(() => undefined);
      process.stderr.write(`PI_HOST_DIRECT_ERROR ${JSON.stringify({ code: "DIRECT_UNAVAILABLE", reason: "trust_output_failed" })}\n`);
    }
  }
}
if (config.pair) {
  const pairing = await service.createPairingToken(600);
  process.stdout.write(pairingTokenLine({
    token: pairing.token,
    expiresAt: pairing.expiresAt,
    port: server.port
  }));
}
const fingerprint = createHash("sha256").update(`${service.hostId}:${server.port}`).digest("hex").slice(0, 16);
process.stdout.write(readyLine({
  version: config.hostVersion,
  hostId: service.hostId,
  port: server.port,
  fingerprint
}));

async function shutdown(): Promise<void> {
  service.stopMaintenance();
  if (bootstrapAttemptId) await removeDirectTrustFile(config.home, bootstrapAttemptId).catch(() => undefined);
  else await invalidateDirectTrustFile(config.home).catch(() => undefined);
  await Promise.all([server.close(), directServer?.close()]);
  process.exit(0);
}
process.once("SIGINT", () => void shutdown());
process.once("SIGTERM", () => void shutdown());
