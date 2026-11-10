import { LegalDocument, Offer, Product } from "@digitalvirgo/atom-api";
import { Atom } from "./atom.ts";

export interface ProductDto {
  snowplowId: string | null;
  phoneSupport: string | null;
  emailSupport: string | null;
  smsPhoneSupport: string | null;
  offers?: Offer[];
  legalDocuments?: LegalDocument[];
  included?: LegalDocument[];
}

export class AtomProduct extends Atom {
  async getProduct(atomProductId: number, include?: string): Promise<ProductDto> {
    const api = await this.getApi();
    const { data: product } = await api.find(
      Product, String(atomProductId), include ? { include } : undefined,
    );
    const dto: ProductDto = {
      snowplowId: product.snowplowId ?? null,
      phoneSupport: product.phoneSupport ?? null,
      emailSupport: product.emailSupport ?? null,
      smsPhoneSupport: product.smsPhoneSupport ?? null,
    };
    if (product.offers) dto.offers = product.offers;
    if (product.legaldocuments) dto.legalDocuments = product.legaldocuments;
    if (product.included) dto.included = product.included as LegalDocument[];
    return dto;
  }
}
