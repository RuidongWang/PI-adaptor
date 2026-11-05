import { createHash, createPrivateKey, X509Certificate } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, readFile, realpath } from "node:fs/promises";
import { dirname } from "node:path";
import type { DirectConfig } from "../config.js";

export type DirectTlsIdentity = {
  /** Exactly one leaf PEM; never the input file's possible certificate chain. */
  certificatePem: string;
  /** Kept in memory only for the HTTPS listener and never included in diagnostics. */
  privateKeyPem: string;
  certificateSha256: string;
  notBefore: string;
  notAfter: string;
};

export class DirectTlsError extends Error {
  constructor(reason: string) {
    super(`direct TLS ${reason}`);
    this.name = "DirectTlsError";
  }
}

type DerElement = {
  tag: number;
  contentStart: number;
  contentEnd: number;
  end: number;
};

function derElement(bytes: Buffer, offset: number): DerElement {
  if (offset < 0 || offset + 2 > bytes.length) throw new DirectTlsError("certificate DER is truncated");
  const tag = bytes[offset]!;
  const firstLength = bytes[offset + 1]!;
  let length = 0;
  let contentStart = offset + 2;
  if (firstLength < 0x80) {
    length = firstLength;
  } else {
    const count = firstLength & 0x7f;
    if (count === 0 || count > 4 || contentStart + count > bytes.length) {
      throw new DirectTlsError("certificate DER has an invalid length");
    }
    if (bytes[contentStart] === 0) throw new DirectTlsError("certificate DER length is not canonical");
    for (let index = 0; index < count; index++) length = length * 256 + bytes[contentStart + index]!;
    contentStart += count;
  }
  const contentEnd = contentStart + length;
  if (!Number.isSafeInteger(contentEnd) || contentEnd > bytes.length) {
    throw new DirectTlsError("certificate DER is truncated");
  }
  return { tag, contentStart, contentEnd, end: contentEnd };
}

function children(bytes: Buffer, parent: DerElement): DerElement[] {
  const result: DerElement[] = [];
  let offset = parent.contentStart;
  while (offset < parent.contentEnd) {
    const child = derElement(bytes, offset);
    if (child.end > parent.contentEnd) throw new DirectTlsError("certificate DER child exceeds its parent");
    result.push(child);
    offset = child.end;
  }
  if (offset !== parent.contentEnd) throw new DirectTlsError("certificate DER sequence is inconsistent");
  return result;
}

function oidEquals(bytes: Buffer, element: DerElement, expected: number[]): boolean {
  return element.tag === 0x06 &&
    element.contentEnd - element.contentStart === expected.length &&
    expected.every((value, index) => bytes[element.contentStart + index] === value);
}

const BASIC_CONSTRAINTS_OID = [0x55, 0x1d, 0x13];
const KEY_USAGE_OID = [0x55, 0x1d, 0x0f];
const EXTENDED_KEY_USAGE_OID = [0x55, 0x1d, 0x25];
const SERVER_AUTH_OID = [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01];

type CertificateExtensions = { basicConstraintsCaFalse: boolean; serverAuth: boolean; keyUsageValid: boolean };

function validateCertificateExtensions(der: Buffer): CertificateExtensions {
  const certificate = derElement(der, 0);
  if (certificate.tag !== 0x30 || certificate.end !== der.length) {
    throw new DirectTlsError("certificate DER root is invalid");
  }
  const tbs = derElement(der, certificate.contentStart);
  if (tbs.tag !== 0x30) throw new DirectTlsError("certificate TBSCertificate is missing");
  const extensionWrapper = children(der, tbs).find((element) => element.tag === 0xa3);
  if (!extensionWrapper) throw new DirectTlsError("certificate extensions are missing");
  const extensionSequence = derElement(der, extensionWrapper.contentStart);
  if (extensionSequence.tag !== 0x30 || extensionSequence.end !== extensionWrapper.contentEnd) {
    throw new DirectTlsError("certificate extensions are malformed");
  }

  let basicConstraints: { critical: boolean; ca: boolean } | undefined;
  let keyUsage: { critical: boolean; digitalSignature: boolean; keyEncipherment: boolean } | undefined;
  let serverAuth: boolean | undefined;
  for (const extension of children(der, extensionSequence)) {
    if (extension.tag !== 0x30) throw new DirectTlsError("certificate extension is malformed");
    const fields = children(der, extension);
    const oid = fields[0];
    if (!oid || oid.tag !== 0x06) throw new DirectTlsError("certificate extension OID is missing");
    const isBasic = oidEquals(der, oid, BASIC_CONSTRAINTS_OID);
    const isKeyUsage = oidEquals(der, oid, KEY_USAGE_OID);
    const isEku = oidEquals(der, oid, EXTENDED_KEY_USAGE_OID);
    if (!isBasic && !isKeyUsage && !isEku) continue;
    if ((isBasic && basicConstraints) || (isKeyUsage && keyUsage) || (isEku && serverAuth !== undefined)) {
      throw new DirectTlsError("duplicate certificate extension");
    }
    let index = 1;
    let critical = false;
    if (fields[index]?.tag === 0x01) {
      const boolean = fields[index]!;
      if (boolean.contentEnd - boolean.contentStart !== 1) throw new DirectTlsError("extension critical flag is invalid");
      critical = der[boolean.contentStart] === 0xff;
      index++;
    }
    const value = fields[index];
    if (!value || value.tag !== 0x04 || index !== fields.length - 1) {
      throw new DirectTlsError("certificate extension value is missing");
    }
    const nested = derElement(der, value.contentStart);
    if (nested.end !== value.contentEnd || ((isBasic || isEku) && nested.tag !== 0x30) || (isKeyUsage && nested.tag !== 0x03)) {
      throw new DirectTlsError("certificate extension payload is malformed");
    }
    if (isBasic) {
      let ca = false;
      for (const item of children(der, nested)) {
        if (item.tag !== 0x01) continue;
        if (item.contentEnd - item.contentStart !== 1) throw new DirectTlsError("basic constraints CA flag is invalid");
        ca = der[item.contentStart] !== 0;
      }
      basicConstraints = { critical, ca };
    } else if (isKeyUsage) {
      if (nested.contentEnd - nested.contentStart < 2 || der[nested.contentStart]! > 7) {
        throw new DirectTlsError("keyUsage bit string is invalid");
      }
      const bits = der[nested.contentStart + 1]!;
      keyUsage = {
        critical,
        digitalSignature: (bits & 0x80) !== 0,
        keyEncipherment: (bits & 0x20) !== 0
      };
    } else {
      serverAuth = children(der, nested).some((item) => oidEquals(der, item, SERVER_AUTH_OID));
    }
  }
  if (!basicConstraints?.critical || basicConstraints.ca) {
    throw new DirectTlsError("requires basicConstraints=critical,CA:FALSE");
  }
  if (serverAuth !== true) throw new DirectTlsError("requires serverAuth extended key usage");
  if (!keyUsage?.critical || !keyUsage.digitalSignature || !keyUsage.keyEncipherment) {
    throw new DirectTlsError("requires keyUsage=critical,digitalSignature,keyEncipherment");
  }
  return { basicConstraintsCaFalse: true, serverAuth: true, keyUsageValid: true };
}

async function validatePrivateKeyAncestors(path: string): Promise<void> {
  let current = await realpath(dirname(path));
  const uid = typeof process.getuid === "function" ? process.getuid() : undefined;
  while (true) {
    const stat = await lstat(current);
    if (!stat.isDirectory()) throw new DirectTlsError("private key ancestor must be a real directory");
    if (uid !== undefined && stat.uid !== uid && stat.uid !== 0) {
      throw new DirectTlsError("private key ancestor directory must be owned by the service account or root");
    }
    const writableByOthers = (stat.mode & 0o022) !== 0;
    // A root-owned sticky directory (for example /tmp) still prevents one account
    // from renaming another account's entries and is therefore safe to traverse.
    const protectedStickyDirectory = stat.uid === 0 && (stat.mode & 0o1000) !== 0;
    if (writableByOthers && !protectedStickyDirectory) {
      throw new DirectTlsError("private key ancestor directory must not be writable by other accounts");
    }
    const parent = dirname(current);
    if (parent === current) break;
    current = parent;
  }
}

async function readValidatedPrivateKey(path: string): Promise<string> {
  await validatePrivateKeyAncestors(path);
  let handle;
  try {
    handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  } catch {
    throw new DirectTlsError("private key must be a regular non-symlink file");
  }
  try {
    const keyStat = await handle.stat();
    if (!keyStat.isFile()) throw new DirectTlsError("private key must be a regular non-symlink file");
    if ((keyStat.mode & 0o777) !== 0o600) throw new DirectTlsError("private key permissions must be exactly 0600");
    if (typeof process.getuid === "function" && keyStat.uid !== process.getuid()) {
      throw new DirectTlsError("private key must be owned by the service account");
    }
    return await handle.readFile("utf8");
  } finally {
    await handle.close();
  }
}

function validateSan(certificate: X509Certificate): void {
  const names = certificate.subjectAltName?.split(",").map((entry) => entry.trim()) ?? [];
  if (!names.some((entry) => entry.startsWith("DNS:") || entry.startsWith("IP Address:"))) {
    throw new DirectTlsError("requires at least one DNS or iPAddress SAN");
  }
}

export async function loadDirectTlsIdentity(config: DirectConfig, now = new Date()): Promise<DirectTlsIdentity> {
  if (!config.enabled) throw new DirectTlsError("listener is disabled");
  if (!config.certificateFile || !config.privateKeyFile) {
    throw new DirectTlsError("certificate and private key paths are required");
  }
  try {
    const [certificateText, privateKeyPem] = await Promise.all([
      readFile(config.certificateFile, "utf8"),
      readValidatedPrivateKey(config.privateKeyFile)
    ]);
    const pemBlocks = certificateText.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? [];
    if (pemBlocks.length !== 1) throw new DirectTlsError("certificate file must contain exactly one leaf certificate");
    const certificatePem = `${pemBlocks[0]!}\n`;
    const certificate = new X509Certificate(certificatePem);
    validateCertificateExtensions(certificate.raw);
    validateSan(certificate);
    const notBefore = certificate.validFromDate.getTime();
    const notAfter = certificate.validToDate.getTime();
    if (!Number.isFinite(notBefore) || !Number.isFinite(notAfter) || notAfter <= notBefore) {
      throw new DirectTlsError("certificate validity interval is invalid");
    }
    if (now.getTime() < notBefore) throw new DirectTlsError("certificate is not yet valid");
    if (now.getTime() > notAfter) throw new DirectTlsError("certificate has expired");
    if (certificate.ca || certificate.issuer !== certificate.subject || !certificate.verify(certificate.publicKey)) {
      throw new DirectTlsError("certificate must be a self-signed CA:FALSE leaf");
    }
    const privateKey = createPrivateKey(privateKeyPem);
    if (!certificate.checkPrivateKey(privateKey)) throw new DirectTlsError("certificate and private key do not match");
    return {
      certificatePem,
      privateKeyPem,
      certificateSha256: createHash("sha256").update(certificate.raw).digest("hex"),
      notBefore: certificate.validFromDate.toISOString(),
      notAfter: certificate.validToDate.toISOString()
    };
  } catch (error) {
    if (error instanceof DirectTlsError) throw error;
    throw new DirectTlsError("certificate or private key could not be loaded and validated");
  }
}
