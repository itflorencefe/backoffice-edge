import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-Client-Info, Apikey",
};

const TAG = "[instant-games-assets]";

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function deepMerge(
  base: Record<string, unknown>,
  override: Record<string, unknown>,
): Record<string, unknown> {
  const result = { ...base };
  for (const key of Object.keys(override)) {
    const ov = override[key];
    const bv = base[key];
    if (
      ov !== null &&
      typeof ov === "object" &&
      !Array.isArray(ov) &&
      bv !== null &&
      typeof bv === "object" &&
      !Array.isArray(bv)
    ) {
      result[key] = deepMerge(bv as Record<string, unknown>, ov as Record<string, unknown>);
    } else {
      result[key] = ov;
    }
  }
  return result;
}

interface DbTemplate {
  id: string;
  game_type_id: number;
  template_name: string;
  is_default: boolean;
  enabled: boolean;
  enabled_from: string | null;
  enabled_to: string | null;
  preview_icon: string | null;
  assets: Record<string, string>;
  theme: Record<string, unknown>;
  config: Record<string, unknown>;
}

interface MergedTemplate {
  id: string;
  template_name: string;
  is_default: boolean;
  enabled: boolean;
  enabled_from: string | null;
  enabled_to: string | null;
  preview_icon: string | null;
  assets: Record<string, unknown>;
  theme: Record<string, unknown>;
  config: Record<string, unknown>;
}

function isTemplateActiveNow(t: { enabled: boolean; enabled_from: string | null; enabled_to: string | null }): boolean {
  if (!t.enabled) return false;
  const now = new Date();
  if (t.enabled_from && now < new Date(t.enabled_from)) return false;
  if (t.enabled_to && now > new Date(t.enabled_to)) return false;
  return true;
}

function mergeTemplates(
  serviceTemplates: DbTemplate[],
  productTemplates: DbTemplate[],
  localeTemplates: DbTemplate[],
): MergedTemplate[] {
  const serviceMap = new Map<string, DbTemplate>();
  for (const t of serviceTemplates) {
    serviceMap.set(t.template_name, t);
  }

  const productMap = new Map<string, DbTemplate>();
  for (const t of productTemplates) {
    productMap.set(t.template_name, t);
  }

  const localeMap = new Map<string, DbTemplate>();
  for (const t of localeTemplates) {
    localeMap.set(t.template_name, t);
  }

  const allNames = new Set([...serviceMap.keys(), ...productMap.keys(), ...localeMap.keys()]);
  const merged: MergedTemplate[] = [];

  for (const name of allNames) {
    const svc = serviceMap.get(name);
    const prod = productMap.get(name);
    const loc = localeMap.get(name);

    let assets: Record<string, unknown> = (svc?.assets ?? {}) as Record<string, unknown>;
    let theme: Record<string, unknown> = svc?.theme ?? {};
    let config: Record<string, unknown> = svc?.config ?? {};
    let isDefault = svc?.is_default ?? false;
    let enabled = svc?.enabled ?? true;
    let enabledFrom: string | null = svc?.enabled_from ?? null;
    let enabledTo: string | null = svc?.enabled_to ?? null;
    let previewIcon: string | null = svc?.preview_icon ?? null;

    if (prod) {
      assets = deepMerge(assets, (prod.assets ?? {}) as Record<string, unknown>);
      theme = deepMerge(theme, prod.theme ?? {});
      config = deepMerge(config, prod.config ?? {});
      isDefault = prod.is_default || isDefault;
      enabled = prod.enabled;
      if (prod.enabled_from !== null || prod.enabled_to !== null) {
        enabledFrom = prod.enabled_from;
        enabledTo = prod.enabled_to;
      }
      previewIcon = prod.preview_icon ?? previewIcon;
    }

    if (loc) {
      assets = deepMerge(assets, (loc.assets ?? {}) as Record<string, unknown>);
      theme = deepMerge(theme, loc.theme ?? {});
      config = deepMerge(config, loc.config ?? {});
      isDefault = loc.is_default || isDefault;
      enabled = loc.enabled;
      if (loc.enabled_from !== null || loc.enabled_to !== null) {
        enabledFrom = loc.enabled_from;
        enabledTo = loc.enabled_to;
      }
      previewIcon = loc.preview_icon ?? previewIcon;
    }

    const id = loc?.id ?? prod?.id ?? svc!.id;
    merged.push({ id, template_name: name, is_default: isDefault, enabled, enabled_from: enabledFrom, enabled_to: enabledTo, preview_icon: previewIcon, assets, theme, config });
  }

  return merged;
}

async function fetchPulsarGameTypes(
  supabaseUrl: string,
  country: string,
  locale: string,
): Promise<Array<{ id: number; title: string | null; type: unknown }>> {
  const url = `${supabaseUrl}/functions/v1/pulsar/instant-games?country=${encodeURIComponent(country)}&locale=${encodeURIComponent(locale)}`;
  const res = await fetch(url, {
    method: "GET",
    headers: {
      "Authorization": `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
      "Content-Type": "application/json",
    },
  });

  if (!res.ok) {
    console.error(`${TAG} Pulsar call failed: ${res.status} ${await res.text()}`);
    return [];
  }

  const body = await res.json();
  if (!body.ok || !Array.isArray(body.data)) return [];
  return body.data;
}

async function resolveProductLocaleId(
  supabase: ReturnType<typeof createClient>,
  productId: string,
  locale: string,
): Promise<string | null> {
  const languageCode = locale.includes("-") ? locale.split("-")[0] : locale;

  const { data } = await supabase
    .schema("backoffice").from("bo_product_locales")
    .select("id")
    .eq("product_id", productId)
    .eq("language_code", languageCode)
    .maybeSingle();

  return data?.id ?? null;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const ts = new Date().toISOString();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: CORS });
  }

  if (req.method !== "GET") {
    return json({ ok: false, error: { message: "Method not allowed" } }, 405);
  }

  const url = new URL(req.url);
  const funcPrefix = "/instant-games-assets";
  let pathname = url.pathname;
  if (pathname.startsWith(funcPrefix)) {
    pathname = pathname.slice(funcPrefix.length) || "/";
  }

  const environment = url.searchParams.get("environment") || "production";
  if (environment !== "staging" && environment !== "production") {
    return json({ ok: false, error: { message: "environment must be 'staging' or 'production'" } }, 400);
  }

  const country = url.searchParams.get("country") || "FR";
  const locale = url.searchParams.get("locale") || "fr-FR";

  const productId = url.searchParams.get("productid");
  if (!productId) {
    return json({ ok: false, error: { message: "productid query parameter is required" } }, 400);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabase = createClient(supabaseUrl, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: product, error: productError } = await supabase
    .schema("backoffice").from("bo_products")
    .select("id, service_id")
    .eq("id", productId)
    .maybeSingle();

  if (productError) {
    return json({ ok: false, error: { message: `Product lookup failed: ${productError.message}` } }, 500);
  }
  if (!product) {
    return json({ ok: false, error: { message: `Product not found: ${productId}` } }, 404);
  }

  const service_id = product.service_id;
  const product_id = product.id;
  const dbEnv = environment === "staging" ? "staging" : "production";

  console.log(`${TAG} ${ts} | GET ${pathname} | service=${service_id} product=${product_id} env=${dbEnv} locale=${locale}`);

  const productLocaleId = await resolveProductLocaleId(supabase, product_id, locale);

  try {
    if (pathname === "/" || pathname === "") {
      const pulsarGames = await fetchPulsarGameTypes(supabaseUrl, country, locale);

      const typeIds = [...new Set(
        pulsarGames
          .map((g) => (g.type as Record<string, unknown>)?.id as number | undefined)
          .filter((id): id is number => typeof id === "number"),
      )];

      if (typeIds.length === 0) {
        return json({ ok: true, data: { game_types: [] } }, 200);
      }

      const { data: serviceRows } = await supabase
        .schema("backoffice").from("bo_service_instant_games_defaults")
        .select("id, game_type_id, template_name, is_default, enabled, enabled_from, enabled_to, preview_icon, assets, theme, config")
        .eq("service_id", service_id)
        .eq("environment", dbEnv)
        .in("game_type_id", typeIds);

      const { data: productRows } = await supabase
        .schema("backoffice").from("bo_product_instant_games")
        .select("id, game_type_id, template_name, is_default, enabled, enabled_from, enabled_to, preview_icon, assets, theme, config")
        .eq("product_id", product_id)
        .eq("environment", dbEnv)
        .in("game_type_id", typeIds);

      let localeRows: DbTemplate[] = [];
      if (productLocaleId) {
        const { data } = await supabase
          .schema("backoffice").from("bo_locale_instant_games")
          .select("id, game_type_id, template_name, is_default, enabled, enabled_from, enabled_to, preview_icon, assets, theme, config")
          .eq("product_locale_id", productLocaleId)
          .eq("environment", dbEnv)
          .in("game_type_id", typeIds);
        localeRows = (data ?? []) as DbTemplate[];
      }

      const svcByType = new Map<number, DbTemplate[]>();
      for (const row of (serviceRows ?? []) as DbTemplate[]) {
        const list = svcByType.get(row.game_type_id) ?? [];
        list.push(row);
        svcByType.set(row.game_type_id, list);
      }

      const prodByType = new Map<number, DbTemplate[]>();
      for (const row of (productRows ?? []) as DbTemplate[]) {
        const list = prodByType.get(row.game_type_id) ?? [];
        list.push(row);
        prodByType.set(row.game_type_id, list);
      }

      const localeByType = new Map<number, DbTemplate[]>();
      for (const row of localeRows) {
        const list = localeByType.get(row.game_type_id) ?? [];
        list.push(row);
        localeByType.set(row.game_type_id, list);
      }

      const gameTypeMap = new Map<number, { id: number; title: string | null; type: unknown }[]>();
      for (const g of pulsarGames) {
        const typeObj = g.type as Record<string, unknown> | undefined;
        const typeId = typeObj?.id as number | undefined;
        if (typeof typeId !== "number") continue;
        const list = gameTypeMap.get(typeId) ?? [];
        list.push(g);
        gameTypeMap.set(typeId, list);
      }

      const gameTypes = typeIds.map((typeId) => {
        const svcTemplates = svcByType.get(typeId) ?? [];
        const prodTemplates = prodByType.get(typeId) ?? [];
        const locTemplates = localeByType.get(typeId) ?? [];
        const templates = mergeTemplates(svcTemplates, prodTemplates, locTemplates).filter(t => isTemplateActiveNow(t));
        const pulsarItems = gameTypeMap.get(typeId) ?? [];
        const typeName = (pulsarItems[0]?.type as Record<string, unknown>)?.name as string ?? `type_${typeId}`;

        return {
          type_id: typeId,
          type_name: typeName,
          pulsar_games: pulsarItems,
          templates,
        };
      });

      return json({ ok: true, data: { game_types: gameTypes } }, 200);
    }

    const typeIdMatch = pathname.match(/^\/(\d+)$/);
    if (typeIdMatch) {
      const typeId = parseInt(typeIdMatch[1], 10);

      const [{ data: serviceRows }, { data: productRows }] = await Promise.all([
        supabase
          .schema("backoffice").from("bo_service_instant_games_defaults")
          .select("id, game_type_id, template_name, is_default, enabled, enabled_from, enabled_to, preview_icon, assets, theme, config")
          .eq("service_id", service_id)
          .eq("environment", dbEnv)
          .eq("game_type_id", typeId),
        supabase
          .schema("backoffice").from("bo_product_instant_games")
          .select("id, game_type_id, template_name, is_default, enabled, enabled_from, enabled_to, preview_icon, assets, theme, config")
          .eq("product_id", product_id)
          .eq("environment", dbEnv)
          .eq("game_type_id", typeId),
      ]);

      let localeRows: DbTemplate[] = [];
      if (productLocaleId) {
        const { data } = await supabase
          .schema("backoffice").from("bo_locale_instant_games")
          .select("id, game_type_id, template_name, is_default, enabled, enabled_from, enabled_to, preview_icon, assets, theme, config")
          .eq("product_locale_id", productLocaleId)
          .eq("environment", dbEnv)
          .eq("game_type_id", typeId);
        localeRows = (data ?? []) as DbTemplate[];
      }

      const templates = mergeTemplates(
        (serviceRows ?? []) as DbTemplate[],
        (productRows ?? []) as DbTemplate[],
        localeRows,
      ).filter(t => isTemplateActiveNow(t));

      return json({ ok: true, data: { type_id: typeId, templates } }, 200);
    }

    return json({ ok: false, error: { message: "Route not found" } }, 404);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Internal server error";
    console.error(`${TAG} ${ts} | error: ${message}`, err);
    return json({ ok: false, error: { message } }, 500);
  }
});
