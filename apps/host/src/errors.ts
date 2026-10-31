export const ERROR_NUMBERS = {
  INTERNAL: -32000,
  UNAUTHORIZED: -32001,
  FORBIDDEN: -32002,
  PROTOCOL_MISMATCH: -32003,
  INVALID_ARGUMENT: -32004,
  NOT_FOUND: -32005,
  CONFLICT: -32006,
  IDEMPOTENCY_CONFLICT: -32007,
  CURSOR_EXPIRED: -32008,
  CLIENT_TOO_SLOW: -32009,
  PAYLOAD_TOO_LARGE: -32010,
  APPROVAL_EXPIRED: -32011,
  APPROVAL_STALE: -32012,
  SESSION_BUSY: -32013,
  SESSION_READ_ONLY: -32014,
  PROVIDER_NOT_CONFIGURED: -32015,
  PROVIDER_SECRET_MISSING: -32016,
  PROVIDER_IN_USE: -32017,
  SKILL_SOURCE_UNAVAILABLE: -32018,
  SKILL_CONFLICT: -32019,
  ATTACHMENT_INVALID: -32020,
  ATTACHMENT_INCOMPLETE: -32021,
  AGENT_RESTARTED: -32022,
  DEVICE_NOT_FOUND: -32023,
  RATE_LIMITED: -32024,
  PAIRING_FAILED: -32025,
  PAIRING_TOKEN_EXPIRED: -32026
} as const;

export type ErrorCode = keyof typeof ERROR_NUMBERS;

export class HostError extends Error {
  readonly code: ErrorCode;
  readonly data: Record<string, unknown> | undefined;

  constructor(code: ErrorCode, message?: string, data?: Record<string, unknown>) {
    super(message ?? code);
    this.name = "HostError";
    this.code = code;
    this.data = data;
  }

  toJSONRPC(id: string | number | null): {
    jsonrpc: "2.0";
    id: string | number | null;
    error: { code: number; message: string; data?: Record<string, unknown> };
  } {
    const numeric = ERROR_NUMBERS[this.code];
    const data = this.data ? { ...this.data, code: this.code } : { code: this.code };
    return {
      jsonrpc: "2.0",
      id,
      error: { code: numeric, message: this.message, data }
    };
  }
}

export function asHostError(error: unknown): HostError {
  if (error instanceof HostError) return error;
  if (error instanceof Error) return new HostError("INTERNAL", error.message);
  return new HostError("INTERNAL", String(error));
}
