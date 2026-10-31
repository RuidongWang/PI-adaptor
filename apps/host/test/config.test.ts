import { mkdtemp, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_HOST_V2_HOME,
  ensureHostDirectories,
  loadHostConfig,
  parseHostConfig,
  readHostConfigFile
} from "../src/config.js";

describe("host config", () => {
  it("parses explicit paths and port", () => {
    const config = parseHostConfig(
      ["--data-dir", "/tmp/data", "--agent-dir", "/tmp/agent", "--port", "44271", "--pair"],
      {},
      "/home/tester"
    );
    expect(config.dataDir).toBe("/tmp/data");
    expect(config.agentDir).toBe("/tmp/agent");
    expect(config.port).toBe(44271);
    expect(config.pair).toBe(true);
  });

  it("creates owner-only directories", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-host-config-"));
    const config = parseHostConfig(["--data-dir", root, "--agent-dir", join(root, "agent")], {}, root);
    await ensureHostDirectories(config);
    expect((await stat(root)).mode & 0o777).toBe(0o700);
    expect((await stat(join(root, "meta"))).mode & 0o777).toBe(0o700);
  });

  it("isolates every default path under the v2 home and never touches the legacy host", () => {
    const home = "/home/tester";
    const config = parseHostConfig([], {}, home);
    const v2Home = join(home, DEFAULT_HOST_V2_HOME);
    expect(config.home).toBe(v2Home);
    expect(config.dataDir).toBe(join(v2Home, "data"));
    expect(config.agentDir).toBe(join(v2Home, "agent"));
    expect(config.sessionRoots).toEqual([join(v2Home, "data", "sessions")]);
    expect(config.logsDir).toBe(join(v2Home, "logs"));
    expect(config.runDir).toBe(join(v2Home, "run"));
    // The isolation guarantee: no default may point at the legacy PI-Desktop
    // host or the shared pi global dir.
    for (const value of [config.home, config.dataDir, config.agentDir, ...config.sessionRoots]) {
      expect(value).not.toContain(".pi-desktop");
      expect(value).not.toContain(join(".pi", "agent"));
    }
  });

  it("reads <home>/config.json as a default layer overridden by env then CLI", async () => {
    const home = await mkdtemp(join(tmpdir(), "pi-host-home-"));
    const { mkdir } = await import("node:fs/promises");
    await mkdir(join(home, DEFAULT_HOST_V2_HOME), { recursive: true });
    await writeFile(
      join(home, DEFAULT_HOST_V2_HOME, "config.json"),
      JSON.stringify({ agentDir: join(home, "from-file-agent"), port: 44001, hostId: "file-id" }),
      "utf8"
    );

    // File only.
    const fromFile = loadHostConfig([], {}, home);
    expect(fromFile.configFile).toBe(join(home, DEFAULT_HOST_V2_HOME, "config.json"));
    expect(fromFile.agentDir).toBe(join(home, "from-file-agent"));
    expect(fromFile.port).toBe(44001);
    expect(fromFile.hostId).toBe("file-id");

    // Env beats file.
    const fromEnv = loadHostConfig([], { PI_HOST_V2_PORT: "44002", PI_HOST_V2_HOST_ID: "env-id" }, home);
    expect(fromEnv.port).toBe(44002);
    expect(fromEnv.hostId).toBe("env-id");
    expect(fromEnv.agentDir).toBe(join(home, "from-file-agent"));

    // CLI beats env and file.
    const fromCli = loadHostConfig(["--port", "44003", "--agent-dir", "/tmp/cli-agent"], { PI_HOST_V2_PORT: "44002" }, home);
    expect(fromCli.port).toBe(44003);
    expect(fromCli.agentDir).toBe("/tmp/cli-agent");
  });

  it("keeps the namespaced env over the deprecated shared aliases", () => {
    const config = parseHostConfig(
      [],
      { PI_HOST_V2_AGENT_DIR: "/tmp/v2-agent", PI_AGENT_DIR: "/tmp/shared-agent" },
      "/home/tester"
    );
    expect(config.agentDir).toBe("/tmp/v2-agent");
    // The shared alias is still honored when it is the only source.
    expect(parseHostConfig([], { PI_AGENT_DIR: "/tmp/shared-agent" }, "/home/tester").agentDir).toBe("/tmp/shared-agent");
  });

  it("resolves the provider seed file across flag, env, and config file", async () => {
    const home = await mkdtemp(join(tmpdir(), "pi-host-seedcfg-"));
    const { mkdir } = await import("node:fs/promises");
    await mkdir(join(home, DEFAULT_HOST_V2_HOME), { recursive: true });
    await writeFile(
      join(home, DEFAULT_HOST_V2_HOME, "config.json"),
      JSON.stringify({ providerSeedFile: "/tmp/from-file.json" }),
      "utf8"
    );

    // Disabled by default.
    expect(parseHostConfig([], {}, home).providerSeedFile).toBeNull();
    // File, then env over file, then CLI over env.
    expect(loadHostConfig([], {}, home).providerSeedFile).toBe("/tmp/from-file.json");
    expect(
      loadHostConfig([], { PI_HOST_V2_PROVIDER_SEED_FILE: "/tmp/from-env.json" }, home).providerSeedFile
    ).toBe("/tmp/from-env.json");
    expect(
      loadHostConfig(
        ["--provider-seed-file", "/tmp/from-flag.json"],
        { PI_HOST_V2_PROVIDER_SEED_FILE: "/tmp/from-env.json" },
        home
      ).providerSeedFile
    ).toBe("/tmp/from-flag.json");
  });

  it("fails loudly on a malformed config file", async () => {
    const home = await mkdtemp(join(tmpdir(), "pi-host-badcfg-"));
    const { mkdir } = await import("node:fs/promises");
    await mkdir(join(home, DEFAULT_HOST_V2_HOME), { recursive: true });
    await writeFile(join(home, DEFAULT_HOST_V2_HOME, "config.json"), "{ not json", "utf8");
    expect(() => readHostConfigFile(join(home, DEFAULT_HOST_V2_HOME))).toThrow(/invalid config file/);
  });
});
