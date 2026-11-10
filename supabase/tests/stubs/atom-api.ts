/**
 * Test stand-in for the private `@digitalvirgo/atom-api` package (mapped in tests/deno.json).
 * Only what supabase/functions/_shared/atom uses: `JsonApiService.find` answers from
 * `atomStub.products`, keyed by Atom product id.
 */
// deno-lint-ignore-file no-explicit-any

export class Product {}
export class Offer {}
export class LegalDocument {}

export class JsonApiHttpError extends Error {
  constructor(message: string, public status: number, public errors: unknown[] = []) {
    super(message);
  }
}

export const atomStub = {
  products: new Map<string, Record<string, any>>(),
  finds: [] as { id: string; include?: string }[],
};

export class JsonApiService {
  constructor(_options: unknown) {}

  find(_model: unknown, id: string, params?: { include?: string }): Promise<{ data: Record<string, any> }> {
    atomStub.finds.push({ id, include: params?.include });
    const product = atomStub.products.get(id);
    if (!product) return Promise.reject(new JsonApiHttpError("Product not found", 404));
    return Promise.resolve({ data: product });
  }
}
