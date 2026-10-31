import { readFile } from "node:fs/promises";
import { ProviderStore, type ProviderInput, type ProviderModel } from "./store.js";

/**
 * Provider seed file (<home>/providers.seed.json by convention, path supplied by
 * `--provider-seed-file` / `PI_ADAPTOR_PROVIDER_SEED_FILE` / `config.json`).
 *
 * It carries **plaintext** provider credentials so a freshly booted Host can run
 * connection/turn tests without a client importing a provider first. It is a
 * bootstrap/testing affordance only: the file MUST stay outside version control
 * (see docs/qa/2026-10-31-deepseek-live-test.md) and is meant to hold test keys.
 */
export type ProviderSeedEntry = ProviderInput;

const AUTH_KINDS = new Set(["api_key", "none"]);

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`provider seed: ${field} must be a non-empty string`);
  }
  return value;
}

function parseModel(raw: unknown, index: number): ProviderModel {
  if (!raw || typeof raw !== "object") {
    throw new Error(`provider seed: models[${index}] must be an object`);
  }
  const model = raw as Record<string, unknown>;
  const id = requireString(model.id, `models[${index}].id`);
  const thinkingLevels = model.thinkingLevels === undefined ? [] : model.thinkingLevels;
  if (!Array.isArray(thinkingLevels) || !thinkingLevels.every((level) => typeof level === "string")) {
    throw new Error(`provider seed: models[${index}].thinkingLevels must be a string array`);
  }
  const defaultThinkingLevel =
    model.defaultThinkingLevel === undefined || model.defaultThinkingLevel === null
      ? null
      : requireString(model.defaultThinkingLevel, `models[${index}].defaultThinkingLevel`);
  return {
    id,
    displayName:
      model.displayName === undefined ? id : requireString(model.displayName, `models[${index}].displayName`),
    contextWindow: typeof model.contextWindow === "number" ? model.contextWindow : 128_000,
    maxTokens: typeof model.maxTokens === "number" ? model.maxTokens : 16_384,
    thinkingLevels: thinkingLevels as string[],
    defaultThinkingLevel,
    supportsImages: model.supportsImages === true
  };
}

function parseEntry(raw: unknown, index: number): ProviderSeedEntry {
  if (!raw || typeof raw !== "object") {
    throw new Error(`provider seed: providers[${index}] must be an object`);
  }
  const entry = raw as Record<string, unknown>;
  const authKind = entry.authKind === undefined ? "api_key" : entry.authKind;
  if (typeof authKind !== "string" || !AUTH_KINDS.has(authKind)) {
    throw new Error(`provider seed: providers[${index}].authKind must be "api_key" or "none"`);
  }
  const models = entry.models === undefined ? [] : entry.models;
  if (!Array.isArray(models)) {
    throw new Error(`provider seed: providers[${index}].models must be an array`);
  }
  const apiKey = entry.apiKey === undefined ? undefined : requireString(entry.apiKey, `providers[${index}].apiKey`);
  if (authKind === "api_key" && !apiKey) {
    throw new Error(`provider seed: providers[${index}] requires apiKey for authKind "api_key"`);
  }
  return {
    name: requireString(entry.name, `providers[${index}].name`),
    vendorKey: requireString(entry.vendorKey, `providers[${index}].vendorKey`),
    type: requireString(entry.type, `providers[${index}].type`),
    protocol: requireString(entry.protocol, `providers[${index}].protocol`),
    baseUrl: requireString(entry.baseUrl, `providers[${index}].baseUrl`),
    authKind: authKind as ProviderInput["authKind"],
    ...(apiKey ? { apiKey } : {}),
    models: models.map((model, modelIndex) => parseModel(model, modelIndex))
  };
}

/** Parse the seed file's JSON content. Pure; throws on any shape violation. */
export function parseProviderSeed(raw: unknown): ProviderSeedEntry[] {
  const list = Array.isArray(raw) ? raw : (raw as { providers?: unknown } | null)?.providers;
  if (!Array.isArray(list)) {
    throw new Error("provider seed: expected a JSON array or an object with a `providers` array");
  }
  return list.map((entry, index) => parseEntry(entry, index));
}

export async function loadProviderSeed(path: string): Promise<ProviderSeedEntry[]> {
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch (error) {
    throw new Error(
      `provider seed file not readable: ${path} (${error instanceof Error ? error.message : String(error)})`
    );
  }
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (error) {
    throw new Error(`provider seed file is not valid JSON: ${path} (${error instanceof Error ? error.message : String(error)})`);
  }
  return parseProviderSeed(raw);
}

export type ProviderSeedResult = { created: number; updated: number };

/**
 * Upsert each seed entry into the v2 provider store, keyed by `vendorKey`, so
 * restarting the Host with the same file is idempotent. Uses the store's own
 * create/update, so the endpoint and auth-kind rules still apply (and private
 * base URLs are rejected unless the store was built with `allowPrivateHosts`).
 */
export async function applyProviderSeed(
  store: ProviderStore,
  entries: ProviderSeedEntry[]
): Promise<ProviderSeedResult> {
  const existing = await store.list();
  let created = 0;
  let updated = 0;
  for (const entry of entries) {
    const match = existing.find((record) => record.vendorKey === entry.vendorKey);
    if (match) {
      await store.update(match.id, entry);
      updated += 1;
    } else {
      const record = await store.create(entry);
      existing.push(record);
      created += 1;
    }
  }
  return { created, updated };
}
