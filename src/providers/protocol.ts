/**
 * Provider wire protocols supported by the iOS client.
 *
 * The identifiers match pi-ai's `Api` union, so a provider record can be
 * handed to `registerProvider` without a translation table on the client.
 * Older records used `openai_compatible`; they keep the historical
 * OpenAI Chat Completions behaviour.
 */
export const PROVIDER_APIS = [
  "openai-completions",
  "openai-responses",
  "anthropic-messages",
  "google-generative-ai"
] as const;

export type ProviderApi = (typeof PROVIDER_APIS)[number];

export function providerApi(protocol: string | undefined): ProviderApi {
  return (PROVIDER_APIS as readonly string[]).includes(protocol ?? "")
    ? (protocol as ProviderApi)
    : "openai-completions";
}

export function isSupportedProviderProtocol(protocol: string | undefined): boolean {
  return (PROVIDER_APIS as readonly string[]).includes(protocol ?? "");
}
