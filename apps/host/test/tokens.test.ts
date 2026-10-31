import { mkdtemp, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { HostError } from "../src/errors.js";
import { TokenStore } from "../src/security/tokens.js";

describe("token store", () => {
  it("serializes simultaneous pair and revoke operations", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-tokens-race-"));
    const store = new TokenStore(root);
    const pairing = await store.createPairingToken();
    const attempts = await Promise.allSettled([store.pair(pairing.token, "a"), store.pair(pairing.token, "b")]);
    expect(attempts.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const paired = attempts.find((result) => result.status === "fulfilled") as PromiseFulfilledResult<{ deviceId: string; deviceToken: string }>;
    await Promise.allSettled([store.authenticate(paired.value.deviceToken), store.revoke(paired.value.deviceId)]);
    await expect(store.authenticate(paired.value.deviceToken)).rejects.toMatchObject({ code: "UNAUTHORIZED" });
  });

  it("does not share empty state across separate stores", async () => {
    const first = new TokenStore(await mkdtemp(join(tmpdir(), "pi-adaptor-first-")));
    const second = new TokenStore(await mkdtemp(join(tmpdir(), "pi-adaptor-second-")));
    await first.createPairingToken();
    expect(await second.listDevices()).toEqual([]);
  });
  it("pairs once, authenticates, and stores only hashes", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-tokens-"));
    const store = new TokenStore(root);
    const pairing = await store.createPairingToken(600, new Date("2026-01-01T00:00:00Z"));
    expect(pairing.token).toMatch(/^ppt2\./);
    const paired = await store.pair(pairing.token, "iPhone", new Date("2026-01-01T00:01:00Z"));
    expect(paired.deviceToken).toMatch(/^pdt2\./);
    const device = await store.authenticate(paired.deviceToken, new Date("2026-01-01T00:02:00Z"));
    expect(device.deviceId).toBe(paired.deviceId);
    expect((await stat(join(root, "meta", "tokens.json"))).mode & 0o777).toBe(0o600);
    await expect(store.pair(pairing.token, "replay", new Date("2026-01-01T00:03:00Z"))).rejects.toMatchObject({
      code: "PAIRING_FAILED"
    });
  });

  it("rejects expired pairing tokens and revoked devices", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-tokens-"));
    const store = new TokenStore(root);
    const pairing = await store.createPairingToken(60, new Date("2026-01-01T00:00:00Z"));
    await expect(
      store.pair(pairing.token, "late", new Date("2026-01-01T00:02:00Z"))
    ).rejects.toBeInstanceOf(HostError);

    const fresh = await store.createPairingToken(60, new Date("2026-01-01T00:00:00Z"));
    const paired = await store.pair(fresh.token, "iPhone", new Date("2026-01-01T00:00:30Z"));
    expect(await store.revoke(paired.deviceId, new Date("2026-01-01T00:01:00Z"))).toBe(true);
    await expect(
      store.authenticate(paired.deviceToken, new Date("2026-01-01T00:02:00Z"))
    ).rejects.toMatchObject({ code: "UNAUTHORIZED" });
  });

  it("rotates with a five-minute overlap and confirms the new token", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-tokens-"));
    const store = new TokenStore(root);
    const pairing = await store.createPairingToken(60, new Date("2026-01-01T00:00:00Z"));
    const paired = await store.pair(pairing.token, "iPhone", new Date("2026-01-01T00:00:10Z"));
    const rotated = await store.rotate(paired.deviceId, new Date("2026-01-01T00:01:00Z"));
    await expect(
      store.authenticate(paired.deviceToken, new Date("2026-01-01T00:02:00Z"))
    ).resolves.toMatchObject({ deviceId: paired.deviceId });
    await expect(
      store.authenticate(rotated.deviceToken, new Date("2026-01-01T00:02:00Z"))
    ).resolves.toMatchObject({ deviceId: paired.deviceId });
    expect(await store.confirmRotation(paired.deviceId, rotated.rotationId)).toBe(true);
    await expect(
      store.authenticate(paired.deviceToken, new Date("2026-01-01T00:03:00Z"))
    ).rejects.toMatchObject({ code: "UNAUTHORIZED" });
  });

  it("rejects a confirmation whose rotationId does not match", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-tokens-"));
    const store = new TokenStore(root);
    const pairing = await store.createPairingToken(60, new Date("2026-01-01T00:00:00Z"));
    const paired = await store.pair(pairing.token, "iPhone", new Date("2026-01-01T00:00:10Z"));
    await store.rotate(paired.deviceId, new Date("2026-01-01T00:01:00Z"));
    await expect(
      store.confirmRotation(paired.deviceId, "not-the-rotation-id")
    ).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  });

  it("voids an unconfirmed rotation after restart, keeping the old token valid", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-tokens-"));
    const store = new TokenStore(root);
    const pairing = await store.createPairingToken(60, new Date("2026-01-01T00:00:00Z"));
    const paired = await store.pair(pairing.token, "iPhone", new Date("2026-01-01T00:00:10Z"));
    const rotated = await store.rotate(paired.deviceId, new Date("2026-01-01T00:01:00Z"));

    // Simulate a restart: a fresh store over the same data recovers the pending
    // rotation and restores the pre-rotation token as the active one.
    const restarted = new TokenStore(root);
    await restarted.recoverUnconfirmedRotations();
    await expect(
      restarted.authenticate(paired.deviceToken, new Date("2026-01-01T00:20:00Z"))
    ).resolves.toMatchObject({ deviceId: paired.deviceId });
    await expect(
      restarted.authenticate(rotated.deviceToken, new Date("2026-01-01T00:20:00Z"))
    ).rejects.toMatchObject({ code: "UNAUTHORIZED" });
  });
});
