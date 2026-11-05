/**
 * Test harness for the edge functions.
 *
 * - `loadFunction(name)` imports supabase/functions/<name>/index.ts with Deno.serve stubbed and
 *   returns the request handler, so tests call it directly (no server, no port).
 * - `FakeSupabase` answers the HTTP calls supabase-js makes (PostgREST /rest/v1 and Auth
 *   /auth/v1) from in-memory tables. Every outgoing fetch goes through it: a request it does not
 *   know fails the test instead of reaching the network.
 *
 * The PostgREST fake covers what the functions use: select projection (embedded resources are
 * returned when the seeded row already holds them under that name), eq / neq / in / is / gt /
 * gte / lt / lte / like / ilike filters, `or=(...)` of simple filters, order, limit, single /
 * maybeSingle, exact counts, insert, update and delete. Tables that were never seeded are empty.
 */

export const SUPABASE_URL = "http://supabase.test";
export const SERVICE_ROLE_KEY = "test-service-role-key";
export const ANON_KEY = "test-anon-key";

type Row = Record<string, unknown>;
type Handler = (req: Request) => Response | Promise<Response>;
type Route = (req: Request, url: URL) => Response | Promise<Response> | undefined;

export interface AuthUser {
  id: string;
  email: string;
  token?: string;
}

export interface RecordedRequest {
  method: string;
  path: string;
  search: string;
  body: unknown;
}

// ---------------------------------------------------------------------------
// Deno.serve stub and function loader
// ---------------------------------------------------------------------------

let captured: Handler | null = null;
const loaded = new Map<string, Handler>();

(Deno as unknown as { serve: unknown }).serve = (a: unknown, b?: unknown) => {
  captured = (typeof a === "function" ? a : b) as Handler;
  return { finished: Promise.resolve(), shutdown: () => Promise.resolve(), ref() {}, unref() {}, addr: {} };
};

const BASE_ENV: Record<string, string> = {
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY: SERVICE_ROLE_KEY,
  SUPABASE_ANON_KEY: ANON_KEY,
};

/** Imports a function once (module state is shared across the tests of a file) and returns its handler. */
export async function loadFunction(name: string, env: Record<string, string> = {}): Promise<Handler> {
  for (const [k, v] of Object.entries({ ...BASE_ENV, ...env })) Deno.env.set(k, v);
  const cached = loaded.get(name);
  if (cached) return cached;
  captured = null;
  await import(new URL(`../functions/${name}/index.ts`, import.meta.url).href);
  if (!captured) throw new Error(`${name} did not call Deno.serve`);
  loaded.set(name, captured);
  return captured;
}

// ---------------------------------------------------------------------------
// fetch dispatcher
// ---------------------------------------------------------------------------

let active: FakeSupabase | null = null;
const activate = (fake: FakeSupabase | null) => {
  active = fake;
};
const realFetch = globalThis.fetch;

globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
  const req = input instanceof Request ? new Request(input, init) : new Request(String(input), init);
  if (!active) throw new Error(`Unexpected fetch outside a FakeSupabase test: ${req.method} ${req.url}`);
  return await active.handle(req);
};

/** Restores the real fetch (only for tests that really need the network: none should). */
export function useRealFetch() {
  globalThis.fetch = realFetch;
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

function splitTopLevel(input: string, sep = ","): string[] {
  const out: string[] = [];
  let depth = 0;
  let quoted = false;
  let cur = "";
  for (const ch of input) {
    if (ch === '"') quoted = !quoted;
    if (!quoted && ch === "(") depth++;
    if (!quoted && ch === ")") depth--;
    if (!quoted && depth === 0 && ch === sep) {
      out.push(cur);
      cur = "";
    } else {
      cur += ch;
    }
  }
  if (cur) out.push(cur);
  return out;
}

const unquote = (v: string) => v.replace(/^"(.*)"$/, "$1");

function likeToRegExp(pattern: string, flags: string): RegExp {
  const escaped = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/[*%]/g, ".*");
  return new RegExp(`^${escaped}$`, flags);
}

function matches(row: Row, column: string, expr: string): boolean {
  const negate = expr.startsWith("not.");
  const body = negate ? expr.slice(4) : expr;
  const dot = body.indexOf(".");
  const op = body.slice(0, dot);
  const raw = body.slice(dot + 1);
  const value = row[column];
  let ok: boolean;
  switch (op) {
    case "eq":
      ok = value !== null && value !== undefined && String(value) === unquote(raw);
      break;
    case "neq":
      ok = value === null || value === undefined || String(value) !== unquote(raw);
      break;
    case "in": {
      const list = splitTopLevel(raw.replace(/^\((.*)\)$/, "$1")).map(unquote);
      ok = value !== null && value !== undefined && list.includes(String(value));
      break;
    }
    case "is":
      ok = raw === "null" ? value === null || value === undefined : String(value) === raw;
      break;
    case "gt":
      ok = value !== null && value !== undefined && String(value) > raw;
      break;
    case "gte":
      ok = value !== null && value !== undefined && String(value) >= raw;
      break;
    case "lt":
      ok = value !== null && value !== undefined && String(value) < raw;
      break;
    case "lte":
      ok = value !== null && value !== undefined && String(value) <= raw;
      break;
    case "like":
      ok = typeof value === "string" && likeToRegExp(raw, "").test(value);
      break;
    case "ilike":
      ok = typeof value === "string" && likeToRegExp(raw, "i").test(value);
      break;
    default:
      throw new Error(`FakeSupabase: unsupported filter operator '${op}' on ${column}`);
  }
  return negate ? !ok : ok;
}

/** `(a.eq.1,b.is.null)` -> true when any condition holds. */
function matchesOr(row: Row, expr: string): boolean {
  return splitTopLevel(expr.replace(/^\((.*)\)$/, "$1")).some((cond) => {
    const dot = cond.indexOf(".");
    return matches(row, cond.slice(0, dot), cond.slice(dot + 1));
  });
}

const RESERVED = new Set(["select", "order", "limit", "offset", "on_conflict", "columns"]);

function filterRows(rows: Row[], params: URLSearchParams): Row[] {
  return rows.filter((row) => {
    for (const [key, expr] of params) {
      if (RESERVED.has(key)) continue;
      if (key === "or") {
        if (!matchesOr(row, expr)) return false;
      } else if (key === "and") {
        const conds = splitTopLevel(expr.replace(/^\((.*)\)$/, "$1"));
        for (const cond of conds) {
          const dot = cond.indexOf(".");
          if (!matches(row, cond.slice(0, dot), cond.slice(dot + 1))) return false;
        }
      } else if (!matches(row, key, expr)) {
        return false;
      }
    }
    return true;
  });
}

function orderRows(rows: Row[], order: string | null): Row[] {
  if (!order) return rows;
  const keys = order.split(",").map((part) => {
    const [column, ...mods] = part.split(".");
    return { column, desc: mods.includes("desc") };
  });
  return [...rows].sort((a, b) => {
    for (const { column, desc } of keys) {
      const av = a[column];
      const bv = b[column];
      if (av === bv) continue;
      if (av === null || av === undefined) return 1;
      if (bv === null || bv === undefined) return -1;
      const cmp = typeof av === "number" && typeof bv === "number"
        ? av - bv
        : typeof av === "boolean" && typeof bv === "boolean"
        ? Number(av) - Number(bv)
        : String(av).localeCompare(String(bv));
      if (cmp !== 0) return desc ? -cmp : cmp;
    }
    return 0;
  });
}

/** Keeps the selected columns; `alias:table(...)` / `table(...)` keep the seeded value under that name. */
function project(row: Row, select: string | null): Row {
  if (!select || select === "*") return { ...row };
  const out: Row = {};
  for (const item of splitTopLevel(select.replace(/\s+/g, ""))) {
    if (item === "*") {
      Object.assign(out, row);
      continue;
    }
    const embed = item.match(/^(?:([A-Za-z0-9_]+):)?([A-Za-z0-9_]+)(?:![A-Za-z0-9_]+)*\(.*\)$/);
    if (embed) {
      const name = embed[1] ?? embed[2];
      out[name] = row[name] ?? null;
      continue;
    }
    const [alias, column] = item.includes(":") ? item.split(":") : [item, item];
    out[alias] = row[column] ?? null;
  }
  return out;
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

// ---------------------------------------------------------------------------
// FakeSupabase
// ---------------------------------------------------------------------------

export class FakeSupabase {
  /** Tables keyed by `schema.table`; tables never seeded behave as empty. */
  readonly tables = new Map<string, Row[]>();
  readonly requests: RecordedRequest[] = [];
  readonly authUsers: AuthUser[] = [];
  private routes: Route[] = [];
  /** Per-table errors returned instead of data, e.g. `fail("backoffice.bo_products", "GET")`. */
  private failures = new Map<string, string>();

  constructor() {
    activate(this);
  }

  /** Stops routing fetches to this fake. Call at the end of each test (or use `withFake`). */
  close() {
    if (active === this) activate(null);
  }

  seed(table: string, rows: Row[]): this {
    const key = table.includes(".") ? table : `public.${table}`;
    this.tables.set(key, rows.map((r) => ({ ...r })));
    return this;
  }

  rows(table: string): Row[] {
    const key = table.includes(".") ? table : `public.${table}`;
    return this.tables.get(key) ?? [];
  }

  /** Makes every `method` request on `table` answer with a PostgREST error. */
  fail(table: string, method = "GET", message = "simulated failure"): this {
    this.failures.set(`${method} ${table}`, message);
    return this;
  }

  /** Extra handler for non-Supabase URLs (or to override a Supabase endpoint). */
  route(route: Route): this {
    this.routes.push(route);
    return this;
  }

  addAuthUser(user: AuthUser): this {
    this.authUsers.push(user);
    return this;
  }

  async handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const text = req.method === "GET" || req.method === "HEAD" ? "" : await req.clone().text();
    let body: unknown = null;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = text;
    }
    this.requests.push({ method: req.method, path: url.pathname, search: url.search, body });

    for (const route of this.routes) {
      const res = await route(req, url);
      if (res) return res;
    }
    if (url.origin === SUPABASE_URL && url.pathname.startsWith("/rest/v1/")) return this.rest(req, url, body);
    if (url.origin === SUPABASE_URL && url.pathname.startsWith("/auth/v1/")) return this.auth(req, url, body);
    throw new Error(`FakeSupabase: unexpected request ${req.method} ${req.url}`);
  }

  private rest(req: Request, url: URL, body: unknown): Response {
    const table = url.pathname.slice("/rest/v1/".length);
    const schema = req.headers.get("Accept-Profile") ?? req.headers.get("Content-Profile") ?? "public";
    const key = `${schema}.${table}`;
    const failure = this.failures.get(`${req.method} ${key}`);
    if (failure) return json({ code: "XX000", message: failure, details: null, hint: null }, 400);

    if (table.startsWith("rpc/")) throw new Error(`FakeSupabase: unexpected RPC ${table}`);
    const params = url.searchParams;
    const select = params.get("select");
    const prefer = req.headers.get("Prefer") ?? "";
    const wantsObject = (req.headers.get("Accept") ?? "").includes("vnd.pgrst.object");
    const all = this.tables.get(key) ?? [];

    const respond = (rows: Row[], total: number, status = 200): Response => {
      const headers: Record<string, string> = {};
      if (prefer.includes("count=")) headers["Content-Range"] = `0-${Math.max(rows.length - 1, 0)}/${total}`;
      if (req.method === "HEAD") return new Response(null, { status, headers });
      if (wantsObject) {
        if (rows.length !== 1) {
          return json({
            code: "PGRST116",
            message: "JSON object requested, multiple (or no) rows returned",
            details: `The result contains ${rows.length} rows`,
            hint: null,
          }, 406);
        }
        return json(rows[0], status, headers);
      }
      return json(rows, status, headers);
    };

    if (req.method === "GET" || req.method === "HEAD") {
      let rows = orderRows(filterRows(all, params), params.get("order"));
      const total = rows.length;
      const offset = Number(params.get("offset") ?? 0);
      const limit = params.get("limit");
      rows = rows.slice(offset, limit ? offset + Number(limit) : undefined);
      return respond(rows.map((r) => project(r, select)), total);
    }

    if (req.method === "POST") {
      const input = (Array.isArray(body) ? body : [body]) as Row[];
      const now = new Date().toISOString();
      const inserted = input.map((r) => ({ id: crypto.randomUUID(), created_at: now, updated_at: now, ...r }));
      this.tables.set(key, [...all, ...inserted]);
      if (!prefer.includes("return=representation")) return new Response(null, { status: 201 });
      return respond(inserted.map((r) => project(r, select)), inserted.length, 201);
    }

    if (req.method === "PATCH") {
      const hit = new Set(filterRows(all, params));
      const updated: Row[] = [];
      this.tables.set(key, all.map((r) => {
        if (!hit.has(r)) return r;
        const next = { ...r, ...(body as Row) };
        updated.push(next);
        return next;
      }));
      if (!prefer.includes("return=representation")) return new Response(null, { status: 204 });
      return respond(updated.map((r) => project(r, select)), updated.length);
    }

    if (req.method === "DELETE") {
      const hit = new Set(filterRows(all, params));
      this.tables.set(key, all.filter((r) => !hit.has(r)));
      if (!prefer.includes("return=representation")) return new Response(null, { status: 204 });
      return respond([...hit].map((r) => project(r, select)), hit.size);
    }

    throw new Error(`FakeSupabase: unsupported ${req.method} ${url.pathname}`);
  }

  private auth(req: Request, url: URL, body: unknown): Response {
    const path = url.pathname.slice("/auth/v1".length);
    if (req.method === "GET" && path === "/user") {
      const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
      const user = this.authUsers.find((u) => u.token && u.token === token);
      if (!user) return json({ code: 401, error_code: "bad_jwt", msg: "invalid JWT" }, 401);
      return json({ id: user.id, email: user.email, aud: "authenticated", role: "authenticated" });
    }
    if (req.method === "POST" && path === "/admin/users") {
      const { email } = body as { email: string };
      if (this.authUsers.some((u) => u.email === email)) {
        return json({ code: 422, error_code: "email_exists", msg: "A user with this email address has already been registered" }, 422);
      }
      const user = { id: crypto.randomUUID(), email };
      this.authUsers.push(user);
      return json({ ...user, aud: "authenticated", role: "authenticated" });
    }
    const del = path.match(/^\/admin\/users\/([^/]+)$/);
    if (req.method === "DELETE" && del) {
      const i = this.authUsers.findIndex((u) => u.id === del[1]);
      if (i >= 0) this.authUsers.splice(i, 1);
      return json({});
    }
    throw new Error(`FakeSupabase: unexpected auth request ${req.method} ${path}`);
  }
}

/** Runs `fn` with a fresh FakeSupabase and always detaches it afterwards. */
export async function withFake<T>(fn: (fake: FakeSupabase) => Promise<T>): Promise<T> {
  const fake = new FakeSupabase();
  try {
    return await fn(fake);
  } finally {
    fake.close();
  }
}

// ---------------------------------------------------------------------------
// Request helpers
// ---------------------------------------------------------------------------

export function get(path: string, params: Record<string, string> = {}, headers: Record<string, string> = {}): Request {
  const url = new URL(`http://edge.test/${path}`);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  return new Request(url, { method: "GET", headers: { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}`, ...headers } });
}

export function post(path: string, body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`http://edge.test/${path}`, {
    method: "POST",
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}`, "Content-Type": "application/json", ...headers },
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
}

export async function readJson(res: Response): Promise<Record<string, unknown>> {
  return await res.json() as Record<string, unknown>;
}
