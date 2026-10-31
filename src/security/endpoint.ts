import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { HostError } from "../errors.js";

function isPrivateIPv4(address: string): boolean {
  const parts = address.split(".").map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part))) return true;
  const [a = 0, b = 0] = parts;
  return (
    a === 10 ||
    a === 127 ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    a === 0
  );
}

function isPrivateAddress(address: string): boolean {
  if (isIP(address) === 4) return isPrivateIPv4(address);
  if (isIP(address) === 6) {
    const lower = address.toLowerCase();
    return (
      lower === "::1" ||
      lower.startsWith("fc") ||
      lower.startsWith("fd") ||
      lower.startsWith("fe80:") ||
      lower.startsWith("::ffff:127.") ||
      lower.startsWith("::ffff:10.") ||
      lower.startsWith("::ffff:192.168.")
    );
  }
  return true;
}

export type EndpointPolicy = {
  allowPrivateHosts?: boolean;
  allowHttp?: boolean;
};

export async function assertPublicHttpsEndpoint(
  raw: string,
  policy: EndpointPolicy = {}
): Promise<URL> {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new HostError("INVALID_ARGUMENT", "invalid endpoint URL");
  }
  if (!policy.allowHttp && url.protocol !== "https:") {
    throw new HostError("INVALID_ARGUMENT", "endpoint must use https");
  }
  if (url.username || url.password) throw new HostError("INVALID_ARGUMENT", "credentials in URL are forbidden");
  const host = url.hostname.toLowerCase();
  if (!policy.allowPrivateHosts) {
    if (host === "localhost" || host.endsWith(".localhost") || host === "metadata.google.internal") {
      throw new HostError("INVALID_ARGUMENT", "private endpoint is forbidden");
    }
    const resolved = isIP(host) ? [{ address: host }] : await lookup(host, { all: true });
    if (resolved.length === 0 || resolved.some((entry) => isPrivateAddress(entry.address))) {
      throw new HostError("INVALID_ARGUMENT", "private endpoint is forbidden");
    }
  }
  return url;
}
