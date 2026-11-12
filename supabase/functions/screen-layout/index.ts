import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.49.1";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

const TAG = "[screen-layout]";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SCREEN_RE = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$/;
const LOCALE_RE = /^[a-zA-Z]{2,3}([-_][a-zA-Z0-9]{2,8})?$/;
const STORAGE_PATH = "/storage/v1/object/public/";

const EXTERNAL_URL_RE = /^https:\/\/[a-z0-9.-]+\.[a-z]{2,}(:\d+)?(\/\S*)?$/i;
const INTERNAL_PATH_RE = /^[A-Za-z0-9][A-Za-z0-9._~\-/?=&#%+]*$/;
const WIDGET_TYPES = new Set(["custom_widget", "placeholder_text", "banner", "video"]);
const USER_TIERS = ["guest", "free", "premium"];

// Canonical order; null (rows predating the column) means visible to every user type.
function visibleTo(v: string[] | null): string[] {
  return v ? USER_TIERS.filter((t) => v.includes(t)) : [...USER_TIERS];
}

// Keep in sync with the backoffice country -> time zone map.
const COUNTRY_TIMEZONE: Record<string, string> = {
  AE: "Asia/Dubai", AO: "Africa/Luanda", AR: "America/Argentina/Buenos_Aires", AT: "Europe/Vienna", AU: "Australia/Sydney",
  BE: "Europe/Brussels", BF: "Africa/Ouagadougou", BH: "Asia/Bahrain", BJ: "Africa/Porto-Novo", BR: "America/Sao_Paulo",
  BW: "Africa/Gaborone", CA: "America/Toronto", CD: "Africa/Kinshasa", CF: "Africa/Bangui", CG: "Africa/Brazzaville",
  CH: "Europe/Zurich", CI: "Africa/Abidjan", CM: "Africa/Douala", CO: "America/Bogota", CZ: "Europe/Prague",
  DE: "Europe/Berlin", DK: "Europe/Copenhagen", DZ: "Africa/Algiers", EG: "Africa/Cairo", ES: "Europe/Madrid",
  ET: "Africa/Addis_Ababa", FI: "Europe/Helsinki", FR: "Europe/Paris", GA: "Africa/Libreville", GB: "Europe/London",
  GH: "Africa/Accra", GN: "Africa/Conakry", GR: "Europe/Athens", IE: "Europe/Dublin", IN: "Asia/Kolkata",
  IQ: "Asia/Baghdad", IT: "Europe/Rome", JO: "Asia/Amman", KE: "Africa/Nairobi", KW: "Asia/Kuwait",
  LB: "Asia/Beirut", LY: "Africa/Tripoli", MA: "Africa/Casablanca", MG: "Africa/Antananarivo", ML: "Africa/Bamako",
  MR: "Africa/Nouakchott", MU: "Indian/Mauritius", MW: "Africa/Blantyre", MX: "America/Mexico_City", MZ: "Africa/Maputo",
  NA: "Africa/Windhoek", NE: "Africa/Niamey", NG: "Africa/Lagos", NL: "Europe/Amsterdam", NO: "Europe/Oslo",
  OM: "Asia/Muscat", PL: "Europe/Warsaw", PT: "Europe/Lisbon", QA: "Asia/Qatar", RO: "Europe/Bucharest",
  RW: "Africa/Kigali", SA: "Asia/Riyadh", SD: "Africa/Khartoum", SE: "Europe/Stockholm", SN: "Africa/Dakar",
  TD: "Africa/Ndjamena", TG: "Africa/Lome", TN: "Africa/Tunis", TR: "Europe/Istanbul", TZ: "Africa/Dar_es_Salaam",
  UG: "Africa/Kampala", US: "America/New_York", ZA: "Africa/Johannesburg", ZM: "Africa/Lusaka", ZW: "Africa/Harare",
};

type Platform = "mobile" | "desktop";
type Level = "locale" | "product" | "service";
const LEVEL_RANK: Record<Level, number> = { service: 0, product: 1, locale: 2 };

interface ScreenRow {
  id: string;
  slug: string;
  name: string;
  enabled: boolean;
  service_id: string | null;
  product_id: string | null;
  product_locale_id: string | null;
}

type Link = { type: "external" | "internal" | null; url: string | null };

interface SectionRow {
  id: string;
  screen_id: string;
  platform: Platform;
  widget_type: string;
  title: string;
  show_title: boolean;
  position: number;
  col_span: number;
  config: Record<string, unknown>;
  start_at_local: string | null;
  end_at_local: string | null;
  visible_to: string[] | null;
}

function isValidTimezone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

function resolveTimezone(timezone: string | null, countryCode: string | null): string {
  if (timezone && isValidTimezone(timezone)) return timezone;
  return (countryCode && COUNTRY_TIMEZONE[countryCode.toUpperCase()]) || "UTC";
}

function nowInTimezone(tz: string): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date());
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "00";
  return `${get("year")}-${get("month")}-${get("day")}T${get("hour")}:${get("minute")}`;
}

function toMinute(value: string | null): string | null {
  return value ? value.replace(" ", "T").slice(0, 16) : null;
}

function str(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

/** Optional challenge reference of a section (config.challenge_id), always as a string. */
function challengeId(v: unknown): string | null {
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  return str(v) || null;
}

function validExternal(url: string): boolean {
  return EXTERNAL_URL_RE.test(url);
}

function validInternal(path: string): boolean {
  return !path.startsWith("/") && !path.includes("://") && !path.includes("..") && INTERNAL_PATH_RE.test(path);
}

function cleanLink(v: unknown): Link {
  const o = (v && typeof v === "object" ? v : {}) as Record<string, unknown>;
  const url = str(o.url);
  if (o.type === "external" && validExternal(url)) return { type: "external", url };
  if (o.type === "internal" && validInternal(url)) return { type: "internal", url };
  return { type: null, url: null };
}

/** "upload" for files in Supabase storage, "url" for external images, null without an image. */
function imageSource(url: string | null): "upload" | "url" | null {
  if (!url) return null;
  return url.includes(STORAGE_PATH) ? "upload" : "url";
}

function image(url: string | null) {
  return { image_source: imageSource(url), image_url: url };
}

/** Type-specific fields of a section, after the common ones (label, description, link). */
function widgetFields(type: string, c: Record<string, unknown>): Record<string, unknown> {
  const common = { label: str(c.label) || null, description: str(c.description) };
  if (type === "custom_widget") {
    const items = (Array.isArray(c.slides) ? c.slides : [])
      .map((s) => (s && typeof s === "object" ? s : {}) as Record<string, unknown>)
      .map((s) => ({ id: str(s.id), title: str(s.title), ...image(str(s.image_url) || null), link: cleanLink(s.link) }))
      .filter((s) => s.image_url || s.title);
    return { ...common, link: cleanLink(null), items: c.carousel_enabled === true ? items : items.slice(0, 1) };
  }
  if (type === "placeholder_text") return { ...common, link: cleanLink(c.link) };
  if (type === "banner") {
    const url = str(c.image_url);
    const ok = !!url && (c.image_source !== "external" || validExternal(url));
    return { ...common, link: cleanLink(c.link), ...image(ok ? url : null) };
  }
  const source = c.video_source === "external" || c.video_source === "internal" ? c.video_source : "upload";
  const url = str(c.video_url);
  const ok = !!url && (source === "upload" || (source === "external" ? validExternal(url) : validInternal(url)));
  return { ...common, link: cleanLink(null), video_url: ok ? url : null, ...image(str(c.cover_image_url) || null) };
}

type TextRef = { namespace: string; key: string };
type Translate = (ref: unknown, raw: string) => string;

const DESKTOP_KEY_SUFFIX = "Desktop";
const baseKey = (key: string) => (key.endsWith(DESKTOP_KEY_SUFFIX) ? key.slice(0, -DESKTOP_KEY_SUFFIX.length) : null);

function readRef(v: unknown): TextRef | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  return typeof o.namespace === "string" && typeof o.key === "string" && o.key ? { namespace: o.namespace, key: o.key } : null;
}

function refsOf(i18n: unknown): Record<string, unknown> {
  return (i18n && typeof i18n === "object" ? i18n : {}) as Record<string, unknown>;
}

function collectRefs(c: Record<string, unknown>): TextRef[] {
  const out: TextRef[] = [];
  const push = (i18n: unknown) => {
    const r = refsOf(i18n);
    for (const field of ["title", "description"]) {
      const ref = readRef(r[field]);
      if (ref) out.push(ref);
    }
  };
  push(c.i18n);
  for (const slide of Array.isArray(c.slides) ? c.slides : []) push((slide as Record<string, unknown>)?.i18n);
  return out;
}

function localize(title: string, c: Record<string, unknown>, t: Translate): { title: string; config: Record<string, unknown> } {
  const refs = refsOf(c.i18n);
  const config: Record<string, unknown> = { ...c, description: t(refs.description, str(c.description)) };
  if (Array.isArray(c.slides)) {
    config.slides = c.slides.map((slide) => {
      const s = (slide && typeof slide === "object" ? slide : {}) as Record<string, unknown>;
      const r = refsOf(s.i18n);
      return { ...s, title: t(r.title, str(s.title)) };
    });
  }
  return { title: t(refs.title, title), config };
}

async function loadTranslator(
  supabase: SupabaseClient,
  serviceId: string,
  locale: { id: string; language_code: string } | null,
  environment: string,
  refs: TextRef[],
): Promise<{ translate: Translate; error: boolean }> {
  const values = new Map<string, string>();
  const id = (namespace: string, key: string) => `${namespace}\u0000${key}`;
  const keys = [...new Set(refs.flatMap((r) => {
    const base = baseKey(r.key);
    return base ? [r.key, base] : [r.key];
  }))];
  if (locale && keys.length > 0) {
    const [svc, loc] = await Promise.all([
      supabase.schema("backoffice").from("service_translations_defaults").select("namespace, key, value")
        .eq("service_id", serviceId).eq("environment", environment).eq("language_code", locale.language_code).in("key", keys),
      supabase.schema("backoffice").from("product_translations").select("namespace, key, value")
        .eq("product_locale_id", locale.id).eq("environment", environment).in("key", keys),
    ]);
    if (svc.error || loc.error) {
      console.error(`${TAG} texts`, svc.error?.message ?? loc.error?.message);
      return { translate: (_ref, raw) => raw, error: true };
    }
    for (const r of (svc.data ?? []) as { namespace: string; key: string; value: string }[]) values.set(id(r.namespace, r.key), r.value);
    for (const r of (loc.data ?? []) as { namespace: string; key: string; value: string }[]) values.set(id(r.namespace, r.key), r.value);
  }
  // A missing or empty desktop text (e.g. videoTitleDesktop) falls back to its base key (videoTitle).
  const lookup = (namespace: string, key: string) => {
    const own = values.get(id(namespace, key));
    if (own) return own;
    const base = baseKey(key);
    return (base ? values.get(id(namespace, base)) : undefined) ?? own;
  };
  return {
    translate: (ref, raw) => {
      const r = readRef(ref);
      return r ? lookup(r.namespace, r.key) ?? raw : raw;
    },
    error: false,
  };
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function fail(status: number, error: string): Response {
  return json({ ok: false, error }, status);
}

/** Active locales: the requested one, else the default, else the first; null when the product has none. */
function pickLocale(
  locales: { id: string; language_code: string; is_default: boolean }[],
  requested: string | null,
): { id: string; language_code: string } | null {
  const norm = (code: string) => code.toLowerCase().replace("_", "-");
  return (requested ? locales.find((l) => norm(l.language_code) === norm(requested)) : undefined)
    ?? locales.find((l) => l.is_default)
    ?? locales[0]
    ?? null;
}

function levelOf(row: ScreenRow): Level {
  return row.product_locale_id ? "locale" : row.product_id ? "product" : "service";
}

/** Most specific level wins per slug: locale > product > service. */
function mergeScreens(rows: ScreenRow[]): Map<string, ScreenRow> {
  const bySlug = new Map<string, ScreenRow>();
  for (const row of rows) {
    const prev = bySlug.get(row.slug);
    if (!prev || LEVEL_RANK[levelOf(row)] > LEVEL_RANK[levelOf(prev)]) bySlug.set(row.slug, row);
  }
  return bySlug;
}

/** Enabled widgets of known types for the given screens, ordered by position. */
async function loadSections(
  db: ReturnType<SupabaseClient["schema"]>,
  screenIds: string[],
): Promise<{ rows: SectionRow[]; error: string | null }> {
  if (screenIds.length === 0) return { rows: [], error: null };
  const { data, error } = await db
    .from("app_screen_sections")
    .select("id, screen_id, platform, widget_type, title, show_title, position, col_span, config, start_at_local, end_at_local, visible_to")
    .in("screen_id", screenIds)
    .eq("enabled", true)
    .order("position", { ascending: true })
    .order("created_at", { ascending: true });
  if (error) return { rows: [], error: error.message };
  return { rows: ((data ?? []) as SectionRow[]).filter((s) => WIDGET_TYPES.has(s.widget_type)), error: null };
}

/** Widgets of the requested platform (or the other one when it has none), live at product-local `nowLocal`. */
function pickSections(all: SectionRow[], platform: Platform, nowLocal: string): { resolvedPlatform: Platform; sections: SectionRow[] } {
  const other: Platform = platform === "mobile" ? "desktop" : "mobile";
  let resolvedPlatform: Platform = platform;
  let sections = all.filter((s) => s.platform === platform);
  if (sections.length === 0 && all.some((s) => s.platform === other)) {
    resolvedPlatform = other;
    sections = all.filter((s) => s.platform === other);
  }
  // Live between start and end (both inclusive, product-local minutes).
  sections = sections.filter((s) => {
    const start = toMinute(s.start_at_local);
    const end = toMinute(s.end_at_local);
    return (!start || nowLocal >= start) && (!end || nowLocal <= end);
  });
  return { resolvedPlatform, sections };
}

function serializeSections(sections: SectionRow[], translate: Translate): Record<string, unknown>[] {
  return sections.map((s, index) => {
    const { title, config } = localize(s.title, s.config ?? {}, translate);
    return {
      id: s.id,
      widget_type: s.widget_type,
      title: title.trim(),
      show_title: s.show_title,
      col_span: s.col_span,
      position: index,
      start_at: toMinute(s.start_at_local),
      end_at: toMinute(s.end_at_local),
      visible_to: visibleTo(s.visible_to),
      challenge_id: challengeId(s.config?.challenge_id),
      ...widgetFields(s.widget_type, config),
    };
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: CORS });
  }
  if (req.method !== "GET") {
    return fail(405, "Use GET");
  }

  try {
    const params = new URL(req.url).searchParams;

    const productId = params.get("product_id");
    // An empty screen (screen= or blanks) means "no screen": the response is the screen list.
    const screen = params.get("screen")?.trim() || null;
    const platformParam = (params.get("platform") || "mobile").toLowerCase();
    const environment = params.get("environment") || "production";
    const localeParam = params.get("locale") ?? params.get("language_code");

    if (!productId) return fail(400, "'product_id' is required");
    if (!UUID_RE.test(productId)) return fail(400, "'product_id' must be a valid product code (uuid)");
    if (environment !== "staging" && environment !== "production") {
      return fail(400, "environment must be 'staging' or 'production'");
    }
    if (platformParam !== "mobile" && platformParam !== "desktop") {
      return fail(400, "platform must be 'mobile' or 'desktop'");
    }
    if (screen !== null && !SCREEN_RE.test(screen)) return fail(400, "Invalid screen");
    if (localeParam !== null && !LOCALE_RE.test(localeParam)) return fail(400, "Invalid locale");
    const platform = platformParam as Platform;

    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const db = supabase.schema("backoffice");

    const { data: product, error: productError } = await db
      .from("products")
      .select("id, service_id, country_code, timezone")
      .eq("id", productId)
      .maybeSingle();
    if (productError) {
      console.error(`${TAG} product`, productError.message);
      return fail(500, "Could not load product");
    }
    if (!product) return fail(404, "Product not found");

    const { data: locales, error: localesError } = await db
      .from("product_locales")
      .select("id, language_code, is_default")
      .eq("product_id", product.id)
      .eq("status", "active")
      .order("is_default", { ascending: false })
      .order("created_at", { ascending: true });
    if (localesError) {
      console.error(`${TAG} locales`, localesError.message);
      return fail(500, "Could not load languages");
    }
    const locale = pickLocale(locales ?? [], localeParam);
    const timezone = resolveTimezone(product.timezone, product.country_code);

    // Screen slugs are stored in lowercase.
    const owners = [`service_id.eq.${product.service_id}`, `product_id.eq.${product.id}`];
    if (locale) owners.push(`product_locale_id.eq.${locale.id}`);
    let query = db
      .from("app_screens")
      .select("id, slug, name, enabled, service_id, product_id, product_locale_id")
      .eq("environment", environment)
      .or(owners.join(","));
    if (screen !== null) query = query.eq("slug", screen.toLowerCase());
    const { data: screenRows, error: screensError } = await query;
    if (screensError) {
      console.error(`${TAG} screens`, screensError.message);
      return fail(500, "Could not load screens");
    }
    const bySlug = mergeScreens((screenRows ?? []) as ScreenRow[]);
    const localeCode = locale?.language_code ?? null;
    const nowLocal = nowInTimezone(timezone);

    if (screen === null) {
      // List mode: every active screen, complete with the widgets a single-screen call would return.
      const screens = [...bySlug.values()]
        .filter((r) => r.enabled)
        .sort((a, b) => a.slug.localeCompare(b.slug));
      const { rows, error: sectionsError } = await loadSections(db, screens.map((r) => r.id));
      if (sectionsError) {
        console.error(`${TAG} sections`, sectionsError);
        return fail(500, "Could not load screens");
      }
      const picked = screens.map((r) => ({
        row: r,
        ...pickSections(rows.filter((s) => s.screen_id === r.id), platform, nowLocal),
      }));
      const { translate, error: textsError } = await loadTranslator(
        supabase, product.service_id, locale, environment,
        picked.flatMap((p) => p.sections.flatMap((s) => collectRefs(s.config ?? {}))),
      );
      if (textsError) return fail(500, "Could not load texts");

      console.log(`${TAG} product=${product.id} screen=* env=${environment} platform=${platform} screens=${picked.length}`);

      return json({
        ok: true,
        data: {
          environment,
          locale: localeCode,
          platform,
          timezone,
          screens: picked.map((p) => ({
            screen: p.row.slug,
            name: p.row.name,
            source_level: levelOf(p.row),
            resolved_platform: p.resolvedPlatform,
            sections: serializeSections(p.sections, translate),
          })),
        },
      }, 200);
    }

    const found = bySlug.get(screen.toLowerCase());
    if (!found) return fail(404, `Screen '${screen}' not found`);
    const level = levelOf(found);
    if (!found.enabled) return fail(404, `Screen '${screen}' is disabled for this ${level}`);

    const { rows, error: sectionError } = await loadSections(db, [found.id]);
    if (sectionError) {
      console.error(`${TAG} sections`, sectionError);
      return fail(500, "Could not load screens");
    }
    const { resolvedPlatform, sections } = pickSections(rows, platform, nowLocal);

    const { translate, error: textsError } = await loadTranslator(
      supabase, product.service_id, locale, environment, sections.flatMap((s) => collectRefs(s.config ?? {})),
    );
    if (textsError) return fail(500, "Could not load texts");

    console.log(`${TAG} product=${product.id} screen=${found.slug} env=${environment} level=${level} platform=${resolvedPlatform} sections=${sections.length}`);

    return json({
      ok: true,
      data: {
        screen: found.slug,
        name: found.name,
        environment,
        locale: localeCode,
        source_level: level,
        platform,
        resolved_platform: resolvedPlatform,
        timezone,
        sections: serializeSections(sections, translate),
      },
    }, 200);
  } catch (err) {
    console.error(`${TAG} error`, err);
    return fail(500, "Internal error");
  }
});
