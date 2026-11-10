/**
 * Smoke test for every edge function: the module loads (imports resolve, no crash at start-up)
 * and the CORS preflight answers 2xx with an Access-Control-Allow-Origin header.
 *
 * Functions that import private @digitalvirgo packages need the registry token of their .npmrc,
 * so they are skipped here; deploy bundles them with Docker.
 */
import { assert } from "@std/assert";
import { loadFunction, withFake } from "./harness.ts";

const PRIVATE_PACKAGES = new Set(["bolt-auth-proxy", "pulsar"]);

const functionsDir = new URL("../functions/", import.meta.url);
const names: string[] = [];
for await (const entry of Deno.readDir(functionsDir)) {
  if (!entry.isDirectory || entry.name.startsWith("_")) continue;
  try {
    await Deno.stat(new URL(`${entry.name}/index.ts`, functionsDir));
    names.push(entry.name);
  } catch {
    // not a function folder
  }
}
names.sort();

// Values the functions read from the environment (none of them is called for real).
const ENV = {
  OPENAI_API_KEY: "test",
  APP_JWT_SECRET: "test-secret-test-secret-test-secret-00",
  JWT_SECRET: "test-secret-test-secret-test-secret-00",
  SUPABASE_JWT_SECRET: "test-secret-test-secret-test-secret-00",
};

for (const name of names) {
  Deno.test({
    name: `smoke: ${name} loads and answers the CORS preflight`,
    ignore: PRIVATE_PACKAGES.has(name),
    fn: async () => {
      await withFake(async () => {
        const handler = await loadFunction(name, ENV);
        const res = await handler(new Request(`http://edge.test/${name}`, {
          method: "OPTIONS",
          headers: { Origin: "http://localhost:5173", "Access-Control-Request-Method": "POST" },
        }));
        await res.body?.cancel();
        assert(res.status >= 200 && res.status < 300, `${name}: OPTIONS returned ${res.status}`);
        assert(res.headers.get("Access-Control-Allow-Origin"), `${name}: missing Access-Control-Allow-Origin`);
      });
    },
  });
}
