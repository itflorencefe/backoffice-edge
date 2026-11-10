# Edge function tests

Unit tests for `supabase/functions`, run with Deno before every commit (`.githooks/pre-commit`) and on GitHub for every pull request (`.github/workflows/tests.yml`, check "Edge function tests", required to merge into `main`).

```bash
npm test                 # same as npm run test:functions
deno test --config supabase/tests/deno.json --allow-env --allow-read supabase/tests/screen-layout_test.ts
```

The hook is enabled by `npm install` (`prepare` sets `core.hooksPath` to `.githooks`). Skip it once with `git commit --no-verify`.

## How they work

`harness.ts`:

- `loadFunction(name)` imports `supabase/functions/<name>/index.ts` with `Deno.serve` stubbed and returns its handler, so a test calls `handler(request)` directly.
- `withFake(async (fake) => …)` routes every `fetch` to an in-memory Supabase: PostgREST tables (`fake.seed("backoffice.bo_products", rows)`, `fake.rows(...)`) and Auth admin (`fake.addAuthUser(...)`). A request the fake does not handle fails the test, so nothing reaches the network or the real project.
- `fake.fail(table, method)` makes a table answer with an error, to test error paths.
- `get(path, params)` / `post(path, body)` build requests with the anon key headers.

`smoke_test.ts` loads every function and checks the CORS preflight. Functions that import private `@digitalvirgo` packages (`bolt-auth-proxy`, `pulsar`) are skipped; `atom` runs against `stubs/atom-api.ts`.

New test files must end in `_test.ts`.
