import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { access, realpath, stat } from "node:fs/promises";
import { basename, extname, isAbsolute } from "node:path";
import { diagnostic, type ExtensionsConfig, type ExtensionConfigEntry, type InventoryEntry, type RuntimeEntry } from "./types.js";

export function parseExtensionsConfig(raw: unknown): ExtensionsConfig {
  if (raw === undefined) return { enabled: false, entries: [] };
  const record = (value: unknown, keys: string[]): Record<string, unknown> => {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid extensions config: expected object");
    for (const key of Object.keys(value)) if (!keys.includes(key)) throw new Error("unknown extensions config field");
    return value as Record<string, unknown>;
  };
  const value = record(raw, ["enabled", "entries"]);
  if (value.enabled !== undefined && typeof value.enabled !== "boolean") throw new Error("invalid extensions.enabled");
  if (value.entries !== undefined && (!Array.isArray(value.entries) || value.entries.length > 100)) throw new Error("invalid extensions.entries: maximum 100 entries");
  const ids = new Set<string>();
  const text = (v: unknown, max: number): v is string => typeof v === "string" && v.length > 0 && v.length <= max && !/[\x00-\x1f]/.test(v);
  const entries = ((value.entries ?? []) as unknown[]).map(item => {
    const entry = record(item, ["id", "name", "entryPath", "enabled", "version", "compatibility"]);
    if (!text(entry.id, 64) || !/^[a-zA-Z0-9._-]+$/.test(entry.id) || ids.has(entry.id)) throw new Error("invalid or duplicate extensions entry id");
    ids.add(entry.id);
    if (!text(entry.entryPath, 4096) || !isAbsolute(entry.entryPath) || /[*?\[\]{}]/.test(entry.entryPath) || ![".ts", ".js", ".mjs"].includes(extname(entry.entryPath))) throw new Error("invalid extensions.entryPath: expected absolute local .ts/.js/.mjs file");
    if (entry.enabled !== undefined && typeof entry.enabled !== "boolean") throw new Error("invalid extensions entry enabled");
    if (entry.name !== undefined && !text(entry.name, 256)) throw new Error("invalid extensions entry name");
    if (entry.version !== undefined && !text(entry.version, 256)) throw new Error("invalid extensions entry version");
    if (entry.compatibility !== undefined && !["unknown", "headless-reviewed", "requires-ui"].includes(entry.compatibility as string)) throw new Error("invalid extensions entry compatibility");
    return { id: entry.id, entryPath: entry.entryPath, name: entry.name ?? basename(entry.entryPath), enabled: entry.enabled ?? true, version: entry.version ?? null, compatibility: entry.compatibility ?? "unknown" } as ExtensionConfigEntry;
  });
  return { enabled: value.enabled === true, entries };
}

export class ExtensionRegistry {
  private startupEntries: Map<string, string> | undefined;
  private initialization: Promise<void> | undefined;
  async initialize(): Promise<void> {
    this.initialization ??= (async () => {
      const { paths } = await this.inspect();
      const pins = new Map<string, string>();
      for (const [id, path] of paths) {
        try {
          const info = await stat(path);
          pins.set(id, `${path}:${info.dev}:${info.ino}:${info.size}:${info.mtimeMs}:${info.ctimeMs}`);
        } catch { /* A file removed during startup remains unavailable until restart. */ }
      }
      this.startupEntries = pins;
    })();
    return this.initialization;
  }
  readonly config: ExtensionsConfig;
  readonly configRevision: string;
  constructor(config: ExtensionsConfig = { enabled: false, entries: [] }) {
    this.config = structuredClone(config);
    for (const entry of this.config.entries) Object.freeze(entry);
    Object.freeze(this.config.entries); Object.freeze(this.config);
    this.configRevision = createHash("sha256").update(JSON.stringify(this.config)).digest("hex");
  }
  async inspect(): Promise<{ entries: InventoryEntry[]; paths: Map<string, string> }> {
    const entries: InventoryEntry[] = [], paths = new Map<string, string>(), seen = new Set<string>();
    for (const config of this.config.entries) {
      const entry: InventoryEntry = { id: config.id, name: config.name, configuredVersion: config.version, entryPath: config.entryPath, enabled: config.enabled, compatibility: config.compatibility, entryState: "valid", diagnostics: [] };
      try {
        const canonical = await realpath(config.entryPath);
        const info = await stat(canonical);
        if (!info.isFile() || (info.mode & 0o444) === 0 || ![".ts", ".js", ".mjs"].includes(extname(canonical))) throw new Error("not readable entry file");
        await access(canonical, constants.R_OK);
        if (seen.has(canonical)) { entry.entryState = "duplicate"; entry.diagnostics.push(diagnostic("validation", "DUPLICATE_ENTRY", "Entry resolves to an already configured file.")); }
        else { seen.add(canonical); paths.set(config.id, canonical); }
        if (entry.entryState === "valid" && this.startupEntries && this.startupEntries.get(config.id) !== `${canonical}:${info.dev}:${info.ino}:${info.size}:${info.mtimeMs}:${info.ctimeMs}`) {
          entry.entryState = "unreadable";
          paths.delete(config.id);
          entry.diagnostics.push(diagnostic("validation", "ENTRY_CHANGED_RESTART_REQUIRED", "Entry file changed since host startup; restart the host to apply code changes."));
        }
      } catch (error) {
        entry.entryState = (error as NodeJS.ErrnoException).code === "ENOENT" ? "missing" : "unreadable";
        entry.diagnostics.push(diagnostic("validation", entry.entryState === "missing" ? "ENTRY_MISSING" : "ENTRY_UNREADABLE", entry.entryState === "missing" ? "Configured entry file is missing." : "Configured entry must be a readable regular file."));
      }
      entries.push(entry);
    }
    return { entries, paths };
  }
  async prepare() {
    await this.initialize();
    const { entries, paths } = await this.inspect();
    const runtime: RuntimeEntry[] = entries.map(entry => {
      const skipReason = !this.config.enabled ? "host-disabled" : !entry.enabled ? "entry-disabled" : entry.compatibility !== "headless-reviewed" ? "not-adapted" : null;
      return { id: entry.id, name: entry.name, configuredVersion: entry.configuredVersion, loadState: skipReason ? "skipped" : "failed", skipReason, registeredTools: [], activeTools: [], registeredCommands: [], mobileInvocable: false, diagnostics: entry.diagnostics };
    });
    const selected = new Map<string, string>();
    for (const entry of runtime) if (!entry.skipReason && paths.has(entry.id)) selected.set(entry.id, paths.get(entry.id)!);
    return { entries: runtime, paths: selected };
  }
  async inventory(hostId: string) {
    return { hostId, configRevision: this.configRevision, userLoadingEnabled: this.config.enabled, capturedAt: new Date().toISOString(), entries: (await this.inspect()).entries };
  }
}
