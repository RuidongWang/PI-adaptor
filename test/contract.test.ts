import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

type FixtureGroups = {
  requests: Array<{ method: string }>;
  responses: unknown[];
  notifications: unknown[];
  errors: unknown[];
  events: unknown[];
  invalid: unknown[];
};

type Schema = {
  $schema?: string;
  $defs: {
    request: {
      oneOf: Array<{
        properties: {
          method: { const: string };
          params: { $ref: string };
        };
      }>;
    };
    successResponse: {
      properties: {
        result: unknown;
      };
      [key: string]: unknown;
    };
    [key: string]: unknown;
  };
};

const schemaURL = new URL("../docs/api/pi-adaptor.schema.json", import.meta.url);
const goldenURL = new URL("../docs/api/pi-adaptor.golden.json", import.meta.url);
const require = createRequire(import.meta.url);
const Ajv2020 = require("ajv/dist/2020") as new (options?: object) => {
  compile(schema: object): ((value: unknown) => boolean) & { errors?: unknown[] };
};
const addFormats = require("ajv-formats") as (ajv: object) => void;

/** Method → `$defs/result_*` name, derived from the request's params `$ref` (no naming guesswork). */
function resultDefinitionFor(entry: Schema["$defs"]["request"]["oneOf"][number]): string {
  const paramsRef = entry.properties.params.$ref;
  const paramsName = paramsRef.slice(paramsRef.lastIndexOf("/") + 1);
  return `result_${paramsName.replace(/^params_/, "")}`;
}

/**
 * The schema's `successResponse.result` is a plain `anyOf` over every result type, so a
 * response can validate even when its result belongs to a different method. Compile a
 * per-method copy that only accepts that method's result definition.
 */
function compileResponseForMethod(schema: Schema, resultDefinition: string) {
  const copy = JSON.parse(JSON.stringify(schema)) as Schema;
  copy.$defs.successResponse = {
    ...copy.$defs.successResponse,
    properties: {
      ...copy.$defs.successResponse.properties,
      result: { $ref: `#/$defs/${resultDefinition}` },
    },
  };
  const ajv = new Ajv2020({ strict: true, allErrors: true });
  addFormats(ajv);
  return ajv.compile({
    $schema: copy.$schema,
    $ref: "#/$defs/successResponse",
    $defs: copy.$defs,
  });
}

describe("pi-adaptor contract", () => {
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
      for (const [index, fixture] of (fixtures as unknown[]).entries()) {
        const valid = validate(fixture);
        expect(valid, `${group}[${index}] ${JSON.stringify(validate.errors)}`).toBe(true);
      }
    }
    for (const [index, fixture] of golden.invalid.entries()) {
      expect(validate(fixture), `invalid[${index}] unexpectedly passed`).toBe(false);
    }
  });

  it("has exactly one request and one matching result fixture for every method", async () => {
    const schema = JSON.parse(await readFile(fileURLToPath(schemaURL), "utf8")) as Schema;
    const golden = JSON.parse(
      await readFile(fileURLToPath(goldenURL), "utf8")
    ) as FixtureGroups;

    const entries = schema.$defs.request.oneOf;
    const schemaMethods = entries.map((entry) => entry.properties.method.const);
    const goldenMethods = golden.requests.map((request) => request.method);

    // Duplicate or missing methods must fail: equal totals alone cannot catch them.
    expect(new Set(schemaMethods).size).toBe(schemaMethods.length);
    expect(new Set(goldenMethods).size).toBe(goldenMethods.length);
    expect(goldenMethods.slice().sort()).toEqual(schemaMethods.slice().sort());
    expect(golden.responses).toHaveLength(schemaMethods.length);

    // Pair each request with the response in the same slot, then require the result to be
    // the one defined for that method (the generic successResponse accepts any result type).
    for (const [index, entry] of entries.entries()) {
      const method = entry.properties.method.const;
      const resultDefinition = resultDefinitionFor(entry);
      expect(schema.$defs[resultDefinition], `${method} 缺少 ${resultDefinition}`).toBeDefined();
      const validateResponse = compileResponseForMethod(schema, resultDefinition);
      const response = golden.responses[index];
      expect(
        validateResponse(response),
        `${method} 的 response[${index}] 不是该方法的 result：${JSON.stringify(validateResponse.errors)}`
      ).toBe(true);
    }
  });
});
