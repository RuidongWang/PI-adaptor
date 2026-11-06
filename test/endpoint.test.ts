import { describe, expect, it } from "vitest";
import { assertPublicHttpsEndpoint } from "../src/security/endpoint.js";

describe("endpoint policy", () => {
  it("rejects non-https endpoints for non-loopback hosts", async () => {
    await expect(assertPublicHttpsEndpoint("http://example.com")).rejects.toMatchObject({
      code: "INVALID_ARGUMENT"
    });
    await expect(assertPublicHttpsEndpoint("https://10.0.0.1/v1")).rejects.toMatchObject({
      code: "INVALID_ARGUMENT"
    });
  });

  it("allows the loopback model gateway over http and https", async () => {
    for (const raw of [
      "http://localhost:8080",
      "http://127.0.0.1:8080",
      "https://127.0.0.1/v1",
      "http://[::1]:8080"
    ]) {
      await expect(assertPublicHttpsEndpoint(raw)).resolves.toBeInstanceOf(URL);
    }
  });

  it("still honours the explicit private-host policy", async () => {
    await expect(
      assertPublicHttpsEndpoint("https://127.0.0.1/v1", { allowPrivateHosts: true })
    ).resolves.toBeInstanceOf(URL);
  });
});
