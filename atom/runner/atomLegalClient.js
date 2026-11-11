/**
 * Atom legal documents — minimal client for the reference runner.
 * Mirrors atom edge legal logic (Atom only, no Supabase).
 */

const { JsonApiService, Product } = require('@digitalvirgo/atom-api');

class AtomLegalError extends Error {
  constructor(message, { status, body } = {}) {
    super(message);
    this.name = 'AtomLegalError';
    this.status = status;
    this.body = body;
  }
}

class AtomLegalAuthError extends AtomLegalError {
  constructor(message, opts) {
    super(message, opts);
    this.name = 'AtomLegalAuthError';
  }
}

function normalizeEnvironment(raw) {
  return raw === 'staging' ? 'staging' : 'production';
}

function findDocument(documents, key) {
  const trimmed = key.trim();
  const lower = trimmed.toLowerCase();
  return documents.find(
    (e) =>
      e.documentType === trimmed ||
      e.name === trimmed ||
      e.id === trimmed ||
      e.documentType.toLowerCase() === lower ||
      e.name.toLowerCase() === lower,
  );
}

/** Resolves the Atom product id for the direct runner */
function resolveAtomProductIdFromParam(atomProductIdParam, locale) {
  const n = Number(atomProductIdParam);
  if ((typeof atomProductIdParam !== 'string' && typeof atomProductIdParam !== 'number') || !Number.isFinite(n)) {
    throw new AtomLegalError('atom_product_id must be a number');
  }
  const loc = String(locale ?? 'fr').toLowerCase();
  return { atomProductId: n, resolvedLocale: loc };
}

function requireAtomProductId(atomProductIdParam) {
  if (atomProductIdParam == null || (typeof atomProductIdParam === 'string' && !atomProductIdParam.trim())) {
    throw new AtomLegalError('atom product id is required');
  }
}

function documentFromLegalDocument(doc) {
  const documentType = typeof doc.documentType === 'string' ? doc.documentType.trim() : '';
  if (!documentType) return null;
  const name = String(doc.name ?? '').trim() || documentType;
  return { id: String(doc.id ?? ''), name, documentType };
}

function documentsFromProductFind(product) {
  const fromProduct = (product.legalDocuments ?? [])
    .map(documentFromLegalDocument)
    .filter((document) => document !== null);
  if (fromProduct.length > 0) return fromProduct;

  return (product.included ?? [])
    .filter((item) => item.type === undefined || item.type === 'legaldocuments')
    .map(documentFromLegalDocument)
    .filter((document) => document !== null);
}

/** Mirrors edge discoverDocuments */
function discoverDocuments(product) {
  const documents = documentsFromProductFind(product);
  return {
    documents: documents.map((document) => ({
      id: document.id,
      name: document.name,
      sourceDocumentFormat: document.name,
      documentFormat: document.documentType,
    })),
    formatsDiscovered: documents.map((document) => document.documentType),
  };
}

function normalizePlatformFilter(platformParam) {
  const platform = String(platformParam ?? '').trim().toLowerCase();
  if (!platform) {
    throw new AtomLegalError('platform is required');
  }
  return platform;
}

function skusFromProductFind(product, platformFilter) {
  const skus = [];
  let offerCount = 0;

  for (const offer of product.offers ?? []) {
    const platform = Object.values(offer.platform?.name ?? {}).find(
      (name) => typeof name === "string" && name.trim() !== "",
    );
    if (typeof platform !== "string") continue;
    if (platform.trim().toLowerCase() !== platformFilter) continue;

    const packs = [];
    for (const { pack } of offer.packoffers ?? []) {
      if (pack?.id == null) continue;
      const name = Object.values(pack.name ?? {}).find(
        (value) => typeof value === "string" && value.trim() !== "",
      );
      packs.push(typeof name === "string" ? name : String(pack.id));
    }
    if (packs.length === 0) continue;
    offerCount += 1;

    for (const capability of offer.offercapabilities ?? []) {
      const sku = capability.sku;
      if (sku?.id == null || sku.id === "") continue;
      const id = String(sku.id);
      let dto = skus.find((item) => item.id === id);
      if (!dto) {
        const name = Object.values(sku.name ?? {}).find(
          (value) => typeof value === "string" && value.trim() !== "",
        );
        dto = {
          id,
          name: typeof name === "string" ? name : "",
          external_id: sku.externalId ?? null,
          price: sku.price ?? null,
          units: sku.units ?? null,
        };
        skus.push(dto);
      }
    }
  }
  return { offerCount, skus };
}

async function fetchDocumentHtmlFromAtom(
  api,
  atomProductId,
  documentType,
  language,
  date,
) {
  const day = date?.trim() || new Date().toISOString().split('T')[0];
  const path = `products/${atomProductId}/document/${documentType}/html/${language}/${day}`;
  const { body, status } = await api.getVisualiseLegalDocuments(path);
  if (status < 200 || status >= 300) {
    throw new AtomLegalError(
      `Document not found: ${documentType}/${language}`,
      { status },
    );
  }
  return body.text();
}

/** Extract validity dates without calculating availability for offers or pack offers. */
function getValidityDetails(resource) {
  const result = { validityStart: null, validityEnd: null, validityTz: resource.validityTz ?? null };
  if (typeof resource.validity !== 'string') return result;
  const range = /^[[(]\s*("[^"]*"|[^,]*),\s*("[^"]*"|[^,]*)\s*([)\]])$/.exec(resource.validity.trim());
  if (!range) return result;
  result.validityStart = range[1].trim().replace(/^"|"$/g, '').trim() || null;
  result.validityEnd = range[2].trim().replace(/^"|"$/g, '').trim() || null;
  return result;
}

/** Pack expiry depends only on the upper bound of Atom's validity range. */
function expirationFromResource(resource, now) {
  const result = { ...getValidityDetails(resource), expired: null };
  const validityTz = result.validityTz;
  if (typeof resource.validity !== 'string') return result;
  const range = /^[[(]\s*("[^"]*"|[^,]*),\s*("[^"]*"|[^,]*)\s*([)\]])$/.exec(resource.validity.trim());
  if (!range) return result;
  const end = result.validityEnd;
  if (!end || end === 'infinity') return { ...result, expired: false };
  if (end === '-infinity') return { ...result, expired: true };
  // Reject non-ISO values rather than letting Date.parse guess a date format.
  if (!/^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}(?::?\d{2})?)?)?$/.test(end)) return result;
  const calendarDate = new Date(`${end.slice(0, 10)}T00:00:00Z`);
  if (!Number.isFinite(calendarDate.getTime()) || calendarDate.toISOString().slice(0, 10) !== end.slice(0, 10)) return result;
  let currentTime = now;
  let timestamp = end.replace(' ', 'T');
  if (!/(?:Z|[+-]\d{2}(?::?\d{2})?)$/.test(timestamp.slice(10))) {
    // Compare wall-clock dates in Atom's timezone, independent of the runner's TZ.
    if (!validityTz) return result;
    try {
      const parts = new Intl.DateTimeFormat('en-US', {
        timeZone: validityTz, year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
      }).formatToParts(new Date(now));
      const values = Object.fromEntries(parts.map(({ type, value }) => [type, value]));
      currentTime = Date.parse(`${values.year}-${values.month}-${values.day}T${values.hour}:${values.minute}:${values.second}Z`) + now % 1000;
    } catch {
      return result;
    }
    timestamp += timestamp.length === 10 ? 'T00:00:00Z' : 'Z';
  } else {
    timestamp = timestamp.replace(/([+-]\d{2})$/, '$1:00');
  }
  const endTime = Date.parse(timestamp);
  if (!Number.isFinite(endTime)) return result;
  return { ...result, expired: range[3] === ']' ? currentTime > endTime : currentTime >= endTime };
}

class AtomLegalClient {
  /**
   * @param {{ environment: string, staging?: object, production?: object }} options
   */
  constructor(options) {
    this.environment = normalizeEnvironment(options.environment);
    this.staging = options.staging ?? {};
    this.production = options.production ?? {};
    this._token = null;
  }

  getEnvConfig() {
    const block =
      this.environment === 'production' ? this.production : this.staging;
    const baseUrl = String(block.baseUrl ?? 'https://atom.digitalvirgo.com').replace(
      /\/+$/,
      '',
    );
    const user = String(block.user ?? '').trim();
    const pass = String(block.sdkAccessKey ?? block.pass ?? '').trim();
    return { baseUrl, user, pass };
  }

  async login() {
    const { baseUrl, user, pass } = this.getEnvConfig();
    if (!user || !pass) {
      throw new AtomLegalAuthError(
        `Missing user/sdkAccessKey for environment "${this.environment}" in config.json`,
      );
    }
    const credentials = Buffer.from(`${user}:${pass}`).toString('base64');
    const url = `${baseUrl}/auth/token`;
    let res;
    try {
      res = await fetch(url, {
        method: 'GET',
        headers: {
          Accept: 'application/vnd.api+json',
          Authorization: `Basic ${credentials}`,
        },
      });
    } catch (err) {
      const cause = err.cause?.message ?? err.cause ?? '';
      throw new AtomLegalAuthError(
        `Network error calling ${url}${cause ? `: ${cause}` : ''}`,
        {
          status: undefined,
          body: {
            hint: 'Check staging.baseUrl (not example.com) and VPN if required',
          },
        },
      );
    }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const detail = data?.errors?.[0]?.detail;
      throw new AtomLegalAuthError(
        `ATOM login failed: ${detail ?? `HTTP ${res.status}`}`,
        { status: res.status, body: data },
      );
    }
    const token = data.access_token;
    if (!token) {
      throw new AtomLegalAuthError('ATOM login: missing access_token', {
        body: data,
      });
    }
    this._token = token;
    return token;
  }

  async getApi() {
    if (!this._token) await this.login();
    const { baseUrl } = this.getEnvConfig();
    const token = this._token;
    return new JsonApiService({
      url: baseUrl,
      version: 'api',
      headers: () => ({ Authorization: `Bearer ${token}` }),
    });
  }

  async getProduct(atom_product_id, include) {
    requireAtomProductId(atom_product_id);
    const { atomProductId } = resolveAtomProductIdFromParam(atom_product_id);
    if (include != null && typeof include !== 'string') {
      throw new AtomLegalError('include must be a string');
    }
    const api = await this.getApi();
    const { data: product, included } = await api.find(
      Product, String(atomProductId), include ? { include } : undefined,
    );
    const dto = {
      snowplowId: product.snowplowId ?? null,
      phoneSupport: product.phoneSupport ?? null,
      emailSupport: product.emailSupport ?? null,
      smsPhoneSupport: product.smsPhoneSupport ?? null,
    };
    if (product.offers) dto.offers = product.offers;
    if (product.legaldocuments) dto.legalDocuments = product.legaldocuments;
    if (included) dto.included = included;
    return dto;
  }

  /** Return packs grouped by ID, with all associated offers and providers. */
  async getPacks(atom_product_id) {
    const { offers } = await this.getProduct(
      atom_product_id,
      'offers,offers.packoffers.pack,offers.platform,offers.currency',
    );
    const now = Date.now();
    const localizedName = (name) => {
      if (typeof name === 'string') return name.trim() ? name : null;
      return Object.values(name ?? {}).find(
        (value) => typeof value === 'string' && value.trim() !== '',
      ) ?? null;
    };
    const packs = new Map();
    for (const offer of offers ?? []) {
      if (offer.id == null || String(offer.id).trim() === '') continue;
      const offerDto = {
        id: String(offer.id),
        name: localizedName(offer.name),
        ...getValidityDetails(offer),
        price: offer.price ?? null,
        currency: offer.currency?.id != null && String(offer.currency.id).trim() !== ""
          ? String(offer.currency.id)
          : null,
        provider: offer.platform?.id != null && String(offer.platform.id).trim() !== ''
          ? { id: String(offer.platform.id), name: localizedName(offer.platform.name) }
          : null,
      };
      for (const link of offer.packoffers ?? []) {
        const pack = link?.pack;
        if (pack?.id == null || String(pack.id).trim() === '') continue;
        const id = String(pack.id);
        if (!packs.has(id)) {
          packs.set(id, { id, name: localizedName(pack.name), ...expirationFromResource(pack, now), offers: [] });
        }
        const packDto = packs.get(id);
        const packOffer = {
          id: link.id != null && String(link.id).trim() !== '' ? String(link.id) : null,
          ...getValidityDetails(link),
          used: link.used ?? null,
          data: link.data ?? null,
        };
        if (!packDto.offers.some((item) => item.id === offerDto.id && item.packOffer.id === packOffer.id)) {
          packDto.offers.push({ ...offerDto, packOffer });
        }
      }
    }
    return { packs: [...packs.values()] };
  }

  async discoverDocuments(atom_product_id, language) {
    requireAtomProductId(atom_product_id);
    const { atomProductId, resolvedLocale } = resolveAtomProductIdFromParam(
      atom_product_id,
      language,
    );
    const product = await this.getProduct(atomProductId, 'legaldocuments');
    const discovery = discoverDocuments(product);

    return {
      ok: true,
      requestedLanguage: resolvedLocale,
      ...discovery,
    };
  }

  /**
   * Same JSON shape as edge document mode (without Accept: text/html).
   * @param {string} format document type key (edge JSON field: format)
   */
  async fetchDocument(atom_product_id, format, language, date) {
    requireAtomProductId(atom_product_id);
    const { atomProductId, resolvedLocale } = resolveAtomProductIdFromParam(
      atom_product_id,
      language,
    );
    const api = await this.getApi();

    const formatKey = String(format ?? '').trim();
    if (!formatKey) {
      throw new AtomLegalError(
        'document_format (or format / document_slug) is required for document mode',
      );
    }

    const bodyHtml = await fetchDocumentHtmlFromAtom(
      api,
      atomProductId,
      formatKey,
      resolvedLocale,
      date,
    );

    return {
      ok: true,
      document: {
        slug: formatKey,
        locale: resolvedLocale,
        body_html: bodyHtml,
        updated_at: new Date().toISOString(),
      },
    };
  }

  /** Returns HTML string only (runner convenience). */
  async fetchDocumentHtml(atom_product_id, format, language, date) {
    const res = await this.fetchDocument(atom_product_id, format, language, date);
    return res.document.body_html;
  }

  async getProductSkus(atom_product_id, platform) {
    requireAtomProductId(atom_product_id);
    const requestedPlatform = normalizePlatformFilter(platform);
    const { atomProductId } = resolveAtomProductIdFromParam(atom_product_id, 'fr');
    const product = await this.getProduct(
      atomProductId,
      'offers.offercapabilities.sku,offers.platform,offers.packoffers.pack',
    );
    const { offerCount, skus } = skusFromProductFind(
      product,
      requestedPlatform,
    );

    return {
      ok: true,
      atom_product_id: atomProductId,
      platform: requestedPlatform,
      offer_count: offerCount,
      sku_count: skus.length,
      skus,
    };
  }
}

module.exports = {
  AtomLegalClient,
  AtomLegalError,
  AtomLegalAuthError,
  resolveAtomProductIdFromParam,
  discoverDocuments,
  documentFromLegalDocument,
  documentsFromProductFind,
  findDocument,
  fetchDocumentHtmlFromAtom,
  skusFromProductFind,
  normalizePlatformFilter,
};
