import { assertEquals, assertMatch } from "@std/assert";
import { loadFunction, post, readJson, withFake } from "./harness.ts";

const handler = await loadFunction("create-first-user");

Deno.test("create-first-user: OPTIONS and method checks", async () => {
  const options = await handler(new Request("http://edge.test/create-first-user", { method: "OPTIONS" }));
  assertEquals(options.status, 200);
  assertEquals(options.headers.get("Access-Control-Allow-Origin"), "*");
  const getRes = await handler(new Request("http://edge.test/create-first-user", { method: "GET" }));
  assertEquals(getRes.status, 405);
});

Deno.test("create-first-user: creates the first admin in Auth and bo_backoffice_users", async () => {
  await withFake(async (fake) => {
    const res = await handler(post("create-first-user", { email: " Admin@Example.com ", password: "secret123", display_name: "Ada" }));
    assertEquals(res.status, 200);
    const body = await readJson(res);
    assertEquals(body.ok, true);
    assertEquals(fake.authUsers.map((u) => u.email), ["admin@example.com"]);
    const [row] = fake.rows("backoffice.bo_backoffice_users");
    assertEquals(
      { user_id: row.user_id, email: row.email, display_name: row.display_name, role: row.role, is_active: row.is_active },
      { user_id: fake.authUsers[0].id, email: "admin@example.com", display_name: "Ada", role: "admin", is_active: true },
    );
    assertMatch(String(body.message), /admin@example\.com/);
  });
});

Deno.test("create-first-user: display name falls back to first_name, then the email local part", async () => {
  await withFake(async (fake) => {
    await handler(post("create-first-user", { email: "a@b.co", password: "x", data: { first_name: "Bob" } }));
    assertEquals(fake.rows("backoffice.bo_backoffice_users")[0].display_name, "Bob");
  });
  await withFake(async (fake) => {
    await handler(post("create-first-user", { email: "carol@b.co", password: "x" }));
    assertEquals(fake.rows("backoffice.bo_backoffice_users")[0].display_name, "carol");
  });
});

Deno.test("create-first-user: an existing user blocks the bootstrap and names the oldest admin", async () => {
  await withFake(async (fake) => {
    fake.seed("backoffice.bo_backoffice_users", [
      { id: "1", user_id: "u1", email: "editor@example.com", role: "editor", created_at: "2026-01-01" },
      { id: "2", user_id: "u2", email: "late-admin@example.com", role: "admin", created_at: "2026-03-01" },
      { id: "3", user_id: "u3", email: "first-admin@example.com", role: "admin", created_at: "2026-02-01" },
    ]);
    const res = await handler(post("create-first-user", { email: "new@example.com", password: "secret" }));
    assertEquals(res.status, 409);
    const body = await readJson(res);
    assertEquals(body.code, "ADMIN_EXISTS");
    assertEquals(body.existing_email, "first-admin@example.com");
    assertMatch(String(body.error), /first-admin@example\.com/);
    assertEquals(fake.authUsers.length, 0);
  });
});

Deno.test("create-first-user: without admins the oldest user is reported", async () => {
  await withFake(async (fake) => {
    fake.seed("backoffice.bo_backoffice_users", [
      { id: "1", user_id: "u1", email: "viewer@example.com", role: "viewer", created_at: "2026-01-01" },
    ]);
    const body = await readJson(await handler(post("create-first-user", undefined)));
    assertEquals(body.existing_email, "viewer@example.com");
  });
});

Deno.test("create-first-user: body validation", async () => {
  await withFake(async (fake) => {
    const bad = await handler(post("create-first-user", "not json"));
    assertEquals(bad.status, 400);
    assertEquals(await bad.json(), { ok: false, error: "Invalid JSON body" });
    const missing = await handler(post("create-first-user", { email: "a@b.co" }));
    assertEquals(missing.status, 400);
    assertEquals(await missing.json(), { ok: false, error: "email and password are required" });
    assertEquals(fake.authUsers.length, 0);
  });
});

Deno.test("create-first-user: Auth errors are returned as 400", async () => {
  await withFake(async (fake) => {
    fake.addAuthUser({ id: "x", email: "taken@example.com" });
    const res = await handler(post("create-first-user", { email: "taken@example.com", password: "secret" }));
    assertEquals(res.status, 400);
    assertMatch(String((await readJson(res)).error), /already been registered/);
  });
});

Deno.test("create-first-user: a failed backoffice insert deletes the Auth user again", async () => {
  await withFake(async (fake) => {
    fake.fail("backoffice.bo_backoffice_users", "POST", "insert refused");
    const res = await handler(post("create-first-user", { email: "a@b.co", password: "secret" }));
    assertEquals(res.status, 500);
    assertMatch(String((await readJson(res)).error), /insert refused/);
    assertEquals(fake.authUsers.length, 0);
  });
});

Deno.test("create-first-user: unreadable bo_backoffice_users asks to run migrations", async () => {
  await withFake(async (fake) => {
    fake.fail("backoffice.bo_backoffice_users", "GET", "relation does not exist");
    const res = await handler(post("create-first-user", { email: "a@b.co", password: "secret" }));
    assertEquals(res.status, 500);
    assertMatch(String((await readJson(res)).error), /Run migrations first/);
  });
});
