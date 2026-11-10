import type { ProductPack, SavedPackWarning } from "./index.ts";
import type { PackDto } from "../_shared/atom/packs.ts";

export interface AtomValidity {
  validityEnd: string | null;
  validityTz: string | null;
}

const timezoneFormatters = new Map<string, Intl.DateTimeFormat>();

/** Reuse date results and timezone conversions only for this check's fixed instant. */
export function createLiveCheck(now = Date.now()): (value: AtomValidity) => boolean | null {
  const results = new Map<string, boolean | null>();
  const timezoneTimes = new Map<string, number | null>();
  return (value) => {
    const key = JSON.stringify([value.validityEnd, value.validityTz]);
    if (results.has(key)) return results.get(key)!;
    const live = calculateLive(value, now, timezoneTimes);
    results.set(key, live);
    return live;
  };
}

/** End bounds are exclusive. Compare naive Atom dates in their declared timezone. */
function calculateLive(value: AtomValidity, now: number, timezoneTimes: Map<string, number | null>): boolean | null {
  const end = value.validityEnd?.trim();
  if (end == null || end === 'infinity') return true;
  if (end === '-infinity') return false;
  const match = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?(Z|[+-]\d{2}(?::?\d{2})?)?)?$/.exec(end);
  if (!match || !Number.isFinite(now)) return null;
  const [, year, month, day, hour, minute, second, fraction, zone] = match;
  const date = new Date(`${year}-${month}-${day}T00:00:00Z`);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== `${year}-${month}-${day}` ||
      Number(hour ?? 0) > 23 || Number(minute ?? 0) > 59 || Number(second ?? 0) > 59) return null;
  const timestamp = `${year}-${month}-${day}T${hour ?? '00'}:${minute ?? '00'}:${second ?? '00'}${fraction ?? ''}`;
  if (zone) {
    const offset = zone.replace(/([+-]\d{2})$/, '$1:00');
    const endTime = Date.parse(timestamp + offset);
    return Number.isFinite(endTime) ? now < endTime : null;
  }
  if (!value.validityTz) return null;
  if (!timezoneTimes.has(value.validityTz)) {
    let localNow: number | null = null;
    try {
      let formatter = timezoneFormatters.get(value.validityTz);
      if (!formatter) {
        formatter = new Intl.DateTimeFormat('en-US', {
          timeZone: value.validityTz, year: 'numeric', month: '2-digit', day: '2-digit',
          hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
        });
        timezoneFormatters.set(value.validityTz, formatter);
      }
      const parts = Object.fromEntries(formatter.formatToParts(new Date(now)).map(({ type, value }) => [type, value]));
      localNow = Date.parse(`${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}Z`) + now % 1000;
    } catch {
      // Reuse unknown results for invalid timezones within this check too.
    }
    timezoneTimes.set(value.validityTz, localNow);
  }
  const localNow = timezoneTimes.get(value.validityTz)!;
  return localNow === null ? null : localNow < Date.parse(timestamp + 'Z');
}

export function compareSavedPacksWithAtom(saved: readonly ProductPack[], catalog: readonly PackDto[], now = Date.now()): SavedPackWarning[] {
  const live = createLiveCheck(now);
  const packs = new Map(catalog.map((pack) => [pack.id, pack]));
  const warnings: SavedPackWarning[] = [];
  for (const record of saved) {
    const pack = packs.get(record.packId);
    const prefix = `${record.packName} (Pack ID ${record.packId})`;
    const add = (code: SavedPackWarning['code'], detail: string) => warnings.push({ packId: record.packId, code, message: `${prefix}: ${detail}` });
    const savedPack = { validityEnd: record.packValidityEnd, validityTz: record.packValidityTz };
    const savedOffer = { validityEnd: record.offerValidityEnd, validityTz: record.offerValidityTz };
    const savedPackOffer = { validityEnd: record.packOfferValidityEnd, validityTz: record.packOfferValidityTz };
    if (!pack) {
      if (live(savedPack) === true || (record.offerId && (live(savedOffer) === true || live(savedPackOffer) === true))) {
        add('pack-missing', 'saved as live but no longer present in the Atom catalog; pack and offer availability cannot be verified.');
      }
      continue;
    }
    const checkExpiry = (code: SavedPackWarning['code'], name: string, previous: AtomValidity, current: AtomValidity) => {
      const previousLive = live(previous);
      const currentLive = live(current);
      if (previousLive !== currentLive) {
        add(code, `${name} live changed: database ${previousLive ?? 'unknown'}, Atom ${currentLive ?? 'unknown'}.`);
      }
    };
    checkExpiry('pack-expiry-changed', 'pack', savedPack, pack);
    let offer: PackDto["offers"][number] | undefined;
    let linkedOffer: PackDto["offers"][number] | undefined;
    let offerCount = 0;
    for (const candidate of pack.offers) {
      if (candidate.id !== record.offerId) continue;
      offer ??= candidate;
      offerCount++;
      if (record.packOfferId != null && candidate.packOffer.id === record.packOfferId) {
        linkedOffer ??= candidate;
      }
    }
    if (!offer) {
      if (record.offerId && (live(savedOffer) === true || live(savedPackOffer) === true)) add('offer-missing', `selected offer ${record.offerId} or its pack offer is saved as live but no longer present on this Atom pack.`);
      continue;
    }
    checkExpiry('offer-expiry-changed', `selected offer ${offer.id}`, savedOffer, offer);
    if (record.price !== offer.price) add('price-changed', `selected offer ${offer.id} price differs: database ${formatPrice(record.price, record.currency)}, Atom ${formatPrice(offer.price, offer.currency)}.`);
    if (record.packOfferId == null && offerCount === 1) linkedOffer = offer;
    if (!linkedOffer) {
      add(record.packOfferId == null ? 'pack-offer-ambiguous' : 'pack-offer-missing', record.packOfferId == null
        ? `selected offer ${offer.id} has multiple pack offers on Atom; select and save the correct association to compare its expiry.`
        : `selected pack offer ${record.packOfferId} is no longer present on this Atom offer.`);
    } else {
      checkExpiry('pack-offer-expiry-changed', `pack offer for selected offer ${offer.id}`, savedPackOffer, linkedOffer.packOffer);
    }
  }
  return warnings;
}

function formatPrice(price: number | null | undefined, currency?: string | null): string {
  if (price == null) return 'Unavailable';
  const amount = new Intl.NumberFormat('en', { minimumFractionDigits: 2, maximumFractionDigits: 6 }).format(price);
  return currency?.trim() ? `${amount} ${currency.trim()}` : amount;
}
