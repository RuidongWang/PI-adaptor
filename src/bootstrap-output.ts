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
