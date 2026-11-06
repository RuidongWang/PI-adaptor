import { describe, expect, it } from "vitest";
import { PROVIDER_APIS, isSupportedProviderProtocol, providerApi } from "../src/providers/protocol.js";
import { fallbackSessionTitle, sanitizeSessionTitle } from "../src/server/host-service.js";

describe("provider protocol mapping", () => {
  it("covers exactly the four supported wire protocols", () => {
    expect([...PROVIDER_APIS]).toEqual([
      "openai-completions",
      "openai-responses",
      "anthropic-messages",
      "google-generative-ai"
    ]);
  });

  it("maps every supported protocol to itself and falls back to chat completions", () => {
    for (const api of PROVIDER_APIS) {
      expect(providerApi(api)).toBe(api);
      expect(isSupportedProviderProtocol(api)).toBe(true);
    }
    expect(providerApi(undefined)).toBe("openai-completions");
    expect(providerApi("")).toBe("openai-completions");
    expect(providerApi("openai_compatible")).toBe("openai-completions");
    expect(isSupportedProviderProtocol("ollama")).toBe(false);
  });
});

describe("session title generation helpers", () => {
  it("strips quotes, punctuation, and whitespace", () => {
    expect(sanitizeSessionTitle('  “修复登录超时。”\n')).toBe("修复登录超时");
    expect(sanitizeSessionTitle("Fix   the   login\nflow")).toBe("Fix the login flow");
    expect(sanitizeSessionTitle("   ")).toBeUndefined();
    expect(sanitizeSessionTitle(undefined)).toBeUndefined();
  });

  it("caps long titles", () => {
    const title = sanitizeSessionTitle("a".repeat(80));
    expect(title?.endsWith("…")).toBe(true);
    expect(title?.length).toBe(41);
  });

  it("falls back to the first instruction line when the model returns nothing", () => {
    expect(fallbackSessionTitle("帮我检查磁盘使用率\n第二行不要")).toBe("帮我检查磁盘使用率");
    expect(fallbackSessionTitle("")).toBe("New session");
    expect(fallbackSessionTitle("x".repeat(40))).toBe(`${"x".repeat(24)}…`);
  });
});
