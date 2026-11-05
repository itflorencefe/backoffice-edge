import {
  JsonApiHttpError,
  JsonApiService,
  LegalDocument,
  Product,
} from "@digitalvirgo/atom-api";

export { JsonApiHttpError };

let cachedToken: string | undefined;

function getAtomConfig() {
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

export async function getAtomApi(): Promise<JsonApiService> {
  const cfg = getAtomConfig();
  if (!cfg.user || !cfg.pass) {
    throw new Error("ATOM credentials not configured");
  }

  let token = cachedToken;
  if (!token) {
    token = await atomLogin(cfg.baseUrl, cfg.user, cfg.pass);
    cachedToken = token;
  }

  return new JsonApiService({
    url: cfg.baseUrl,
    version: "api",
    headers: () => ({ Authorization: `Bearer ${token}` }),
  });
}

export function resolveAtomProductIdFromParam(
  atomProductIdParam: string,
  locale: string,
): { atomProductId: number; resolvedLocale: string } {
  const n = Number(atomProductIdParam);
  if (!Number.isFinite(n)) {
    throw new Error("atom_product_id must be a number");
  }
  const loc = locale.toLowerCase();
  return {
    atomProductId: n,
    resolvedLocale: loc,
  };
}

interface Document {
  id: string;
  name: string;
  documentType: string;
}

type ProductFindDocument = Awaited<ReturnType<JsonApiService["find"]>>;

function documentFromLegalDocument(doc: LegalDocument): Document | null {
  const documentType = doc.documentType.trim();
  if (!documentType) return null;
  const name = String(doc.name ?? "").trim() || documentType;
  return {
    id: String(doc.id ?? ""),
    name,
    documentType,
  };
}

function documentsFromProductFind(doc: ProductFindDocument): Document[] {
  const product = doc.data as Product;
  const fromProduct = (product.legaldocuments ?? [])
    .map(documentFromLegalDocument)
    .filter((e): e is Document => e !== null);

  if (fromProduct.length > 0) return fromProduct;

  const included = (doc.included ?? []) as LegalDocument[];
  return included
    .filter((item) => {
      const type = (item as { type?: string }).type;
      return type === undefined || type === "legaldocuments";
    })
    .map(documentFromLegalDocument)
    .filter((e): e is Document => e !== null);
}

async function fetchProductWithLegalDocuments(
  api: JsonApiService,
  atomProductId: number,
): Promise<ProductFindDocument> {
  return await api.find(Product, String(atomProductId), {
    include: "legaldocuments",
  });
}

function findDocument(document: Document[], key: string): Document | undefined {
  const trimmed = key.trim();
  const lower = trimmed.toLowerCase();
  return document.find(
    (e) =>
      e.documentType === trimmed ||
      e.name === trimmed ||
      e.id === trimmed ||
      e.documentType.toLowerCase() === lower ||
      e.name.toLowerCase() === lower,
  );
}

export async function discoverDocuments(
  api: JsonApiService,
  atomProductId: number
) {
  const doc = await fetchProductWithLegalDocuments(api, atomProductId);
  const documents = documentsFromProductFind(doc);

  const results: Array<{
    id: string;
    name: string;
    sourceDocumentFormat: string;
    documentFormat: string;
  }> = [];

  for (const document of documents) {
    results.push({
      id: document.id,
      name: document.name,
      sourceDocumentFormat: document.name,
      documentFormat: document.documentType,
    });
  }
  return {
    documents: results,
    formatsDiscovered: documents.map((document) => document.documentType),
  };
}

export async function fetchDocumentHtml(
  api: JsonApiService,
  atomProductId: number,
  documentType: string,
  language: string,
  date?: string,
): Promise<string> {
  const day = date ?? new Date().toISOString().split("T")[0];
  const path =
    `products/${atomProductId}/document/${documentType}/html/${language}/${day}`;
  const { body, status } = await api.getVisualiseLegalDocuments(path);
  if (status < 200 || status >= 300) {
    throw new Error(`Document not found: ${documentType}/${language}`);
  }
  return await body.text();
}
