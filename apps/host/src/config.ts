import { chmod, mkdir, realpath } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

export type HostConfig = {
  /** Single isolated root; every default path lives below it. */
  home: string;
  dataDir: string;
  agentDir: string;
  sessionRoots: string[];
  logsDir: string;
  runDir: string;
  /** Config file that was actually read, or null when none existed. */
  configFile: string | null;
  /** JSON file of providers (with plaintext keys) seeded into the v2 provider
   * store at startup, or null when disabled. Test/bootstrap only. */
  providerSeedFile: string | null;
  port: number;
  pair: boolean;
  hostId: string;
  hostVersion: string;
  piVersion: string;
};

/**
 * Config file shape at `<home>/config.json`. Every key is optional; a key set
 * here is a default that CLI flags and `PI_HOST_V2_*` env vars still override.
 */
export type HostConfigFile = {
  dataDir?: string;
  agentDir?: string;
  sessionDir?: string;
  port?: number;
  pair?: boolean;
  hostId?: string;
  hostVersion?: string;
  piVersion?: string;
  providerSeedFile?: string;
};

/** Default root for a fully self-contained v2 host. */
export const DEFAULT_HOST_V2_HOME = ".pi-host-v2";

function valueAfter(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index < 0) return undefined;
  return args[index + 1];
}

function numberFromPort(raw: unknown, source: string): number {
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 0 || port > 65_535) {
    throw new Error(`invalid port (${source}): ${String(raw)}`);
  }
  return port;
}

/**
 * Read `<home>/config.json`. Missing file → `{}`. Malformed file → throws so a
 * broken config fails loudly instead of silently starting with wrong paths.
 */
export function readHostConfigFile(home: string, explicitPath?: string): { path: string | null; value: HostConfigFile } {
  const path = explicitPath ? resolve(explicitPath) : join(resolve(home), "config.json");
  if (!existsSync(path)) {
    if (explicitPath) throw new Error(`config file not found: ${path}`);
    return { path: null, value: {} };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`invalid config file ${path}: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`invalid config file ${path}: expected a JSON object`);
  }
  return { path, value: parsed as HostConfigFile };
}

/**
 * Resolve the v2 host config.
 *
 * Isolation contract: the defaults never reference the legacy PI-Desktop host
 * (`~/.pi-desktop`) or the shared pi global dir (`~/.pi/agent`). Everything is
 * derived from `home` (default `~/.pi-host-v2`) unless a caller overrides it.
 *
 * Precedence, high → low: CLI flag → `PI_HOST_V2_*` env → `<home>/config.json`
 * → derived default. Legacy generic env aliases (`PI_AGENT_DIR`,
 * `PI_SESSION_DIR`, `PI_CODING_AGENT_VERSION`) are still accepted below the
 * namespaced ones, but they are deprecated exactly because they are shared.
 */
export function parseHostConfig(
  args: string[],
  env: NodeJS.ProcessEnv = process.env,
  home = homedir(),
  fileConfig: HostConfigFile = {}
): HostConfig {
  const homeDir = resolve(valueAfter(args, "--home") ?? env.PI_HOST_V2_HOME ?? join(home, DEFAULT_HOST_V2_HOME));

  const fileDataDir = typeof fileConfig.dataDir === "string" ? fileConfig.dataDir : undefined;
  const rawDataDir =
    valueAfter(args, "--data-dir") ?? env.PI_HOST_V2_DATA_DIR ?? fileDataDir ?? join(homeDir, "data");
  const dataDir = resolve(rawDataDir);

  const fileAgentDir = typeof fileConfig.agentDir === "string" ? fileConfig.agentDir : undefined;
  const agentDir = resolve(
    valueAfter(args, "--agent-dir") ??
      env.PI_HOST_V2_AGENT_DIR ??
      env.PI_AGENT_DIR ?? // deprecated shared alias
      fileAgentDir ??
      join(homeDir, "agent")
  );

  const fileSessionDir = typeof fileConfig.sessionDir === "string" ? fileConfig.sessionDir : undefined;
  const configuredSessionDir =
    valueAfter(args, "--session-dir") ?? env.PI_HOST_V2_SESSION_DIR ?? env.PI_SESSION_DIR ?? fileSessionDir;
  const sessionRoots = configuredSessionDir
    ? [resolve(configuredSessionDir)]
    : [join(dataDir, "sessions")];

  const rawPort = valueAfter(args, "--port") ?? env.PI_HOST_V2_PORT ?? fileConfig.port ?? 0;
  const port = numberFromPort(rawPort, "port");

  const fileSeedFile =
    typeof fileConfig.providerSeedFile === "string" ? fileConfig.providerSeedFile : undefined;
  const rawSeedFile =
    valueAfter(args, "--provider-seed-file") ?? env.PI_HOST_V2_PROVIDER_SEED_FILE ?? fileSeedFile;

  return {
    home: homeDir,
    dataDir,
    agentDir,
    sessionRoots,
    logsDir: join(homeDir, "logs"),
    runDir: join(homeDir, "run"),
    configFile: null,
    providerSeedFile: rawSeedFile ? resolve(rawSeedFile) : null,
    port,
    pair: args.includes("--pair") || env.PI_HOST_V2_PAIR === "1" || fileConfig.pair === true,
    hostId: valueAfter(args, "--host-id") ?? env.PI_HOST_V2_HOST_ID ?? fileConfig.hostId ?? "",
    hostVersion: env.PI_HOST_V2_VERSION ?? fileConfig.hostVersion ?? "0.1.0",
    piVersion: env.PI_CODING_AGENT_VERSION ?? fileConfig.piVersion ?? "1.3.0"
  };
}

/** Convenience wrapper: resolve `home`, read the config file, then parse. */
export function loadHostConfig(
  args: string[],
  env: NodeJS.ProcessEnv = process.env,
  home = homedir()
): HostConfig {
  const homeDir = resolve(valueAfter(args, "--home") ?? env.PI_HOST_V2_HOME ?? join(home, DEFAULT_HOST_V2_HOME));
  const explicitConfig = valueAfter(args, "--config");
  const file = readHostConfigFile(homeDir, explicitConfig);
  return { ...parseHostConfig(args, env, home, file.value), configFile: file.path };
}

export async function ensureHostDirectories(config: HostConfig): Promise<void> {
  await mkdir(config.home, { recursive: true, mode: 0o700 });
  await chmod(config.home, 0o700);
  await mkdir(config.dataDir, { recursive: true, mode: 0o700 });
  await chmod(config.dataDir, 0o700);
  for (const name of ["meta", "media", "staging", "providers", "skills", "logs"]) {
    const path = join(config.dataDir, name);
    await mkdir(path, { recursive: true, mode: 0o700 });
    await chmod(path, 0o700);
  }
  await mkdir(config.agentDir, { recursive: true, mode: 0o700 });
  await mkdir(config.logsDir, { recursive: true, mode: 0o700 });
  await mkdir(config.runDir, { recursive: true, mode: 0o700 });
}

export async function canonicalPath(path: string): Promise<string> {
  return realpath(resolve(path));
}
