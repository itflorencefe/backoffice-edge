/**
 * dvlive: proxy to the DV Live voting API. The upstream (STAG base URL) is answered by a
 * FakeSupabase route; app JWTs are really signed with APP_JWT_SECRET.
 */
import { assert, assertEquals } from "@std/assert";
import { create as createJwt } from "jsr:@zaubrik/djwt@3.0.2";
import { normalizeAppClaims } from "../functions/_shared/verify-app-jwt.ts";
import { type FakeSupabase, get, loadFunction, post, readJson, withFake } from "./harness.ts";

const SECRET = "test-secret-test-secret-test-secret-00";
const UPSTREAM = "https://dev-webshow-engine.dv-live.com";
const API_TOKEN = "dvlive-test-token";

const handler = await loadFunction("dvlive", {
  APP_JWT_SECRET: SECRET,
  DVLIVE_ENV: "STAG",
  DVLIVE_API_TOKEN: API_TOKEN,
});

async function appJwt(claims: Record<string, unknown>): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  const now = Math.floor(Date.now() / 1000);
  return await createJwt({ alg: "HS256", typ: "JWT" }, { iat: now, exp: now + 600, ...claims }, key);
}

const USER = { sub: "profile-1", app_role: "app_user", absolute_reference: "abs-ref-42" };
const bearer = async (claims: Record<string, unknown> = USER) => ({ Authorization: `Bearer ${await appJwt(claims)}` });

type Upstream = { method: string; path: string; auth: string | null; body: unknown };

/** Answers DV Live calls with `reply(path)` and records them. */
function upstream(fake: FakeSupabase, reply: (path: string, method: string) => Response): Upstream[] {
  const calls: Upstream[] = [];
  fake.route((req, url) => {
    if (url.origin !== UPSTREAM) return undefined;
    return (async () => {
      const text = req.method === "GET" ? "" : await req.text();
      calls.push({ method: req.method, path: url.pathname, auth: req.headers.get("Authorization"), body: text ? JSON.parse(text) : undefined });
      return reply(url.pathname, req.method);
    })();
  });
  return calls;
}

const jsonRes = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const SHOW = { name: "Show", startDate: "2026-11-01", endDate: "2026-12-01", round: null };

Deno.test("dvlive: without a mode it returns the catalog, with no auth and no upstream call", async () => {
  await withFake(async (fake) => {
    const calls = upstream(fake, () => jsonRes({}));
    const res = await handler(get("dvlive", {}, { Authorization: "" }));
    assertEquals(res.status, 200);
    const body = await readJson(res);
    assertEquals(body.ok, true);
    const data = body.data as { name: string; modes: Record<string, unknown> };
    assertEquals(data.name, "DVLive");
    assertEquals(Object.keys(data.modes).sort(), ["castVote", "createVoter", "getShowVote", "getShowVoteChoice", "getVoter"]);
    assertEquals(calls.length, 0);
  });
});

Deno.test("dvlive: commands need a valid app_user JWT", async () => {
  await withFake(async (fake) => {
    const calls = upstream(fake, () => jsonRes(SHOW));

    const missing = await readJson(await handler(new Request("http://edge.test/dvlive?mode=getShowVote&uuid=s1")));
    assertEquals(missing.error, { message: "Missing bearer token", code: "AUTH_REQUIRED" });

    const forged = await handler(get("dvlive", { mode: "getShowVote", uuid: "s1" }, { Authorization: "Bearer a.b.c" }));
    assertEquals(forged.status, 401);
    assertEquals(((await readJson(forged)).error as { code: string }).code, "AUTH_REQUIRED");

    const notAppUser = await handler(get("dvlive", { mode: "getShowVote", uuid: "s1" }, await bearer({ sub: "u", app_role: "admin" })));
    assertEquals(notAppUser.status, 403);
    assertEquals(((await readJson(notAppUser)).error as { code: string }).code, "FORBIDDEN");

    assertEquals(calls.length, 0);
  });
});

Deno.test("dvlive: getShowVote forwards the server token and wraps the decoded show", async () => {
  await withFake(async (fake) => {
    const calls = upstream(fake, () => jsonRes(SHOW));
    const res = await handler(get("dvlive", { mode: "getShowVote", uuid: "show-1" }, await bearer()));
    assertEquals(res.status, 200);
    const body = await readJson(res);
    assertEquals(body.ok, true);
    assertEquals((body.data as { name: string }).name, "Show");
    assertEquals(calls, [{ method: "GET", path: "/show-vote/show-1", auth: `Bearer ${API_TOKEN}`, body: undefined }]);
  });
});

Deno.test("dvlive: the voter identity always comes from absolute_reference", async () => {
  await withFake(async (fake) => {
    const calls = upstream(fake, (path) =>
      path.endsWith("/vote")
        ? jsonRes({ status: "success", code: 200, message: "ok", nbVoteRemaining: 4 })
        : jsonRes({ status: "success", code: 201, message: "created" })
    );
    const headers = await bearer();

    const created = await handler(post("dvlive?mode=createVoter&showVoteUuid=show-1", { email: "a@b.c", uniqRef: "spoofed" }, headers));
    assertEquals(created.status, 200);
    assertEquals(calls[0].path, "/show-vote/show-1/voter");
    assertEquals((calls[0].body as { uniqRef: string }).uniqRef, "abs-ref-42");

    const voted = await handler(post("dvlive?mode=castVote&showVoteUuid=show-1&userRef=spoofed", { votes: [{ choiceUuid: "c1", nbVotes: 1 }] }, headers));
    assertEquals(voted.status, 200);
    assertEquals(calls[1].path, "/show-vote/show-1/voter/abs-ref-42/vote");
    assertEquals(((await readJson(voted)).data as { nbVoteRemaining: number }).nbVoteRemaining, 4);
  });
});

Deno.test("dvlive: claims nested in app_metadata (local session tokens) are accepted", async () => {
  await withFake(async (fake) => {
    const calls = upstream(fake, () =>
      jsonRes({ uniqRef: "nested-ref", remainingPoints: 3, userFraudStatus: "CLEAN", balance: {} })
    );
    const headers = await bearer({ sub: "profile-2", app_metadata: { app_role: "app_user", absolute_reference: "nested-ref" } });
    const res = await handler(get("dvlive", { mode: "getVoter", showVoteUuid: "show-1" }, headers));
    assertEquals(res.status, 200);
    assertEquals(calls[0].path, "/show-vote/show-1/voter/nested-ref");
  });
});

Deno.test("dvlive: voter commands without absolute_reference are refused", async () => {
  await withFake(async (fake) => {
    const calls = upstream(fake, () => jsonRes({}));
    const res = await handler(get("dvlive", { mode: "getVoter", showVoteUuid: "show-1" }, await bearer({ sub: "u", app_role: "app_user" })));
    assertEquals(res.status, 403);
    assertEquals((await readJson(res)).error, { message: "Missing absolute_reference claim.", code: "FORBIDDEN" });
    assertEquals(calls.length, 0);
  });
});

Deno.test("dvlive: method, content type and body are validated before calling DV Live", async () => {
  await withFake(async (fake) => {
    const calls = upstream(fake, () => jsonRes({}));
    const headers = await bearer();

    const wrongMethod = await handler(get("dvlive", { mode: "castVote", showVoteUuid: "show-1" }, headers));
    assertEquals(wrongMethod.status, 405);
    assertEquals(wrongMethod.headers.get("Allow"), "POST, OPTIONS");

    const notJson = await handler(new Request("http://edge.test/dvlive?mode=castVote&showVoteUuid=show-1", {
      method: "POST", headers: { ...headers, "Content-Type": "text/plain" }, body: "x",
    }));
    assertEquals(notJson.status, 415);

    const noVotes = await handler(post("dvlive?mode=castVote&showVoteUuid=show-1", { votes: [] }, headers));
    assertEquals(noVotes.status, 400);
    assertEquals(((await readJson(noVotes)).error as { code: string }).code, "VALIDATION");

    const noUuid = await handler(get("dvlive", { mode: "getShowVote" }, headers));
    assertEquals(noUuid.status, 400);

    assertEquals(calls.length, 0);
  });
});

Deno.test("dvlive: upstream errors keep their status and JSON details", async () => {
  await withFake(async (fake) => {
    upstream(fake, (path) =>
      path.includes("missing") ? jsonRes({ error: "not found" }, 404) : new Response("not json", { status: 200 })
    );
    const headers = await bearer();

    const notFound = await handler(get("dvlive", { mode: "getShowVote", uuid: "missing" }, headers));
    assertEquals(notFound.status, 404);
    assertEquals((await readJson(notFound)).error, { message: "DV Live upstream error.", code: "UPSTREAM_ERROR", details: { error: "not found" } });

    const garbage = await handler(get("dvlive", { mode: "getShowVote", uuid: "broken" }, headers));
    assertEquals(garbage.status, 502);
    assertEquals(((await readJson(garbage)).error as { code: string }).code, "UPSTREAM_ERROR");
  });
});

Deno.test("verify-app-jwt: normalizeAppClaims reads flat and app_metadata claims", () => {
  const flat = normalizeAppClaims({ sub: "s", app_role: "app_user", absolute_reference: "r", product_id: "p", iat: 1, exp: 2 });
  assertEquals(flat?.absolute_reference, "r");
  assertEquals(flat?.role, "authenticated");
  assertEquals(flat?.product_id, "p");

  const nested = normalizeAppClaims({ sub: "s", app_metadata: { app_role: "app_user", service_slug: "svc" } });
  assertEquals(nested?.service_slug, "svc");
  assertEquals(nested?.absolute_reference, "");

  // Top-level claims win over app_metadata.
  assertEquals(normalizeAppClaims({ sub: "s", app_role: "app_user", product_slug: "top", app_metadata: { product_slug: "meta" } })?.product_slug, "top");

  assertEquals(normalizeAppClaims({ sub: "s", app_role: "admin" }), null);
  assertEquals(normalizeAppClaims({ app_role: "app_user" }), null);
  assert(normalizeAppClaims({ sub: "s", app_metadata: { app_role: "app_user" } }));
});
