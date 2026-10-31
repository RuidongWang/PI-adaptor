import { join } from "node:path";
import { rm } from "node:fs/promises";
import { HostError } from "../errors.js";
import { readSecret, writeSecret } from "../security/secrets.js";
import { assertPublicHttpsEndpoint } from "../security/endpoint.js";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";
import { uuid } from "../util/id.js";

export type ProviderModel = {
  id: string;
  displayName: string;
  contextWindow: number;
  maxTokens: number;
  thinkingLevels: string[];
  defaultThinkingLevel: string | null;
  supportsImages: boolean;
};

export type ProviderInput = {
  name: string;
  vendorKey: string;
  type: string;
  protocol: string;
  baseUrl: string;
  authKind: "api_key" | "none";
  apiKey?: string;
  models: ProviderModel[];
};

type ProviderRecord = ProviderInput & {
  id: string;
  createdAt: string;
  updatedAt: string;
  isDefault: boolean;
};

type ProviderFile = { version: 1; providers: ProviderRecord[] };
const EMPTY: ProviderFile = { version: 1, providers: [] };

function mask(key: string): string {
  if (key.length <= 8) return "••••";
  return `${key.slice(0, 3)}…${key.slice(-4)}`;
}

export class ProviderStore {
  private pending: Promise<void> = Promise.resolve();

  private serialized<T>(work: () => Promise<T>): Promise<T> {
    const result = this.pending.then(work);
    this.pending = result.then(() => undefined, () => undefined);
    return result;
  }

  private readonly index: string;
  private readonly secretsDir: string;

  constructor(dataDir: string, private readonly allowPrivateHosts = false) {
    this.index = join(dataDir, "providers", "providers.json");
    this.secretsDir = join(dataDir, "providers", "secrets");
  }

  private async load(): Promise<ProviderFile> {
    const value = await readJsonFile<ProviderFile>(this.index, structuredClone(EMPTY));
    if (value.version !== 1) throw new HostError("INTERNAL", "unsupported provider store");
    return value;
  }

  private async save(value: ProviderFile): Promise<void> {
    await writeJsonFileAtomic(this.index, value, 0o600);
  }

  private async view(record: ProviderRecord) {
    const key = await readSecret(join(this.secretsDir, record.id));
    return {
      ...record,
      apiKey: undefined,
      hasApiKey: key !== null,
      apiKeyMask: key ? mask(key) : null
    };
  }

  async list() {
    return Promise.all((await this.load()).providers.map((record) => this.view(record)));
  }

  async create(input: ProviderInput, now = new Date()) {
    return this.serialized(async () => {
      await assertPublicHttpsEndpoint(input.baseUrl, { allowPrivateHosts: this.allowPrivateHosts });
      if (input.authKind === "api_key" && !input.apiKey) {
        throw new HostError("INVALID_ARGUMENT", "apiKey is required for api_key provider");
      }
      if (input.authKind === "none" && input.apiKey) {
        throw new HostError("INVALID_ARGUMENT", "apiKey is forbidden for none provider");
      }
      const data = await this.load();
      if (data.providers.some((entry) => entry.vendorKey === input.vendorKey)) {
        throw new HostError("CONFLICT", "provider vendorKey already exists");
      }
      const { apiKey: _apiKey, ...publicInput } = input;
      const record: ProviderRecord = {
        ...publicInput,
        id: uuid(),
        createdAt: now.toISOString(),
        updatedAt: now.toISOString(),
        isDefault: data.providers.length === 0
      };
      if (input.apiKey) await writeSecret(join(this.secretsDir, record.id), input.apiKey);
      data.providers.push(record);
      await this.save(data);
      return this.view(record);
    });
  }

  async update(id: string, input: ProviderInput, now = new Date()) {
    return this.serialized(async () => {
      await assertPublicHttpsEndpoint(input.baseUrl, { allowPrivateHosts: this.allowPrivateHosts });
      const data = await this.load();
      const record = data.providers.find((entry) => entry.id === id);
      if (!record) throw new HostError("NOT_FOUND", "provider not found");
      if (input.authKind === "none" && input.apiKey) {
        throw new HostError("INVALID_ARGUMENT", "apiKey is forbidden for none provider");
      }
      Object.assign(record, input, { apiKey: undefined, updatedAt: now.toISOString() });
      if (input.apiKey) await writeSecret(join(this.secretsDir, id), input.apiKey);
      await this.save(data);
      return this.view(record);
    });
  }

  async delete(id: string): Promise<boolean> {
    return this.serialized(async () => {
      const data = await this.load();
      const index = data.providers.findIndex((entry) => entry.id === id);
      if (index < 0) throw new HostError("NOT_FOUND", "provider not found");
      data.providers.splice(index, 1);
      await this.save(data);
      await rm(join(this.secretsDir, id), { force: true });
      return true;
    });
  }

  async secret(id: string): Promise<string | null> {
    return readSecret(join(this.secretsDir, id));
  }
}
