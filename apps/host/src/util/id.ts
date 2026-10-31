import { createHash, randomBytes, randomUUID } from "node:crypto";

export function uuid(): string {
  return randomUUID();
}

export function opaqueToken(prefix: "pdt2" | "ppt2"): string {
  return `${prefix}.${randomBytes(32).toString("base64url")}`;
}

export function sha256(value: string | Uint8Array): string {
  return createHash("sha256").update(value).digest("hex");
}
