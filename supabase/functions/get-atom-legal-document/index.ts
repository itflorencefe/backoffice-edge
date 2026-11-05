import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  discoverDocuments,
  fetchDocumentHtml,
  getAtomApi,
  JsonApiHttpError,
  resolveAtomProductIdFromParam,
} from "../_shared/atom-legal.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

interface RequestParams {
  mode: "discover" | "document";
  locale: string;
  atomProductId?: string | null;
  documentFormat?: string | null;
  date?: string | null;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

async function parseParams(req: Request): Promise<RequestParams> {
  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const documentFormat = body.format;
  const mode = body.mode === "document" ? "document" : "discover";

  return {
    mode,
    locale: String(body.language ?? "fr").toLowerCase(),
    atomProductId: body.atom_product_id != null
      ? String(body.atom_product_id)
      : null,
    documentFormat: documentFormat != null ? String(documentFormat) : null,
    date: body.date != null ? String(body.date) : null,
  };
}

function httpStatusFromError(message: string): number {
  if (message.includes("not configured") || message.includes("login failed")) {
    return 500;
  }
  if (message.includes("not found") || message.includes("Not found")) {
    return 404;
  }
  if (message.includes("required") || message.includes("must be")) return 400;
  return 500;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return json({ ok: false, error: "Method not allowed" }, 405);
  }

  try {
    const params = await parseParams(req);

    if (!params.atomProductId) {
      return json(
        {
          ok: false,
          error:
            "atom product id is required",
        },
        500,
      );
    }
    const { atomProductId, resolvedLocale } = resolveAtomProductIdFromParam(
      params.atomProductId,
      params.locale,
    );

    const api = await getAtomApi();

    if (params.mode === "discover") {
      const discovery = await discoverDocuments(
        api,
        atomProductId
      );
      return json({
        ok: true,
        requestedLanguage: resolvedLocale,
        ...discovery,
      });
    }

    const formatKey = params.documentFormat?.trim();
    if (!formatKey) {
      return json(
        {
          ok: false,
          error:
            "document_format (or format / document_slug) is required for document mode",
        },
        400,
      );
    }

    const bodyHtml = await fetchDocumentHtml(
      api,
      atomProductId,
      formatKey,
      resolvedLocale,
      params.date ?? undefined,
    );

    const accept = req.headers.get("Accept") ?? "";
    if (accept.includes("text/html")) {
      return new Response(bodyHtml, {
        status: 200,
        headers: {
          ...CORS_HEADERS,
          "Content-Type": "text/html; charset=utf-8",
        },
      });
    }

    return json({
      ok: true,
      document: {
        slug: formatKey,
        locale: resolvedLocale,
        body_html: bodyHtml,
        updated_at: new Date().toISOString(),
      },
    });
  } catch (err) {
    if (err instanceof JsonApiHttpError) {
      return json(
        {
          ok: false,
          error: err.message,
          status: err.status,
          errors: err.errors,
        },
        err.status >= 400 && err.status < 600 ? err.status : 502,
      );
    }
    const message = err instanceof Error ? err.message : String(err);
    return json({ ok: false, error: message }, httpStatusFromError(message));
  }
});
