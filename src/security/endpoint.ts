import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { HostError } from "../errors.js";
import { allowsProviderAddress, isLoopbackHostname, type ProviderDiscoveryLookup } from "../providers/discovery.js";

export type EndpointPolicy = {
  allowPrivateHosts?: boolean;
  allowLoopback?: boolean;
  lookup?: ProviderDiscoveryLookup | undefined;
};

export function endpointHostname(url: URL): string {
  return url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
}

export function parseEndpoint(raw: string, policy: EndpointPolicy = {}): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new HostError("INVALID_ARGUMENT", "invalid endpoint URL");
  }
  if (url.username || url.password) throw new HostError("INVALID_ARGUMENT", "credentials in URL are forbidden");
  if (url.protocol !== "https:" && !(url.protocol === "http:" && policy.allowLoopback !== false && isLoopbackHostname(endpointHostname(url)))) {
    throw new HostError("INVALID_ARGUMENT", "endpoint must use https");
  }
  return url;
}

export async function resolveEndpointAddresses(hostname: string, policy: EndpointPolicy = {}) {
  const answers = isIP(hostname) ? [{ address: hostname }] : await (policy.lookup ?? lookupAll)(hostname);
  if (!answers.length || answers.some(({ address }) => !isIP(address) || (!policy.allowPrivateHosts && !allowsProviderAddress(hostname, address, policy.allowLoopback !== false)))) {
    throw new HostError("INVALID_ARGUMENT", "private endpoint is forbidden");
  }
  return answers.map(({ address }) => ({ address, family: isIP(address) }));
}

function lookupAll(hostname: string) {
  return lookup(hostname, { all: true });
}

export async function assertPublicHttpsEndpoint(raw: string, policy: EndpointPolicy = {}): Promise<URL> {
  const url = parseEndpoint(raw, policy);
  if (!policy.allowPrivateHosts) await resolveEndpointAddresses(endpointHostname(url), policy);
  return url;
}
