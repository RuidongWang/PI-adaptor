import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_HOME_DIR_NAME,
  ensureHostDirectories,
  loadHostConfig,
  parseHostConfig,
  readHostConfigFile,
  type HostConfigFile
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
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-config-"));
    const config = parseHostConfig(["--data-dir", root, "--agent-dir", join(root, "agent")], {}, root);
    await ensureHostDirectories(config);
    expect((await stat(root)).mode & 0o777).toBe(0o700);
    expect((await stat(join(root, "meta"))).mode & 0o777).toBe(0o700);
  });

  it("isolates every default path under the v2 home and never touches the legacy host", () => {
    const home = "/home/tester";
    const config = parseHostConfig([], {}, home);
    const v2Home = join(home, DEFAULT_HOME_DIR_NAME);
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
    const home = await mkdtemp(join(tmpdir(), "pi-adaptor-home-"));
    const { mkdir } = await import("node:fs/promises");
    await mkdir(join(home, DEFAULT_HOME_DIR_NAME), { recursive: true });
    await writeFile(
      join(home, DEFAULT_HOME_DIR_NAME, "config.json"),
      JSON.stringify({ agentDir: join(home, "from-file-agent"), port: 44001, hostId: "file-id" }),
      "utf8"
    );

    // File only.
    const fromFile = loadHostConfig([], {}, home);
    expect(fromFile.configFile).toBe(join(home, DEFAULT_HOME_DIR_NAME, "config.json"));
    expect(fromFile.agentDir).toBe(join(home, "from-file-agent"));
    expect(fromFile.port).toBe(44001);
    expect(fromFile.hostId).toBe("file-id");

    // Env beats file.
    const fromEnv = loadHostConfig([], { PI_ADAPTOR_PORT: "44002", PI_ADAPTOR_HOST_ID: "env-id" }, home);
    expect(fromEnv.port).toBe(44002);
    expect(fromEnv.hostId).toBe("env-id");
    expect(fromEnv.agentDir).toBe(join(home, "from-file-agent"));

    // CLI beats env and file.
    const fromCli = loadHostConfig(["--port", "44003", "--agent-dir", "/tmp/cli-agent"], { PI_ADAPTOR_PORT: "44002" }, home);
    expect(fromCli.port).toBe(44003);
    expect(fromCli.agentDir).toBe("/tmp/cli-agent");
  });

  it("keeps the namespaced env over the deprecated shared aliases", () => {
    const config = parseHostConfig(
      [],
      { PI_ADAPTOR_AGENT_DIR: "/tmp/v2-agent", PI_AGENT_DIR: "/tmp/shared-agent" },
      "/home/tester"
    );
    expect(config.agentDir).toBe("/tmp/v2-agent");
    // The shared alias is still honored when it is the only source.
    expect(parseHostConfig([], { PI_AGENT_DIR: "/tmp/shared-agent" }, "/home/tester").agentDir).toBe("/tmp/shared-agent");
  });

  it("resolves the provider seed file across flag, env, and config file", async () => {
    const home = await mkdtemp(join(tmpdir(), "pi-adaptor-seedcfg-"));
    const { mkdir } = await import("node:fs/promises");
    await mkdir(join(home, DEFAULT_HOME_DIR_NAME), { recursive: true });
    await writeFile(
      join(home, DEFAULT_HOME_DIR_NAME, "config.json"),
      JSON.stringify({ providerSeedFile: "/tmp/from-file.json" }),
      "utf8"
    );

    // Disabled by default.
    expect(parseHostConfig([], {}, home).providerSeedFile).toBeNull();
    // File, then env over file, then CLI over env.
    expect(loadHostConfig([], {}, home).providerSeedFile).toBe("/tmp/from-file.json");
    expect(
      loadHostConfig([], { PI_ADAPTOR_PROVIDER_SEED_FILE: "/tmp/from-env.json" }, home).providerSeedFile
    ).toBe("/tmp/from-env.json");
    expect(
      loadHostConfig(
        ["--provider-seed-file", "/tmp/from-flag.json"],
        { PI_ADAPTOR_PROVIDER_SEED_FILE: "/tmp/from-env.json" },
        home
      ).providerSeedFile
    ).toBe("/tmp/from-flag.json");
  });

  it("fails loudly on a malformed config file", async () => {
    const home = await mkdtemp(join(tmpdir(), "pi-adaptor-badcfg-"));
    const { mkdir } = await import("node:fs/promises");
    await mkdir(join(home, DEFAULT_HOME_DIR_NAME), { recursive: true });
    await writeFile(join(home, DEFAULT_HOME_DIR_NAME, "config.json"), "{ not json", "utf8");
    expect(() => readHostConfigFile(join(home, DEFAULT_HOME_DIR_NAME))).toThrow(/invalid config file/);
  });
});

describe("release version", () => {
  it("reports the version declared by the shipped package manifest", async () => {
    const { HOST_VERSION } = await import("../src/config.js");
    const manifest = JSON.parse(
      await readFile(new URL("../package.json", import.meta.url), "utf8")
    ) as { version?: string };
    expect(manifest.version).toMatch(/^\d+\.\d+\.\d+/);
    // `scripts/build-release.sh` names the tarball from the manifest, so a host
    // advertising anything else would ship under the wrong version.
    expect(HOST_VERSION).toBe(manifest.version);
    expect(parseHostConfig([], {}, "/home/tester").hostVersion).toBe(manifest.version);
  });
});

describe("direct listener config", () => {
  const completeFile = {
    direct: {
      enabled: true,
      host: "127.0.0.1",
      port: 9444,
      certificateFile: "/tmp/file-cert.pem",
      privateKeyFile: "/tmp/file-key.pem",
      maxConnections: 10,
      messageRateCount: 20,
      messageRateWindowMs: 2_000,
      unauthenticatedTimeoutMs: 3_000
    }
  };

  it("keeps legacy loopback defaults and exposes every direct default", () => {
    const config = parseHostConfig([], {}, "/home/tester");
    expect(config.port).toBe(0);
    expect(config.direct).toEqual({
      enabled: false,
      host: "",
      port: 9443,
      certificateFile: null,
      privateKeyFile: null,
      maxConnections: 64,
      messageRateCount: 60,
      messageRateWindowMs: 10_000,
      unauthenticatedTimeoutMs: 10_000
    });
  });

  it("binds the complete config/env/CLI set in precedence order", () => {
    const fromFile = parseHostConfig([], {}, "/home/tester", completeFile);
    expect(fromFile.direct).toEqual({
      enabled: true,
      host: "127.0.0.1",
      port: 9444,
      certificateFile: "/tmp/file-cert.pem",
      privateKeyFile: "/tmp/file-key.pem",
      maxConnections: 10,
      messageRateCount: 20,
      messageRateWindowMs: 2_000,
      unauthenticatedTimeoutMs: 3_000
    });

    const env = {
      PI_ADAPTOR_DIRECT_ENABLED: "1",
      PI_ADAPTOR_DIRECT_HOST: "0.0.0.0",
      PI_ADAPTOR_DIRECT_PORT: "9445",
      PI_ADAPTOR_DIRECT_CERTIFICATE_FILE: "/tmp/env-cert.pem",
      PI_ADAPTOR_DIRECT_PRIVATE_KEY_FILE: "/tmp/env-key.pem",
      PI_ADAPTOR_DIRECT_MAX_CONNECTIONS: "11",
      PI_ADAPTOR_DIRECT_MESSAGE_RATE_COUNT: "21",
      PI_ADAPTOR_DIRECT_MESSAGE_RATE_WINDOW_MS: "2001",
      PI_ADAPTOR_DIRECT_UNAUTHENTICATED_TIMEOUT_MS: "3001"
    };
    expect(parseHostConfig([], env, "/home/tester", completeFile).direct).toEqual({
      enabled: true,
      host: "0.0.0.0",
      port: 9445,
      certificateFile: "/tmp/env-cert.pem",
      privateKeyFile: "/tmp/env-key.pem",
      maxConnections: 11,
      messageRateCount: 21,
      messageRateWindowMs: 2_001,
      unauthenticatedTimeoutMs: 3_001
    });

    const fromCli = parseHostConfig([
      "--direct",
      "--direct-host", "::1",
      "--direct-port", "9446",
      "--direct-cert", "/tmp/cli-cert.pem",
      "--direct-key", "/tmp/cli-key.pem",
      "--direct-max-connections", "12",
      "--direct-message-rate-count", "22",
      "--direct-message-rate-window-ms", "2002",
      "--direct-unauthenticated-timeout-ms", "3002"
    ], env, "/home/tester", completeFile);
    expect(fromCli.direct).toEqual({
      enabled: true,
      host: "::1",
      port: 9446,
      certificateFile: "/tmp/cli-cert.pem",
      privateKeyFile: "/tmp/cli-key.pem",
      maxConnections: 12,
      messageRateCount: 22,
      messageRateWindowMs: 2_002,
      unauthenticatedTimeoutMs: 3_002
    });
    expect(parseHostConfig(["--no-direct"], env, "/home/tester", completeFile).direct.enabled).toBe(false);
  });

  it("rejects mutually exclusive enable flags and non-boolean env values", () => {
    expect(() => parseHostConfig(["--direct", "--no-direct"], {}, "/home/tester")).toThrow(/mutually exclusive/);
    expect(() => parseHostConfig([], { PI_ADAPTOR_DIRECT_ENABLED: "true" }, "/home/tester")).toThrow(/DIRECT_ENABLED/);
    expect(parseHostConfig([], { PI_ADAPTOR_DIRECT_ENABLED: "0" }, "/home/tester").direct.enabled).toBe(false);
  });

  it("fails closed on unknown keys, missing enabled inputs, and every invalid range", () => {
    const invalid = [
      { direct: { directName: "host.example" } },
      { direct: { directRateCount: 60 } },
      { direct: { enabled: true, host: "127.0.0.1", certificateFile: "/tmp/cert", privateKeyFile: "/tmp/key", port: 0 } },
      { direct: { enabled: true, certificateFile: "/tmp/cert", privateKeyFile: "/tmp/key" } },
      { direct: { enabled: true, host: "127.0.0.1", privateKeyFile: "/tmp/key" } },
      { direct: { enabled: true, host: "127.0.0.1", certificateFile: "/tmp/cert" } },
      { direct: { enabled: true, host: "127.0.0.1", certificateFile: "relative-cert", privateKeyFile: "/tmp/key" } },
      { direct: { enabled: false, maxConnections: 0 } },
      { direct: { enabled: false, maxConnections: 1025 } },
      { direct: { enabled: false, messageRateCount: 0 } },
      { direct: { enabled: false, messageRateCount: 601 } },
      { direct: { enabled: false, messageRateWindowMs: 999 } },
      { direct: { enabled: false, messageRateWindowMs: 60_001 } },
      { direct: { enabled: false, unauthenticatedTimeoutMs: 999 } },
      { direct: { enabled: false, unauthenticatedTimeoutMs: 30_001 } }
    ];
    for (const value of invalid) {
      expect(() => parseHostConfig([], {}, "/home/tester", value as never), JSON.stringify(value)).toThrow();
    }
    expect(() => parseHostConfig(["--direct-port", "0"], {}, "/home/tester")).toThrow(/direct.port/);
  });

  it("ships the complete direct example and matching systemd env bindings", async () => {
    const example = JSON.parse(await readFile(new URL("../config.example.json", import.meta.url), "utf8")) as HostConfigFile;
    expect(parseHostConfig([], {}, "/home/tester", example).direct).toEqual({
      enabled: true,
      host: "0.0.0.0",
      port: 9443,
      certificateFile: "/home/ubuntu/.pi-adaptor/tls/direct-cert.pem",
      privateKeyFile: "/home/ubuntu/.pi-adaptor/tls/direct-key.pem",
      maxConnections: 64,
      messageRateCount: 60,
      messageRateWindowMs: 10_000,
      unauthenticatedTimeoutMs: 10_000
    });
    const unit = await readFile(new URL("../deploy/pi-adaptor.service", import.meta.url), "utf8");
    for (const name of [
      "PI_ADAPTOR_DIRECT_ENABLED",
      "PI_ADAPTOR_DIRECT_HOST",
      "PI_ADAPTOR_DIRECT_PORT",
      "PI_ADAPTOR_DIRECT_CERTIFICATE_FILE",
      "PI_ADAPTOR_DIRECT_PRIVATE_KEY_FILE",
      "PI_ADAPTOR_DIRECT_MAX_CONNECTIONS",
      "PI_ADAPTOR_DIRECT_MESSAGE_RATE_COUNT",
      "PI_ADAPTOR_DIRECT_MESSAGE_RATE_WINDOW_MS",
      "PI_ADAPTOR_DIRECT_UNAUTHENTICATED_TIMEOUT_MS"
    ]) {
      expect(unit).toContain(`Environment=${name}=`);
    }
  });
});

describe("extensions", () => {
  it("defaults off and normalizes declared metadata", () => {
    expect(parseHostConfig([], {}, "/tmp").extensions).toEqual({ enabled: false, entries: [] });
    const config = parseHostConfig([], {}, "/tmp", { extensions: { entries: [{ id: "a", entryPath: "/tmp/a.ts" }] } });
    expect(config.extensions.entries[0]).toEqual({ id: "a", entryPath: "/tmp/a.ts", name: "a.ts", enabled: true, version: null, compatibility: "unknown" });
  });
  it.each([null, [], true, { enabled: "true" }, { entries: {} }, { extra: true }, { entries: [null] }, { entries: [{ id: "bad id", entryPath: "/tmp/a.ts" }] }, { entries: [{ id: "a", entryPath: "/tmp/a.ts", enabled: 1 }] }, { entries: [{ id: "a", entryPath: "/tmp/a.ts", compatibility: "reviewed" }] }, { entries: [{ id: "a", entryPath: "/tmp/a.ts", name: 1 }] }, { entries: [{ id: "a", entryPath: "/tmp/a.ts", version: null }] }, { entries: [{ id: "a", entryPath: "/tmp/a.ts" }, { id: "a", entryPath: "/tmp/b.ts" }] }])("strictly rejects malformed config %#", extensions => {
    expect(() => parseHostConfig([], {}, "/tmp", { extensions })).toThrow();
  });
});
