import type { AssistantMessage, CredentialStore } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { AsyncLocalStorage } from "node:async_hooks";
import { isIP } from "node:net";
import { Agent, fetch as guardedFetch, type RequestInit } from "undici";
import { HostError } from "../errors.js";
import { endpointHostname, parseEndpoint, resolveEndpointAddresses } from "../security/endpoint.js";

const modelOrigin = new AsyncLocalStorage<string>();
const dispatcher = new Agent({
  connect: {
    lookup(hostname, options, callback) {
      resolveEndpointAddresses(hostname).then(addresses => {
        const matching = addresses.filter(address => !options.family || address.family === options.family);
        const first = matching[0];
        if (!first) callback(new Error("no approved address for requested family"), "");
        else if (options.all) callback(null, matching);
        else callback(null, first.address, first.family);
      }, error => callback(error as NodeJS.ErrnoException, ""));
    }
  }
});
let fetchGuardInstalled = false;

function installModelFetchGuard(): void {
  if (fetchGuardInstalled) return;
  fetchGuardInstalled = true;
  const fetch = globalThis.fetch;
  // Gemini does not accept a custom fetch. Scope the shared hook to SDK model
  // requests so unrelated Host and extension traffic retains platform behavior.
  globalThis.fetch = async (input, init) => {
    const origin = modelOrigin.getStore();
    if (origin === undefined) return fetch(input, init);
    const url = parseEndpoint(input instanceof Request ? input.url : String(input));
    if (url.origin !== origin) throw new HostError("INVALID_ARGUMENT", "model request changed endpoint");
    const hostname = endpointHostname(url);
    // Node skips lookup for literals; named destinations are checked by the
    // connector and only the returned addresses can be dialed.
    if (isIP(hostname)) await resolveEndpointAddresses(hostname);
    const request = new Request(input, init);
    const options: RequestInit = {
      method: request.method,
      headers: [...request.headers],
      ...(request.body ? { body: request.body, duplex: "half" } : {}),
      signal: request.signal,
      dispatcher,
      redirect: "error"
    };
    // Fetch and dispatcher must come from the same Undici version.
    return await guardedFetch(url, options) as unknown as Response;
  };
}

const emptyCredentials: CredentialStore = {
  async read() { return undefined; },
  async list() { return []; },
  async modify(_providerId, update) { return update(undefined); },
  async delete() {}
};

export async function createProviderRuntime(
  providerId: string,
  config: Omit<Parameters<ModelRuntime["registerProvider"]>[1], "apiKey">,
  apiKey: string
): Promise<ModelRuntime> {
  const origin = parseEndpoint(config.baseUrl ?? "").origin;
  installModelFetchGuard();
  const runtime = await ModelRuntime.create({ credentials: emptyCredentials, modelsPath: null });
  // The SDK interprets registered key configuration. The runtime credential is literal.
  runtime.registerProvider(providerId, { ...config, apiKey: "none" });
  await runtime.setRuntimeApiKey(providerId, apiKey);
  const stream = runtime.stream.bind(runtime);
  const streamSimple = runtime.streamSimple.bind(runtime);
  const complete = runtime.complete.bind(runtime);
  const completeSimple = runtime.completeSimple.bind(runtime);
  runtime.stream = (...args) => modelOrigin.run(origin, () => stream(...args));
  runtime.streamSimple = (...args) => modelOrigin.run(origin, () => streamSimple(...args));
  runtime.complete = (...args) => modelOrigin.run(origin, () => complete(...args));
  runtime.completeSimple = (...args) => modelOrigin.run(origin, () => completeSimple(...args));
  return runtime;
}

export function publicAssistantMessage(message: AssistantMessage): AssistantMessage {
  const { errorMessage, diagnostics: _diagnostics, rawStopReason: _rawStopReason, ...safe } = message;
  if (message.stopReason !== "error" && errorMessage === undefined) return safe;
  return { ...safe, content: [], errorMessage: "Model request failed" };
}
