import { AtomProduct } from "./product.ts";

interface ValidityDto {
  validityStart: string | null;
  validityEnd: string | null;
  validityTz: string | null;
}

interface PackOfferDto extends ValidityDto {
  id: string | null;
  used: boolean | null;
  data: Record<string, unknown> | null;
}

interface OfferDto extends ValidityDto {
  id: string;
  providerId: string | null;
  name: string | null;
  price: number | null;
  currency: string | null;
  provider: string | null;
  packOffer: PackOfferDto;
}

export interface PackDto extends ValidityDto {
  id: string;
  name: string | null;
  offers: OfferDto[];
}

function getLocalizedName(name: unknown): string | null {
  if (typeof name === "string") return name.trim() ? name : null;
  if (!name || typeof name !== "object") return null;
  return Object.values(name).find(
    (value): value is string => typeof value === "string" && value.trim() !== "",
  ) ?? null;
}

/** Extract the date bounds from Atom's PostgreSQL-style validity range. */
function getValidityDetails(
  resource: { validity?: string | null; validityTz?: string | null },
): ValidityDto {
  const validity = resource.validity ?? null;
  const validityTz = resource.validityTz ?? null;
  const validityDetails: ValidityDto = { validityStart: null, validityEnd: null, validityTz };
  if (typeof validity !== 'string') return validityDetails;
  const validityRangeMatch = /^[[(]\s*("[^"]*"|[^,]*),\s*("[^"]*"|[^,]*)\s*([)\]])$/.exec(validity.trim());
  if (!validityRangeMatch) return validityDetails;
  validityDetails.validityStart = validityRangeMatch[1].trim().replace(/^"|"$/g, '').trim() || null;
  validityDetails.validityEnd = validityRangeMatch[2].trim().replace(/^"|"$/g, '').trim() || null;
  return validityDetails;
}

export class AtomPacks extends AtomProduct {
  async getPacks(atomProductId: number): Promise<{ packs: PackDto[] }> {
    const { offers } = await this.getProduct(
      atomProductId,
      "offers,offers.packoffers.pack,offers.platform,offers.currency",
    );
    const packs: PackDto[] = [];
    // Arrays hold the output; indexes avoid rescanning them for every link.
    const packsById: Record<string, {
      packDetails: PackDto;
      includedOffers: Record<string, boolean>;
    }> = Object.create(null);

    for (const offer of offers ?? []) {
      if (offer.id == null || String(offer.id).trim() === "") continue;
      const offerId = String(offer.id);
      const offerDetails: Omit<OfferDto, "packOffer"> = {
        id: offerId,
        providerId: offer.platform?.id == null ? null : String(offer.platform.id),
        name: getLocalizedName(offer.name),
        ...getValidityDetails(offer),
        price: offer.price ?? null,
        currency: offer.currency?.id != null && String(offer.currency.id).trim() !== ""
          ? String(offer.currency.id)
          : null,
        provider: getLocalizedName(offer.platform?.name),
      };
      for (const packOffer of offer.packoffers ?? []) {
        const pack = packOffer?.pack;
        if (pack?.id == null || String(pack.id).trim() === "") continue;
        const packId = String(pack.id);
        let packGroup = packsById[packId];
        if (!packGroup) {
          const packDetails: PackDto = {
            id: packId,
            name: getLocalizedName(pack.name),
            ...getValidityDetails(pack),
            offers: [],
          };
          packGroup = { packDetails, includedOffers: Object.create(null) };
          packsById[packId] = packGroup;
          packs.push(packDetails);
        }
        const packOfferId = packOffer.id != null && String(packOffer.id).trim() !== "" ? String(packOffer.id) : null;
        const offerKey = JSON.stringify([offerId, packOfferId]);
        if (packGroup.includedOffers[offerKey]) continue;

        const packOfferDetails: PackOfferDto = {
          id: packOfferId,
          ...getValidityDetails(packOffer),
          used: packOffer.used ?? null,
          data: packOffer.data ?? null,
        };
        packGroup.packDetails.offers.push({ ...offerDetails, packOffer: packOfferDetails });
        packGroup.includedOffers[offerKey] = true;
      }
    }
    return { packs };
  }
}
