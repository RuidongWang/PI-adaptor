import { createHash } from "node:crypto";
import { chmod, lstat, mkdir, realpath, rm } from "node:fs/promises";
import { createConnection, createServer, type Server } from "node:net";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

async function socketPath(dataDir: string): Promise<string> {
  const canonical = await realpath(dataDir);
  const candidate = join(canonical, ".pairing.sock");
  if (Buffer.byteLength(candidate) < 104) return candidate;
  const uid = process.getuid?.();
  const directory = join("/tmp", `pi-adaptor-${uid}`);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const info = await lstat(directory);
  if (!info.isDirectory() || info.uid !== uid || (info.mode & 0o077) !== 0) {
    throw new Error("Pairing socket directory must be private to the Host user");
  }
  const hash = createHash("sha256").update(canonical).digest("hex").slice(0, 32);
  return join(directory, `${hash}.sock`);
}

/** A filesystem lock shared by every Host using the same canonical data directory. */
export function claimHostInstance(dataDir: string): DatabaseSync | undefined {
  const lock = new DatabaseSync(join(dataDir, ".host-instance.sqlite"));
  try {
    lock.exec("BEGIN EXCLUSIVE");
    return lock;
  } catch (error) {
    lock.close();
    if ((error as { errcode?: unknown }).errcode === 5) return undefined; // SQLITE_BUSY
    throw error;
  }
}

export async function startPairingAdmin(dataDir: string, issue: () => Promise<string>): Promise<Server> {
  const path = await socketPath(dataDir);
  await rm(path, { force: true });
  const server = createServer((socket) => {
    socket.on("error", () => undefined);
    socket.setTimeout(5_000, () => socket.destroy());
    void issue().then((line) => socket.end(line), () => socket.destroy());
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    // Set ownership permissions at bind time, before any client can connect.
    const mask = process.umask(0o177);
    try { server.listen(path, resolve); } finally { process.umask(mask); }
  });
  await chmod(path, 0o600);
  return server;
}

export async function requestPairingFromHost(dataDir: string): Promise<string> {
  const path = await socketPath(dataDir);
  const info = await lstat(path);
  if (!info.isSocket() || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0) {
    throw new Error("Pairing socket must be private to the Host user");
  }
  return new Promise((resolve, reject) => {
    const socket = createConnection(path);
    socket.setEncoding("utf8");
    socket.setTimeout(5_000, () => socket.destroy(new Error("Pairing request timed out")));
    let reply = "";
    socket.on("data", (part: string) => {
      reply += part;
      if (reply.length > 4096) socket.destroy(new Error("Invalid pairing reply"));
    });
    socket.once("error", reject);
    socket.once("end", () => {
      if (reply.startsWith("PI_HOST_PAIRING_TOKEN ") && reply.endsWith("\n")) resolve(reply);
      else reject(new Error("Pairing token unavailable from the running Host"));
      socket.destroy();
    });
  });
}
