import { chmod, mkdir, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { writeJsonFileAtomic } from "./util/json-file.js";

export const BOOTSTRAP_HOST = "127.0.0.1";

export type PairingTokenOutput = {
  token: string;
  expiresAt: string;
  port: number;
};

export type ReadyOutput = {
  version: string;
  hostId: string;
  port: number;
  fingerprint: string;
};

export type DirectTrustOutput = {
  schemaVersion: 1;
  attemptId: string;
  hostId: string;
  certificateSha256: string;
  notBefore: string;
  notAfter: string;
};

function assertPort(port: number): void {
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error(`invalid bootstrap output port: ${String(port)}`);
  }
}

export function pairingTokenLine(input: PairingTokenOutput): string {
  assertPort(input.port);
  const expiresAt = Date.parse(input.expiresAt);
  if (!Number.isSafeInteger(expiresAt) || expiresAt <= 0) {
    throw new Error(`invalid pairing token expiry: ${input.expiresAt}`);
  }
  return `PI_HOST_PAIRING_TOKEN ${JSON.stringify({
    token: input.token,
    expiresAt,
    host: BOOTSTRAP_HOST,
    port: input.port
  })}\n`;
}

export function readyLine(input: ReadyOutput): string {
  assertPort(input.port);
  return `PI_HOST_READY ${JSON.stringify({
    version: input.version,
    hostId: input.hostId,
    host: BOOTSTRAP_HOST,
    port: input.port,
    fingerprint: input.fingerprint
  })}\n`;
}

function directTrustPayload(input: DirectTrustOutput): DirectTrustOutput {
  if (input.schemaVersion !== 1) throw new Error("invalid direct trust schemaVersion");
  if (!input.attemptId || !input.hostId) throw new Error("direct trust attemptId and hostId are required");
  if (!/^[0-9a-f]{64}$/.test(input.certificateSha256)) {
    throw new Error("invalid direct trust certificateSha256");
  }
  const notBefore = Date.parse(input.notBefore);
  const notAfter = Date.parse(input.notAfter);
  if (!Number.isFinite(notBefore) || !Number.isFinite(notAfter) || notAfter <= notBefore) {
    throw new Error("invalid direct trust validity interval");
  }
  return {
    schemaVersion: 1,
    attemptId: input.attemptId,
    hostId: input.hostId,
    certificateSha256: input.certificateSha256,
    notBefore: input.notBefore,
    notAfter: input.notAfter
  };
}

export function directTrustLine(input: DirectTrustOutput): string {
  return `PI_HOST_DIRECT_TRUST ${JSON.stringify(directTrustPayload(input))}\n`;
}

export async function writeDirectTrustFile(home: string, input: DirectTrustOutput): Promise<void> {
  const payload = directTrustPayload(input);
  const directory = join(home, ".bootstrap");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(directory, 0o700);
  await writeJsonFileAtomic(join(directory, "direct-trust.json"), payload, 0o600);
}

function directTrustPath(home: string): string {
  return join(home, ".bootstrap", "direct-trust.json");
}

async function trustAttemptId(path: string): Promise<string | null> {
  try {
    const value = JSON.parse(await readFile(path, "utf8")) as { attemptId?: unknown };
    return typeof value.attemptId === "string" ? value.attemptId : null;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    return null;
  }
}

/** Best-effort attempt termination cleanup; never removes a different attempt's trust. */
export async function removeDirectTrustFile(home: string, attemptId: string): Promise<void> {
  const path = directTrustPath(home);
  if ((await trustAttemptId(path)) !== attemptId) return;
  await rm(path, { force: true });
}

/** Fail closed when no current bootstrap attempt can authorize any direct trust. */
export async function invalidateDirectTrustFile(home: string): Promise<void> {
  await rm(directTrustPath(home), { force: true });
}

/** Invalidate a previous attempt at startup while preserving the current attempt's fresh output. */
export async function removeStaleDirectTrustFile(home: string, currentAttemptId: string): Promise<void> {
  const path = directTrustPath(home);
  const storedAttempt = await trustAttemptId(path);
  if (storedAttempt === currentAttemptId) return;
  await rm(path, { force: true });
}
