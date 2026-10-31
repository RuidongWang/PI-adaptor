import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

type FixtureGroups = {
  requests: unknown[];
  responses: unknown[];
  notifications: unknown[];
  errors: unknown[];
  events: unknown[];
  invalid: unknown[];
};

const schemaURL = new URL("../../../docs/api/pi-host-v2.schema.json", import.meta.url);
const goldenURL = new URL("../../../docs/api/pi-host-v2.golden.json", import.meta.url);
const require = createRequire(import.meta.url);
const Ajv2020 = require("ajv/dist/2020") as new (options?: object) => {
  compile(schema: object): ((value: unknown) => boolean) & { errors?: unknown[] };
};
const addFormats = require("ajv-formats") as (ajv: object) => void;

describe("pi-host-v2 contract", () => {
  it("validates every golden request, response, and notification", async () => {
    const schema = JSON.parse(await readFile(fileURLToPath(schemaURL), "utf8")) as object;
    const golden = JSON.parse(
      await readFile(fileURLToPath(goldenURL), "utf8")
    ) as FixtureGroups;

    const ajv = new Ajv2020({ strict: true, allErrors: true });
    addFormats(ajv);
    const validate = ajv.compile(schema);

    for (const [group, fixtures] of Object.entries(golden)) {
      if (group === "invalid") {
        continue;
      }
      for (const [index, fixture] of fixtures.entries()) {
        const valid = validate(fixture);
        expect(valid, `${group}[${index}] ${JSON.stringify(validate.errors)}`).toBe(true);
      }
    }
    for (const [index, fixture] of golden.invalid.entries()) {
      expect(validate(fixture), `invalid[${index}] unexpectedly passed`).toBe(false);
    }
  });

  it("contains one schema request and one result fixture for every method", async () => {
    const schema = JSON.parse(await readFile(fileURLToPath(schemaURL), "utf8")) as {
      $defs: {
        request: {
          oneOf: Array<{
            properties: {
              method: { const: string };
            };
          }>;
        };
      };
    };
    const golden = JSON.parse(
      await readFile(fileURLToPath(goldenURL), "utf8")
    ) as FixtureGroups;

    const methods = schema.$defs.request.oneOf.map((entry) => entry.properties.method.const);
    expect(new Set(methods).size).toBe(methods.length);
    expect(golden.requests).toHaveLength(methods.length);
    expect(golden.responses).toHaveLength(methods.length);
  });
});
