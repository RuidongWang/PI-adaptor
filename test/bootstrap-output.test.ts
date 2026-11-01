import { spawn } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { BOOTSTRAP_HOST, pairingTokenLine, readyLine } from "../src/bootstrap-output.js";

function readLines(stream: NodeJS.ReadableStream): {
  lines: string[];
  waitFor: (predicate: () => boolean) => Promise<void>;
} {
  const lines: string[] = [];
  let pending = "";
  stream.setEncoding("utf8");
  stream.on("data", (chunk: string) => {
    pending += chunk;
    while (pending.includes("\n")) {
      const index = pending.indexOf("\n");
      lines.push(pending.slice(0, index));
      pending = pending.slice(index + 1);
    }
  });
  return {
    lines,
    async waitFor(predicate: () => boolean) {
      const deadline = Date.now() + 8_000;
      while (!predicate()) {
        if (Date.now() >= deadline) throw new Error(`timed out waiting for bootstrap output: ${lines.join("\n")}`);
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
    }
  };
}

describe("bootstrap stdout", () => {
  it("formats pairing and ready records as the bootstrap JSON contract", () => {
    const token = "ppt2." + "test-token";
    const pairing = JSON.parse(
      pairingTokenLine({
        token,
        expiresAt: "2030-01-01T00:00:00.000Z",
        port: 43871
      }).trim().slice("PI_HOST_PAIRING_TOKEN ".length)
    );
    expect(pairing).toEqual({
      token,
      expiresAt: 1_893_456_000_000,
      host: BOOTSTRAP_HOST,
      port: 43871
    });

    const ready = JSON.parse(
      readyLine({
        version: "2.0.1",
        hostId: "host-id",
        port: 43871,
        fingerprint: "abc123"
      }).trim().slice("PI_HOST_READY ".length)
    );
    expect(ready).toEqual({
      version: "2.0.1",
      hostId: "host-id",
      host: BOOTSTRAP_HOST,
      port: 43871,
      fingerprint: "abc123"
    });
  });

  it("emits pairing and ready records from the real host process", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-output-"));
    const child = spawn(
      process.execPath,
      [
        "--import", "tsx",
        "src/main.ts",
        "--home", root,
        "--port", "0",
        "--pair"
      ],
      {
        cwd: join(import.meta.dirname, ".."),
        env: { ...process.env, PI_ADAPTOR_DETERMINISTIC: "1" },
        stdio: ["ignore", "pipe", "pipe"]
      }
    );
    const output = readLines(child.stdout!);
    let stderr = "";
    child.stderr!.setEncoding("utf8");
    child.stderr!.on("data", (chunk: string) => {
      stderr += chunk;
    });

    try {
      await output.waitFor(() =>
        output.lines.some((line) => line.startsWith("PI_HOST_PAIRING_TOKEN ")) &&
        output.lines.some((line) => line.startsWith("PI_HOST_READY "))
      );
      const pairing = JSON.parse(
        output.lines.find((line) => line.startsWith("PI_HOST_PAIRING_TOKEN "))!
          .slice("PI_HOST_PAIRING_TOKEN ".length)
      );
      const ready = JSON.parse(
        output.lines.find((line) => line.startsWith("PI_HOST_READY "))!
          .slice("PI_HOST_READY ".length)
      );
      expect(pairing.token).toMatch(/^ppt2\./);
      expect(pairing.host).toBe(BOOTSTRAP_HOST);
      expect(pairing.port).toBe(ready.port);
      expect(pairing.expiresAt).toBeGreaterThan(Date.now());
      expect(Number.isSafeInteger(pairing.expiresAt)).toBe(true);
      expect(ready).toMatchObject({
        version: "2.0.1",
        host: BOOTSTRAP_HOST,
        port: pairing.port
      });
    } catch (error) {
      throw new Error(`${String(error)}\nhost stderr:\n${stderr}`);
    } finally {
      child.kill("SIGTERM");
      await new Promise<void>((resolve) => {
        child.once("exit", () => resolve());
        setTimeout(resolve, 2_000);
      });
    }
  });
});
