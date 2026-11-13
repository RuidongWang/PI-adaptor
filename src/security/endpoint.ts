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

/** Extract the IPv4 address embedded in a `::ffff:` mapped IPv6 address. */
function mappedIPv4(address: string): string | null {
  const lower = address.toLowerCase();
  if (!lower.startsWith("::ffff:")) return null;
  const rest = lower.slice("::ffff:".length);
  if (isIP(rest) === 4) return rest;
  // Hex form, e.g. ::ffff:7f00:1 or ::ffff:c0a8:101.
  const match = /^([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(rest);
  if (!match) return null;
  const high = parseInt(match[1]!, 16);
  const low = parseInt(match[2]!, 16);
  return `${high >> 8}.${high & 0xff}.${low >> 8}.${low & 0xff}`;
}

function isPrivateIPv6(address: string): boolean {
  const lower = address.toLowerCase();
  if (lower === "::1" || lower === "::") return true;
  // IPv4-mapped addresses must be classified by their embedded IPv4 value;
  // ::ffff:172.16.0.1 and ::ffff:ac10:1 both reach a private network.
  const mapped = mappedIPv4(lower);
  if (mapped) return isPrivateIPv4(mapped);
  const first = parseInt(lower.split(":")[0] || "0", 16);
  // fc00::/7 (unique local) and fe80::/10 (link-local) are not covered by a
  // simple string prefix: fe80::/10 spans fe80 through febf.
  if ((first & 0xfe00) === 0xfc00) return true;
  if ((first & 0xffc0) === 0xfe80) return true;
  return false;
}

function isPrivateAddress(address: string): boolean {
  const version = isIP(address);
  if (version === 4) return isPrivateIPv4(address);
  if (version === 6) return isPrivateIPv6(address);
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
  if (url.username || url.password) throw new HostError("INVALID_ARGUMENT", "credentials in URL are forbidden");
  const host = url.hostname.toLowerCase();
  // 回环网关（默认的 localhost 模型服务）不需要证书，也永远出不了本机；
  // 其余主机仍要求 https，且默认拒绝私网地址。
  const loopback = host === "localhost"
    || host.endsWith(".localhost")
    || host === "127.0.0.1"
    || host === "::1"
    || host === "[::1]";
  const httpAllowed = url.protocol === "http:" && (loopback || policy.allowHttp);
  if (url.protocol !== "https:" && !httpAllowed) {
    throw new HostError("INVALID_ARGUMENT", "endpoint must use https");
  }
  if (!policy.allowPrivateHosts && !loopback) {
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
