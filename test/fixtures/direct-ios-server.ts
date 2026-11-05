import { execFile } from "node:child_process";
import { chmod, mkdir, mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { DeterministicAgentDriver } from "../../src/agent/driver.js";
import { ensureHostDirectories, parseHostConfig } from "../../src/config.js";
import { HostService } from "../../src/server/host-service.js";
import {
  SocketDeviceRegistry,
  startDirectWebSocketServer,
  startWebSocketServer,
  type RunningDirectServer,
  type RunningHostServer
} from "../../src/server/ws.js";

const execFileAsync = promisify(execFile);

async function reserveLoopbackPort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("fixture could not reserve a direct port");
  const port = address.port;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

async function run(): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), "pi-ios-real-direct-wss-"));
  let loopback: RunningHostServer | undefined;
  let direct: RunningDirectServer | undefined;
  let cleanupPromise: Promise<void> | undefined;

  const cleanup = (): Promise<void> => {
    cleanupPromise ??= (async () => {
      const results = await Promise.allSettled([direct?.close(), loopback?.close()]);
      await rm(root, { recursive: true, force: true });
      const failure = results.find((result) => result.status === "rejected");
      if (failure) throw failure.reason;
    })();
    return cleanupPromise;
  };

  try {
    const tlsDirectory = join(root, "tls");
    await mkdir(tlsDirectory, { mode: 0o700 });
    await chmod(tlsDirectory, 0o700);
    const certificateFile = join(tlsDirectory, "direct-cert.pem");
    const privateKeyFile = join(tlsDirectory, "direct-key.pem");
    await execFileAsync("openssl", [
      "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "2", "-nodes",
      "-keyout", privateKeyFile,
      "-out", certificateFile,
      "-subj", "/CN=pi-ios-real-direct-wss",
      "-addext", "basicConstraints=critical,CA:FALSE",
      "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
      "-addext", "extendedKeyUsage=serverAuth",
      "-addext", "subjectAltName=IP:127.0.0.1"
    ]);
    await chmod(privateKeyFile, 0o600);

    const config = parseHostConfig([
      "--home", root,
      "--data-dir", join(root, "data"),
      "--agent-dir", join(root, "agent"),
      "--port", "0",
      "--direct",
      "--direct-host", "127.0.0.1",
      "--direct-port", String(await reserveLoopbackPort()),
      "--direct-cert", certificateFile,
      "--direct-key", privateKeyFile
    ], {}, root);
    await ensureHostDirectories(config);

    const service = new HostService(config, new DeterministicAgentDriver());
    await service.init();
    const pairing = await service.createPairingToken();
    const device = await service.tokens.pair(pairing.token, "real-ios-direct-wss");
    if (!device.deviceToken.startsWith("pdt2.")) throw new Error("fixture did not issue a pdt2 device token");

    const registry = new SocketDeviceRegistry(service);
    loopback = await startWebSocketServer(service, 0, registry);
    direct = await startDirectWebSocketServer(service, config.direct, registry);

    const shutdown = () => {
      void cleanup().catch((error: unknown) => {
        console.error("direct iOS fixture cleanup failed", error);
        process.exitCode = 1;
      });
    };
    process.once("SIGTERM", shutdown);
    process.once("SIGINT", shutdown);

    process.stdout.write(`${JSON.stringify({
      hostId: service.hostId,
      directPort: direct.port,
      certificateSha256: direct.trust.certificateSha256,
      deviceToken: device.deviceToken
    })}\n`);
  } catch (error) {
    await cleanup();
    throw error;
  }
}

try {
  await run();
} catch (error) {
  console.error("direct iOS fixture failed", error);
  process.exitCode = 1;
}
