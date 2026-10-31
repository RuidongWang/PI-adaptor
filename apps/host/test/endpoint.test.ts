import { describe, expect, it } from "vitest";
import { assertPublicHttpsEndpoint } from "../src/security/endpoint.js";

describe("endpoint policy", () => {
  it("rejects loopback and non-https endpoints", async () => {
    await expect(assertPublicHttpsEndpoint("http://example.com")).rejects.toMatchObject({
      code: "INVALID_ARGUMENT"
    });
    await expect(assertPublicHttpsEndpoint("https://127.0.0.1/v1")).rejects.toMatchObject({
      code: "INVALID_ARGUMENT"
    });
    await expect(
      assertPublicHttpsEndpoint("https://127.0.0.1/v1", { allowPrivateHosts: true })
    ).resolves.toBeInstanceOf(URL);
  });
});
