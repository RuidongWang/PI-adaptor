import { chmod, mkdir, realpath } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

export type DirectConfig = {
  enabled: boolean;
  host: string;
  port: number;
  certificateFile: string | null;
  privateKeyFile: string | null;
  maxConnections: number;
  messageRateCount: number;
  messageRateWindowMs: number;
  unauthenticatedTimeoutMs: number;
};

export type DirectConfigFile = {
  enabled?: boolean;
  host?: string;
  port?: number;
  certificateFile?: string;
  privateKeyFile?: string;
  maxConnections?: number;
  messageRateCount?: number;
  messageRateWindowMs?: number;
  unauthenticatedTimeoutMs?: number;
};

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
  direct: DirectConfig;
};

/**
 * Config file shape at `<home>/config.json`. Every key is optional; a key set
 * here is a default that CLI flags and `PI_ADAPTOR_*` env vars still override.
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
  direct?: DirectConfigFile;
};

/**
 * Default root for a fully self-contained PI-adaptor host. Deliberately
 * distinct from the legacy PI-Desktop host (`~/.pi-desktop`) and from any
 * earlier PI-adaptor data root, so an old install can never be mistaken for
 * this one.
 */
export const DEFAULT_HOME_DIR_NAME = ".pi-adaptor";

/**
 * Host version, read from the package manifest that ships with the bundle
 * (`dist/config.js` → `../package.json`). This is the only place a release
 * version is defined; `scripts/build-release.sh` names the tarball from the
 * same field, so bytes and declared version cannot drift apart.
 */
function readPackageVersion(): string {
  try {
    const require = createRequire(import.meta.url);
    const pkg = require("../package.json") as { version?: unknown };
    return typeof pkg.version === "string" && pkg.version.length > 0 ? pkg.version : "0.0.0";
  } catch {
    return "0.0.0";
  }
}

export const HOST_VERSION = readPackageVersion();

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

const DIRECT_CONFIG_KEYS = new Set([
  "enabled",
  "host",
  "port",
  "certificateFile",
  "privateKeyFile",
  "maxConnections",
  "messageRateCount",
  "messageRateWindowMs",
  "unauthenticatedTimeoutMs"
]);

function directCliValue(args: string[], name: string): string | undefined {
  const indexes = args.flatMap((value, index) => value === name ? [index] : []);
  if (indexes.length === 0) return undefined;
  if (indexes.length !== 1) throw new Error(`duplicate direct CLI option: ${name}`);
  const value = args[indexes[0]! + 1];
  if (value === undefined || value.startsWith("--")) {
    throw new Error(`missing value for ${name}`);
  }
  return value;
}

function directNumber(raw: unknown, field: string, minimum: number, maximum: number): number {
  if ((typeof raw !== "string" && typeof raw !== "number") || raw === "") {
    throw new Error(`invalid direct.${field}: ${String(raw)}`);
  }
  const value = Number(raw);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`invalid direct.${field}: expected ${minimum}..${maximum}`);
  }
  return value;
}

function directString(raw: unknown, field: string): string {
  if (typeof raw !== "string" || raw.length === 0 || raw.trim() !== raw || /\s/.test(raw)) {
    throw new Error(`invalid direct.${field}: expected a non-empty value without whitespace`);
  }
  return raw;
}

function parseDirectConfig(args: string[], env: NodeJS.ProcessEnv, fileConfig: HostConfigFile): DirectConfig {
  const fileValue = fileConfig.direct as unknown;
  if (fileValue !== undefined && (!fileValue || typeof fileValue !== "object" || Array.isArray(fileValue))) {
    throw new Error("invalid direct config: expected an object");
  }
  const file = (fileValue ?? {}) as Record<string, unknown>;
  for (const [key, value] of Object.entries(file)) {
    if (!DIRECT_CONFIG_KEYS.has(key)) throw new Error(`unknown direct config key: ${key}`);
    if (value === undefined) continue;
    const expected = key === "enabled" ? "boolean" : ["host", "certificateFile", "privateKeyFile"].includes(key) ? "string" : "number";
    if (typeof value !== expected) throw new Error(`invalid direct.${key}: expected ${expected}`);
  }

  const cliEnabled = args.includes("--direct");
  const cliDisabled = args.includes("--no-direct");
  if (cliEnabled && cliDisabled) throw new Error("--direct and --no-direct are mutually exclusive");
  let enabled = file.enabled === true;
  if (env.PI_ADAPTOR_DIRECT_ENABLED !== undefined) {
    if (env.PI_ADAPTOR_DIRECT_ENABLED !== "0" && env.PI_ADAPTOR_DIRECT_ENABLED !== "1") {
      throw new Error("invalid PI_ADAPTOR_DIRECT_ENABLED: expected 0 or 1");
    }
    enabled = env.PI_ADAPTOR_DIRECT_ENABLED === "1";
  }
  if (cliEnabled) enabled = true;
  if (cliDisabled) enabled = false;

  const hostRaw = directCliValue(args, "--direct-host") ?? env.PI_ADAPTOR_DIRECT_HOST ?? file.host;
  const host = hostRaw === undefined ? "" : directString(hostRaw, "host");
  const certificateRaw = directCliValue(args, "--direct-cert") ?? env.PI_ADAPTOR_DIRECT_CERTIFICATE_FILE ?? file.certificateFile;
  const keyRaw = directCliValue(args, "--direct-key") ?? env.PI_ADAPTOR_DIRECT_PRIVATE_KEY_FILE ?? file.privateKeyFile;
  const certificateFile = certificateRaw === undefined ? null : directString(certificateRaw, "certificateFile");
  const privateKeyFile = keyRaw === undefined ? null : directString(keyRaw, "privateKeyFile");
  if (certificateFile !== null && !isAbsolute(certificateFile)) {
    throw new Error("invalid direct.certificateFile: expected an absolute path");
  }
  if (privateKeyFile !== null && !isAbsolute(privateKeyFile)) {
    throw new Error("invalid direct.privateKeyFile: expected an absolute path");
  }
  if (enabled && (!host || !certificateFile || !privateKeyFile)) {
    throw new Error("direct.enabled requires direct.host, direct.certificateFile, and direct.privateKeyFile");
  }

  return {
    enabled,
    host,
    port: directNumber(directCliValue(args, "--direct-port") ?? env.PI_ADAPTOR_DIRECT_PORT ?? file.port ?? 9443, "port", 1, 65_535),
    certificateFile,
    privateKeyFile,
    maxConnections: directNumber(directCliValue(args, "--direct-max-connections") ?? env.PI_ADAPTOR_DIRECT_MAX_CONNECTIONS ?? file.maxConnections ?? 64, "maxConnections", 1, 1024),
    messageRateCount: directNumber(directCliValue(args, "--direct-message-rate-count") ?? env.PI_ADAPTOR_DIRECT_MESSAGE_RATE_COUNT ?? file.messageRateCount ?? 60, "messageRateCount", 1, 600),
    messageRateWindowMs: directNumber(directCliValue(args, "--direct-message-rate-window-ms") ?? env.PI_ADAPTOR_DIRECT_MESSAGE_RATE_WINDOW_MS ?? file.messageRateWindowMs ?? 10_000, "messageRateWindowMs", 1000, 60_000),
    unauthenticatedTimeoutMs: directNumber(directCliValue(args, "--direct-unauthenticated-timeout-ms") ?? env.PI_ADAPTOR_DIRECT_UNAUTHENTICATED_TIMEOUT_MS ?? file.unauthenticatedTimeoutMs ?? 10_000, "unauthenticatedTimeoutMs", 1000, 30_000)
  };
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
 * derived from `home` (default `~/.pi-adaptor`) unless a caller overrides it.
 *
 * Precedence, high → low: CLI flag → `PI_ADAPTOR_*` env → `<home>/config.json`
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
  const homeDir = resolve(valueAfter(args, "--home") ?? env.PI_ADAPTOR_HOME ?? join(home, DEFAULT_HOME_DIR_NAME));

  const fileDataDir = typeof fileConfig.dataDir === "string" ? fileConfig.dataDir : undefined;
  const rawDataDir =
    valueAfter(args, "--data-dir") ?? env.PI_ADAPTOR_DATA_DIR ?? fileDataDir ?? join(homeDir, "data");
  const dataDir = resolve(rawDataDir);

  const fileAgentDir = typeof fileConfig.agentDir === "string" ? fileConfig.agentDir : undefined;
  const agentDir = resolve(
    valueAfter(args, "--agent-dir") ??
      env.PI_ADAPTOR_AGENT_DIR ??
      env.PI_AGENT_DIR ?? // deprecated shared alias
      fileAgentDir ??
      join(homeDir, "agent")
  );

  const fileSessionDir = typeof fileConfig.sessionDir === "string" ? fileConfig.sessionDir : undefined;
  const configuredSessionDir =
    valueAfter(args, "--session-dir") ?? env.PI_ADAPTOR_SESSION_DIR ?? env.PI_SESSION_DIR ?? fileSessionDir;
  const sessionRoots = configuredSessionDir
    ? [resolve(configuredSessionDir)]
    : [join(dataDir, "sessions")];

  const rawPort = valueAfter(args, "--port") ?? env.PI_ADAPTOR_PORT ?? fileConfig.port ?? 0;
  const port = numberFromPort(rawPort, "port");

  const fileSeedFile =
    typeof fileConfig.providerSeedFile === "string" ? fileConfig.providerSeedFile : undefined;
  const rawSeedFile =
    valueAfter(args, "--provider-seed-file") ?? env.PI_ADAPTOR_PROVIDER_SEED_FILE ?? fileSeedFile;

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
    pair: args.includes("--pair") || env.PI_ADAPTOR_PAIR === "1" || fileConfig.pair === true,
    hostId: valueAfter(args, "--host-id") ?? env.PI_ADAPTOR_HOST_ID ?? fileConfig.hostId ?? "",
    hostVersion: env.PI_ADAPTOR_VERSION ?? fileConfig.hostVersion ?? HOST_VERSION,
    piVersion: env.PI_CODING_AGENT_VERSION ?? fileConfig.piVersion ?? "1.3.0",
    direct: parseDirectConfig(args, env, fileConfig)
  };
}

/** Convenience wrapper: resolve `home`, read the config file, then parse. */
export function loadHostConfig(
  args: string[],
  env: NodeJS.ProcessEnv = process.env,
  home = homedir()
): HostConfig {
  const homeDir = resolve(valueAfter(args, "--home") ?? env.PI_ADAPTOR_HOME ?? join(home, DEFAULT_HOME_DIR_NAME));
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
