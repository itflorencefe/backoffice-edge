import { JsonApiService } from "@digitalvirgo/atom-api";
export { JsonApiHttpError } from "@digitalvirgo/atom-api";

export interface AtomConfig {
  baseUrl: string;
  user: string;
  pass: string;
}

function getAtomConfig(): AtomConfig {
  const baseUrl = (Deno.env.get("ATOM_BASE_URL") ??
    "https://atom.digitalvirgo.com").replace(/\/+$/, "");
  const user = Deno.env.get("ATOM_USER") ?? "";
  const pass = Deno.env.get("ATOM_SDK_ACCESS_KEY") ?? "";
  return { baseUrl, user, pass };
}

async function atomLogin(
  baseUrl: string,
  user: string,
  pass: string,
): Promise<string> {
  const credentials = btoa(`${user}:${pass}`);
  const res = await fetch(`${baseUrl}/auth/token`, {
    method: "GET",
    headers: {
      Accept: "application/vnd.api+json",
      Authorization: `Basic ${credentials}`,
    },
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const detail = (data as { errors?: { detail?: string }[] })?.errors?.[0]
      ?.detail;
    throw new Error(
      `ATOM login failed: ${detail ?? `HTTP ${res.status}`}`,
    );
  }
  const token = (data as { access_token?: string }).access_token;
  if (!token) throw new Error("ATOM login: missing access_token");
  return token;
}

/** Shared authentication for document and SKU services within an edge worker. */
export class Atom {
  private static tokens = new Map<string, Promise<string>>();

  constructor(
    private readonly api?: JsonApiService,
    private readonly config: AtomConfig = getAtomConfig(),
  ) {}

  protected async getApi(): Promise<JsonApiService> {
    if (this.api) return this.api;
    const { baseUrl, user, pass } = this.config;
    if (!user || !pass) throw new Error("ATOM credentials not configured");
    const key = JSON.stringify([baseUrl, user, pass]);
    let token = Atom.tokens.get(key);
    if (!token) {
      token = atomLogin(baseUrl, user, pass).catch((error) => {
        Atom.tokens.delete(key);
        throw error;
      });
      Atom.tokens.set(key, token);
    }
    const accessToken = await token;
    return new JsonApiService({
      url: baseUrl,
      version: "api",
      headers: () => ({ Authorization: `Bearer ${accessToken}` }),
    });
  }
}
