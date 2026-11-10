import { AtomProduct, type ProductDto } from "./product.ts";

// Public DTO: explicitly selected fields; never forward Atom meta or credentials.
interface SkuDto {
  id: string;
  name: string;
  external_id: string | null;
  price: number | null;
  units: number | null;
}

function skusFromProductFind(
  product: ProductDto,
  platformFilter: string,
): { offerCount: number; skus: SkuDto[] } {
  const skus: SkuDto[] = [];
  let offerCount = 0;

  for (const offer of product.offers ?? []) {
    const platform = Object.values(offer.platform?.name ?? {}).find(
      (name) => typeof name === "string" && name.trim() !== "",
    );
    if (typeof platform !== "string") continue;
    if (platform.trim().toLowerCase() !== platformFilter) continue;

    const packs: string[] = [];
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
          units: sku.units ?? null
        };
        skus.push(dto);
      }
    }
  }
  return { offerCount, skus };
}

export class AtomSkus extends AtomProduct {
  async getSkus(atomProductId: number, platform: string) {
    const product = await this.getProduct(
      atomProductId,
      "offers.offercapabilities.sku,offers.platform,offers.packoffers.pack",
    );
    const { offerCount, skus } = skusFromProductFind(product, platform);
    return {
      atom_product_id: atomProductId,
      platform,
      offer_count: offerCount,
      sku_count: skus.length,
      skus,
    };
  }
}
