import { timingSafeEqual } from "node:crypto";
import { join } from "node:path";
import { HostError } from "../errors.js";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";
import { opaqueToken, sha256, uuid } from "../util/id.js";

export type DeviceRecord = {
  deviceId: string;
  label: string;
  role: "owner";
  tokenHash: string;
  createdAt: string;
  lastUsedAt: string;
  revokedAt: string | null;
  previousTokenHash?: string;
  previousValidUntil?: string;
  /**
   * Set between `connection/rotate-token` and `connection/confirm-rotation`.
   * Persisted so a restart before confirmation can void the rotation and keep
   * the old token valid (contract §2.4).
   */
  pendingRotation?: {
    rotationId: string;
    newTokenHash: string;
    previousTokenHash: string;
    previousValidUntil: string;
    createdAt: string;
  };
};

type PairingRecord = {
  tokenHash: string;
  expiresAt: string;
  consumedAt: string | null;
};

type TokenFile = {
  version: 1;
  devices: DeviceRecord[];
  pairing: PairingRecord[];
};

function digestEquals(left: string, right: string): boolean {
  const a = Buffer.from(left, "hex");
  const b = Buffer.from(right, "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

export class TokenStore {
  private readonly path: string;
  private pending: Promise<void> = Promise.resolve();
  private readonly pendingRotations = new Map<
    string,
    {
      rotationId: string;
      deviceId: string;
      deviceToken: string;
      previousTokenValidUntil: string;
      idempotencyKey?: string;
      expiresAt: number;
    }
  >();

  private serialized<T>(work: () => Promise<T>): Promise<T> {
    const result = this.pending.then(work);
    this.pending = result.then(() => undefined, () => undefined);
    return result;
  }

  constructor(dataDir: string) {
    this.path = join(dataDir, "meta", "tokens.json");
  }

  private async load(): Promise<TokenFile> {
    const data = await readJsonFile<TokenFile>(this.path, { version: 1, devices: [], pairing: [] });
    if (data.version !== 1) throw new HostError("INTERNAL", "unsupported token store version");
    return data;
  }

  private async save(data: TokenFile): Promise<void> {
    await writeJsonFileAtomic(this.path, data, 0o600);
  }

  async createPairingToken(ttlSeconds = 600, now = new Date()): Promise<{ token: string; expiresAt: string }> {
    return this.serialized(async () => {
      const data = await this.load();
      const token = opaqueToken("ppt2");
      const expiresAt = new Date(now.getTime() + ttlSeconds * 1000).toISOString();
      data.pairing = data.pairing.filter((entry) => !entry.consumedAt && Date.parse(entry.expiresAt) > now.getTime());
      data.pairing.push({ tokenHash: sha256(token), expiresAt, consumedAt: null });
      await this.save(data);
      return { token, expiresAt };
    });
  }

  async pair(token: string, label: string, now = new Date()): Promise<{ deviceId: string; deviceToken: string }> {
    return this.serialized(async () => {
      const data = await this.load();
      const hash = sha256(token);
      const record = data.pairing.find((entry) => !entry.consumedAt && digestEquals(entry.tokenHash, hash));
      if (!record) throw new HostError("PAIRING_FAILED", "pairing token is invalid or already used");
      if (Date.parse(record.expiresAt) <= now.getTime()) {
        throw new HostError("PAIRING_TOKEN_EXPIRED", "pairing token expired");
      }
      record.consumedAt = now.toISOString();
      const deviceToken = opaqueToken("pdt2");
      const device: DeviceRecord = {
        deviceId: uuid(),
        label: label.slice(0, 200),
        role: "owner",
        tokenHash: sha256(deviceToken),
        createdAt: now.toISOString(),
        lastUsedAt: now.toISOString(),
        revokedAt: null
      };
      data.devices.push(device);
      await this.save(data);
      return { deviceId: device.deviceId, deviceToken };
    });
  }

  async authenticate(token: string, now = new Date()): Promise<DeviceRecord> {
    return this.serialized(async () => {
      const data = await this.load();
      const hash = sha256(token);
      const device = data.devices.find(
        (entry) =>
          !entry.revokedAt &&
          (digestEquals(entry.tokenHash, hash) ||
            (entry.previousTokenHash !== undefined &&
              entry.previousValidUntil !== undefined &&
              Date.parse(entry.previousValidUntil) > now.getTime() &&
              digestEquals(entry.previousTokenHash, hash)))
      );
      if (!device) throw new HostError("UNAUTHORIZED", "device token is invalid or revoked");
      device.lastUsedAt = now.toISOString();
      await this.save(data);
      return device;
    });
  }

  async revoke(deviceId: string, now = new Date()): Promise<boolean> {
    return this.serialized(async () => {
      const data = await this.load();
      const device = data.devices.find((entry) => entry.deviceId === deviceId);
      if (!device) throw new HostError("DEVICE_NOT_FOUND", "device not found");
      if (device.revokedAt) return false;
      device.revokedAt = now.toISOString();
      this.pendingRotations.delete(deviceId);
      await this.save(data);
      return true;
    });
  }

  async listDevices(): Promise<Array<Omit<DeviceRecord, "tokenHash" | "previousTokenHash" | "pendingRotation">>> {
    return this.serialized(async () => {
      return (await this.load()).devices.map(
        ({ tokenHash: _tokenHash, previousTokenHash: _previousTokenHash, pendingRotation: _pendingRotation, ...device }) =>
          device
      );
    });
  }

  async rotate(
    deviceId: string,
    idempotencyKeyOrNow?: string | Date,
    maybeNow = new Date()
  ): Promise<{
    rotationId: string;
    deviceId: string;
    deviceToken: string;
    previousTokenValidUntil: string;
  }> {
    const idempotencyKey = typeof idempotencyKeyOrNow === "string" ? idempotencyKeyOrNow : undefined;
    const now = idempotencyKeyOrNow instanceof Date ? idempotencyKeyOrNow : maybeNow;
    return this.serialized(async () => {
      const data = await this.load();
      const device = data.devices.find((entry) => entry.deviceId === deviceId && !entry.revokedAt);
      if (!device) throw new HostError("DEVICE_NOT_FOUND", "device not found");

      const cached = this.pendingRotations.get(deviceId);
      if (cached && cached.expiresAt > now.getTime()) {
        if (idempotencyKey && cached.idempotencyKey === idempotencyKey) {
          return {
            rotationId: cached.rotationId,
            deviceId: cached.deviceId,
            deviceToken: cached.deviceToken,
            previousTokenValidUntil: cached.previousTokenValidUntil
          };
        }
        if (idempotencyKey && cached.idempotencyKey && cached.idempotencyKey !== idempotencyKey) {
          throw new HostError("IDEMPOTENCY_CONFLICT", "idempotency key reused with different request");
        }
      }

      const deviceToken = opaqueToken("pdt2");
      const previousTokenValidUntil = new Date(now.getTime() + 5 * 60 * 1000).toISOString();
      const previousTokenHash = device.tokenHash;
      const rotationId = uuid();
      device.previousTokenHash = previousTokenHash;
      device.previousValidUntil = previousTokenValidUntil;
      device.tokenHash = sha256(deviceToken);
      device.pendingRotation = {
        rotationId,
        newTokenHash: device.tokenHash,
        previousTokenHash,
        previousValidUntil: previousTokenValidUntil,
        createdAt: now.toISOString()
      };
      await this.save(data);

      this.pendingRotations.set(deviceId, {
        rotationId,
        deviceId: device.deviceId,
        deviceToken,
        previousTokenValidUntil,
        ...(idempotencyKey ? { idempotencyKey } : {}),
        expiresAt: now.getTime() + 5 * 60 * 1000
      });

      return { rotationId, deviceId: device.deviceId, deviceToken, previousTokenValidUntil };
    });
  }

  /**
   * Confirm a rotation by its `rotationId`, dropping the lingering old-token
   * window. Requires the id returned by `rotate`, so a late or duplicated
   * confirmation cannot clear a newer rotation.
   */
  async confirmRotation(deviceId: string, rotationId: string): Promise<boolean> {
    return this.serialized(async () => {
      const data = await this.load();
      const device = data.devices.find((entry) => entry.deviceId === deviceId && !entry.revokedAt);
      if (!device) throw new HostError("DEVICE_NOT_FOUND", "device not found");
      if (!device.pendingRotation || device.pendingRotation.rotationId !== rotationId) {
        throw new HostError("INVALID_ARGUMENT", "rotationId does not match a pending rotation");
      }
      delete device.pendingRotation;
      delete device.previousTokenHash;
      delete device.previousValidUntil;
      this.pendingRotations.delete(deviceId);
      await this.save(data);
      return true;
    });
  }

  /**
   * Void every rotation that was issued but never confirmed before a restart,
   * restoring the pre-rotation token as the active one (contract §2.4). Call
   * once at startup.
   */
  async recoverUnconfirmedRotations(): Promise<void> {
    return this.serialized(async () => {
      const data = await this.load();
      let changed = false;
      this.pendingRotations.clear();
      for (const device of data.devices) {
        if (!device.pendingRotation) continue;
        device.tokenHash = device.pendingRotation.previousTokenHash;
        delete device.previousTokenHash;
        delete device.previousValidUntil;
        delete device.pendingRotation;
        changed = true;
      }
      if (changed) await this.save(data);
    });
  }
}
