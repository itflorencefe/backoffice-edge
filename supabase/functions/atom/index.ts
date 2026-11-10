import { JsonApiHttpError } from "../_shared/atom/atom.ts";
import { AtomDocuments } from "../_shared/atom/documents.ts";
import { AtomSkus } from "../_shared/atom/skus.ts";
import { AtomProduct } from "../_shared/atom/product.ts";
import { AtomPacks, type PackDto } from "../_shared/atom/packs.ts";
import { compareSavedPacksWithAtom, createLiveCheck, type AtomValidity } from "./pack-checks.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

class InputError extends Error {}

type LabelColor =
  | { type: 'solid'; value: string }
  | { type: 'linear-gradient'; colors: [string, string, ...string[]]; locations: [number, number, ...number[]];
      start: { x: number; y: number }; end: { x: number; y: number } };

export interface ProductPack {
  productId: number;
  packId: string;
  packName: string;
  value: number | null;
  labels: { label: string; color?: LabelColor | null }[];
  sortOrder: number;
  packValidityEnd: string | null;
  packValidityTz: string | null;
  offerValidityEnd: string | null;
  offerValidityTz: string | null;
  packOfferValidityEnd: string | null;
  packOfferValidityTz: string | null;
  packOfferId: string | null;
  offerId: string | null;
  price: number | null;
  currency: string | null;
  providerName: string | null;
}

export interface SavedPackWarning {
  packId: string;
  code: 'pack-expiry-changed' | 'offer-expiry-changed' | 'pack-offer-expiry-changed' | 'pack-missing' | 'offer-missing' | 'pack-offer-missing' | 'pack-offer-ambiguous' | 'price-changed';
  message: string;
}


export interface AtomValidityResponse extends AtomValidity {
  validityStart: string | null;
  live: boolean | null;
}

export interface AtomPackOfferResponse extends AtomValidityResponse {
  id: string | null;
  used: boolean | null;
  data: Record<string, unknown> | null;
}

export interface AtomOfferResponse extends AtomValidityResponse {
  id: string;
  name: string | null;
  providerId: string | null;
  provider: string | null;
  price: number | null;
  currency: string | null;
  packOffer: AtomPackOfferResponse;
}

export interface AtomPackResponse extends AtomValidityResponse {
  id: string;
  name: string | null;
  offers: AtomOfferResponse[];
}

export interface PacksResponse {
  ok: true;
  packs: AtomPackResponse[];
}

export interface CheckLocalPacksResponse {
  ok: true;
  packs: ProductPack[];
  messages: SavedPackWarning[];
  errors: string[];
}

/** The edge owns live calculations; the editor still receives original Atom bounds. */
export function toPackResponse(packs: PackDto[], now = Date.now()): AtomPackResponse[] {
  const live = createLiveCheck(now);
  const validity = (value: AtomValidity & { validityStart: string | null }): AtomValidityResponse => ({
    validityStart: value.validityStart,
    validityEnd: value.validityEnd,
    validityTz: value.validityTz,
    live: live(value),
  });
  return packs.map((pack) => ({
    id: pack.id, name: pack.name, ...validity(pack),
    offers: pack.offers.map((offer) => ({
      id: offer.id, name: offer.name, providerId: offer.providerId, provider: offer.provider,
      price: offer.price, currency: offer.currency, ...validity(offer),
      packOffer: {
        id: offer.packOffer.id, used: offer.packOffer.used, data: offer.packOffer.data,
        ...validity(offer.packOffer),
      },
    })),
  }));
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function parseParams(body: unknown) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new InputError("JSON body must be an object");
  }
  const params = body as Record<string, unknown>;
  const mode = params.mode;
  if (mode !== "product" && mode !== "packs" && mode !== "checkLocalPacks" && mode !== "discover" && mode !== "documents" && mode !== "skus") {
    throw new InputError("mode is required and must be product, packs, checkLocalPacks, discover, documents or skus");
  }
  const product = params.atom_product_id;
  if (product == null || (typeof product === "string" && !product.trim())) {
    throw new InputError("atom product id is required");
  }
  if (
    (typeof product !== "string" && typeof product !== "number") ||
    !Number.isFinite(Number(product))
  ) {
    throw new InputError("atom_product_id must be a number");
  }
  const format = params.format == null ? "" : String(params.format).trim();
  if (mode === "product" && params.include != null && typeof params.include !== "string") {
    throw new InputError("include must be a string");
  }
  const platform = params.platform == null
    ? ""
    : String(params.platform).trim().toLowerCase();
  if (mode === "documents" && !format) {
    throw new InputError("format is required for documents mode");
  }
  if (mode === "skus" && !platform) {
    throw new InputError("platform is required");
  }
  if (mode === "checkLocalPacks" && (!Number.isSafeInteger(Number(product)) || Number(product) <= 0)) {
    throw new InputError("atom_product_id must be a positive integer for checkLocalPacks");
  }
  return {
    mode,
    atomProductId: Number(product),
    language: String(params.language ?? "fr").toLowerCase(),
    format,
    platform,
    include: mode === "product" && params.include != null ? String(params.include).trim() : undefined,
    date: params.date == null ? undefined : String(params.date),
  };
}

interface Services {
  product: Pick<AtomProduct, "getProduct">;
  packs: Pick<AtomPacks, "getPacks">;
  documents: Pick<AtomDocuments, "discover" | "getDocumentHtml">;
  skus: Pick<AtomSkus, "getSkus">;
  loadLocalPacks?: (productId: number, request: Request) => Promise<ProductPack[]>;
}

function rejectAppUser(req: Request): Response | null {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return null;
  const parts = auth.slice(7).trim().split(".");
  if (parts.length !== 3) return null;
  try {
    const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padding = padded.length % 4 === 0 ? "" : "=".repeat(4 - padded.length % 4);
    const payload = JSON.parse(atob(padded + padding));
    if (payload?.app_role === "app_user" || payload?.app_metadata?.app_role === "app_user") {
      return json({
        ok: false,
        error: "App users are not authorized for this endpoint"
      }, 403);
    }
  } catch {
    // Decoding only rejects app tokens; auth.getUser verifies operator tokens.
  }
  return null;
}

export function createHandler(services: Services) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (req.method !== "POST") {
      return json({ ok: false, error: "Method not allowed" }, 405);
    }
    try {
      const blocked = rejectAppUser(req);
      if (blocked) return blocked;

      // Verify the operator's Supabase Auth session, as in the clone functions.
      const authHeader = req.headers.get("Authorization");
      const token = authHeader ? /^Bearer\s+(\S+)$/i.exec(authHeader)?.[1] : undefined;
      if (!token) return json({ ok: false, error: "Unauthorized" }, 401);
      const url = Deno.env.get("SUPABASE_URL");
      const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
      if (!url || !key) throw new Error("Backoffice authentication is not configured");
      const supabaseAdmin = createClient(url, key, {
        auth: { persistSession: false, autoRefreshToken: false },
      });
      const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(token);
      if (authErr || !user) return json({ ok: false, error: "Unauthorized" }, 401);
      if (user.app_metadata?.app_role === "app_user") {
        return json({ ok: false, error: "App users are not authorized for this endpoint" }, 403);
      }
      // Atom only reads data, so active viewers are allowed as well.
      const { data: boUser, error: roleError } = await supabaseAdmin.schema("backoffice").from("bo_backoffice_users")
        .select("role").eq("user_id", user.id).eq("is_active", true).maybeSingle();
      if (roleError) throw new Error("Unable to verify backoffice permissions");
      if (!boUser || !["viewer", "editor", "admin"].includes(boUser.role)) {
        return json({ ok: false, error: "Insufficient permissions" }, 403);
      }
      let body: unknown;
      try {
        body = await req.json();
      } catch {
        throw new InputError("Request body must be valid JSON");
      }
      const params = parseParams(body);
      switch (params.mode) {
        case "checkLocalPacks": {
          if (!services.loadLocalPacks) throw new Error("Local pack checks are not configured");
          const packs = await services.loadLocalPacks(params.atomProductId, req);
          let messages: ReturnType<typeof compareSavedPacksWithAtom> = [];
          const errors: string[] = [];
          if (packs.length) {
            try {
              const catalog = await services.packs.getPacks(params.atomProductId);
              messages = compareSavedPacksWithAtom(packs, catalog.packs);
            } catch (error) {
              errors.push(`Unable to check saved packs against Atom: ${error instanceof Error ? error.message : String(error)}`);
            }
          }
          const result: CheckLocalPacksResponse = { ok: true, packs, messages, errors };
          const response = json(result);
          response.headers.set("Cache-Control", "no-store");
          return response;
        }
        case "product":
          return json({
            ok: true,
            product: await services.product.getProduct(params.atomProductId, params.include),
          });
        case "packs": {
          const catalog = await services.packs.getPacks(params.atomProductId);
          const result: PacksResponse = { ok: true, packs: toPackResponse(catalog.packs) };
          return json(result);
        }
        case "discover":
          return json({
            ok: true,
            requestedLanguage: params.language,
            ...await services.documents.discover(params.atomProductId),
          });
        case "skus":
          return json({
            ok: true,
            ...await services.skus.getSkus(params.atomProductId, params.platform),
          });
        case "documents": {
          const bodyHtml = await services.documents.getDocumentHtml(
            params.atomProductId, params.format, params.language, params.date,
          );
          if ((req.headers.get("Accept") ?? "").includes("text/html")) {
            return new Response(bodyHtml, {
              headers: { ...CORS_HEADERS, "Content-Type": "text/html; charset=utf-8" },
            });
          }
          return json({
            ok: true,
            document: {
              slug: params.format,
              locale: params.language,
              body_html: bodyHtml,
              updated_at: new Date().toISOString(),
            },
          });
        }
      }
    } catch (error) {
      if (error instanceof JsonApiHttpError) {
        return json({
          ok: false, error: error.message, status: error.status, errors: error.errors,
        }, error.status >= 400 && error.status < 600 ? error.status : 502);
      }
      const message = error instanceof Error ? error.message : String(error);
      const status = error instanceof InputError ? 400
        : /not configured|login failed/i.test(message) ? 500
        : /not found/i.test(message) ? 404 : 500;
      return json({ ok: false, error: message }, status);
    }
  };
}

export async function loadLocalPacks(productId: number, request: Request): Promise<ProductPack[]> {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !key) throw new Error("Supabase local pack checks are not configured");
  const authorization = request.headers.get("Authorization");
  if (!authorization) throw new Error("Missing operator authorization");
  // Preserve caller RLS permissions for the same records the backoffice can read.
  const supabase = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorization } },
  });
  const { data, error } = await supabase.schema("backoffice").from("bo_product_packs")
    .select("*").eq("productId", productId).order("sortOrder").order("packId");
  if (error) throw new Error(`Unable to load saved packs: ${error.message}`);
  return (data ?? []).map((row) => ({
    productId: row.productId,
    packId: row.packId,
    packName: row.packName,
    value: row.value,
    labels: row.labels,
    sortOrder: row.sortOrder,
    packValidityEnd: row.packValidityEnd,
    packValidityTz: row.packValidityTz,
    offerValidityEnd: row.offerValidityEnd,
    offerValidityTz: row.offerValidityTz,
    packOfferValidityEnd: row.packOfferValidityEnd,
    packOfferValidityTz: row.packOfferValidityTz,
    packOfferId: row.packOfferId,
    offerId: row.offerId,
    price: row.price,
    currency: row.currency,
    providerName: row.providerName,
  }));
}

export const handleRequest = createHandler({
  product: new AtomProduct(),
  packs: new AtomPacks(),
  documents: new AtomDocuments(),
  skus: new AtomSkus(),
  loadLocalPacks,
});

Deno.serve(handleRequest);
