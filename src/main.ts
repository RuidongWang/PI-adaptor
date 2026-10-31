import { createHash } from "node:crypto";
import { join } from "node:path";
import { writeFile } from "node:fs/promises";
import { ensureHostDirectories, loadHostConfig } from "./config.js";
import { DeterministicAgentDriver, PiAgentDriver } from "./agent/driver.js";
import { applyProviderSeed, loadProviderSeed } from "./providers/seed.js";
import { HostService } from "./server/host-service.js";
import { startWebSocketServer } from "./server/ws.js";

const config = loadHostConfig(process.argv.slice(2));
await ensureHostDirectories(config);
// Record the running pid under the isolated run dir so a systemd unit or an
// operator can find this instance without touching any other host's state.
await writeFile(join(config.runDir, "host.pid"), `${process.pid}\n`, { mode: 0o600 }).catch(() => undefined);
const useDeterministic = process.env.PI_HOST_V2_DETERMINISTIC === "1";
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
if (config.pair) {
  const pairing = await service.createPairingToken(600);
  process.stdout.write(`PI_HOST_PAIRING_TOKEN ${pairing.token}\n`);
}
const server = await startWebSocketServer(service, config.port);
const fingerprint = createHash("sha256").update(`${service.hostId}:${server.port}`).digest("hex").slice(0, 16);
process.stdout.write(
  `PI_HOST_READY ${JSON.stringify({
    version: config.hostVersion,
    hostId: service.hostId,
    port: server.port,
    fingerprint
  })}\n`
);

async function shutdown(): Promise<void> {
  service.stopMaintenance();
  await server.close();
  process.exit(0);
}
process.once("SIGINT", () => void shutdown());
process.once("SIGTERM", () => void shutdown());
