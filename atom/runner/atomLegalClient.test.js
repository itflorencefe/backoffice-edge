const test = require('node:test');
const assert = require('node:assert/strict');
const { AtomLegalClient } = require('./atomLegalClient');

const emptyPackOffer = {
  id: null, validityStart: null, validityEnd: null, validityTz: null, used: null, data: null,
};

test('getProductSkus filters by platform and pack links and deduplicates SKUs', async () => {
  const client = new AtomLegalClient({ environment: 'staging' });
  const sku = { id: 10, name: { en: '50 votes' }, externalId: 'votes.50', price: 0, units: 50 };
  const offer = {
    platform: { name: { en: 'AppStore' } },
    packoffers: [{ pack: { id: 50 } }],
    offercapabilities: [{ sku }, { sku }],
  };
  client.getProduct = async (id, include) => {
    assert.equal(id, 2582);
    assert.equal(include, 'offers.offercapabilities.sku,offers.platform,offers.packoffers.pack');
    return { offers: [
      offer,
      { ...offer, offercapabilities: [{ sku: { id: 11 } }] },
      { ...offer, platform: { name: { en: 'playstore' } }, offercapabilities: [{ sku: { id: 12 } }] },
      { ...offer, packoffers: [], offercapabilities: [{ sku: { id: 13 } }] },
    ] };
  };
  assert.deepEqual(await client.getProductSkus('2582', ' AppStore '), {
    ok: true, atom_product_id: 2582, platform: 'appstore', offer_count: 2, sku_count: 2,
    skus: [
      { id: '10', name: '50 votes', external_id: 'votes.50', price: 0, units: 50 },
      { id: '11', name: '', external_id: null, price: null, units: null },
    ],
  });
});

test('getProductSkus handles empty results and validates parameters before retrieval', async () => {
  const client = new AtomLegalClient({ environment: 'staging' });
  client.getProduct = async () => assert.fail('must not request a product');
  await assert.rejects(client.getProductSkus(null, 'appstore'), /product id is required/);
  await assert.rejects(client.getProductSkus(2582, ' '), /platform is required/);
  client.getProduct = async () => ({});
  assert.deepEqual(await client.getProductSkus(2582, 'playstore'), {
    ok: true, atom_product_id: 2582, platform: 'playstore', offer_count: 0, sku_count: 0, skus: [],
  });
});

test('getPacks groups all provider offers under each pack and deduplicates links', async () => {
  const client = new AtomLegalClient({ environment: 'staging' });
  const pack50 = { id: 50, name: { fr: '', en: '50 votes' } };
  const pack70 = { id: 70, name: '70 votes' };
  let requestedInclude;
  client.getProduct = async (id, include) => {
    assert.equal(id, 2930);
    requestedInclude = include;
    return {
      snowplowId: 'tracking',
      legalDocuments: [],
      included: [{ raw: true }],
      offers: [
        { id: 501, name: { en: 'Apple' }, price: 4.99, currency: { id: 1, name: { fr: '', en: 'EUR' } }, platform: { id: 1, name: { en: 'Apple' } },
          packoffers: [{ pack: pack50 }, { pack: pack50 }, { pack: pack70 }, null, {}] },
        { id: 502, name: 'Google', price: 0, currency: { id: 2, name: 'USD' }, platform: { id: 2, name: 'Google' },
          packoffers: [{ pack: pack50 }, { pack: pack70 }] },
        { id: 503, platform: { id: 1, name: 'Apple' }, packoffers: [{ pack: pack50 }] },
        { id: 504, currency: { id: '' }, packoffers: [{ pack: pack70 }, { pack: { id: '' } }] },
        { id: 505 },
        { packoffers: [{ pack: pack50 }] },
      ],
    };
  };
  const result = await client.getPacks(2930);
  assert.equal(requestedInclude, 'offers,offers.packoffers.pack,offers.platform,offers.currency');
  assert.deepEqual(result, {
    packs: [
      { id: '50', name: '50 votes', validityStart: null, validityEnd: null, validityTz: null, expired: null, offers: [
        { id: '501', name: 'Apple', validityStart: null, validityEnd: null, validityTz: null, packOffer: emptyPackOffer, price: 4.99, currency: '1', provider: { id: '1', name: 'Apple' } },
        { id: '502', name: 'Google', validityStart: null, validityEnd: null, validityTz: null, packOffer: emptyPackOffer, price: 0, currency: '2', provider: { id: '2', name: 'Google' } },
        { id: '503', name: null, validityStart: null, validityEnd: null, validityTz: null, packOffer: emptyPackOffer, price: null, currency: null, provider: { id: '1', name: 'Apple' } },
      ] },
      { id: '70', name: '70 votes', validityStart: null, validityEnd: null, validityTz: null, expired: null, offers: [
        { id: '501', name: 'Apple', validityStart: null, validityEnd: null, validityTz: null, packOffer: emptyPackOffer, price: 4.99, currency: '1', provider: { id: '1', name: 'Apple' } },
        { id: '502', name: 'Google', validityStart: null, validityEnd: null, validityTz: null, packOffer: emptyPackOffer, price: 0, currency: '2', provider: { id: '2', name: 'Google' } },
        { id: '504', name: null, validityStart: null, validityEnd: null, validityTz: null, packOffer: emptyPackOffer, price: null, currency: null, provider: null },
      ] },
    ],
  });
});

test('getPacks preserves pack-offer IDs, updates and distinct links independently of the offer', async (t) => {
  t.mock.method(Date, 'now', () => Date.parse('2026-11-07T12:00:00Z'));
  const client = new AtomLegalClient({ environment: 'staging' });
  const pack = { id: 50, validity: '(,infinity)', validityTz: 'UTC' };
  const link = {
    id: 9001, pack, validity: '(,2026-11-01T00:00:00Z)', validityTz: 'UTC',
    used: false, data: { campaign: 'updated' },
  };
  client.getProduct = async () => ({ offers: [{
    id: 501, price: 4.99, validity: '(,infinity)', validityTz: 'UTC',
    packoffers: [link, link, { ...link, id: 9002, validity: '(,infinity)', used: true, data: {} },
      { ...link, id: 9003, pack: { id: 70 } }],
  }] });
  const { packs } = await client.getPacks(2930);
  assert.equal(packs[0].expired, false);
  assert.deepEqual(packs[0].offers.map((offer) => offer.id), ['501', '501']);
  assert.equal('expired' in packs[0].offers[0], false);
  assert.equal('expired' in packs[0].offers[0].packOffer, false);
  assert.equal(packs[0].offers[0].price, 4.99);
  assert.deepEqual(packs[0].offers[0].packOffer, {
    id: '9001', validityStart: null, validityEnd: '2026-11-01T00:00:00Z',
    validityTz: 'UTC', used: false, data: { campaign: 'updated' },
  });
  assert.deepEqual(packs[0].offers[1].packOffer, {
    id: '9002', validityStart: null, validityEnd: 'infinity',
    validityTz: 'UTC', used: true, data: {},
  });
  assert.equal(packs[1].offers[0].packOffer.id, '9003');
  link.validity = '(,infinity)';
  link.data = { campaign: 'changed again' };
  const updated = await client.getPacks(2930);
  assert.equal(updated.packs[0].offers[0].packOffer.validityEnd, 'infinity');
  assert.equal('expired' in updated.packs[0].offers[0].packOffer, false);
  assert.deepEqual(updated.packs[0].offers[0].packOffer.data, { campaign: 'changed again' });
});

test('getPacks retains pack expiry and returns only validity dates for offers and pack offers', async (t) => {
  t.mock.method(Date, 'now', () => Date.parse('2026-11-06T12:00:00Z'));
  const client = new AtomLegalClient({ environment: 'staging' });
  const cases = [
    ['(,)', 'UTC', false],
    ['["2026-01-01 00:00:00","2026-11-06 12:00:00")', 'UTC', true],
    ['(,2026-11-06T12:00:00Z]', null, false],
    ['(,2026-11-06T12:00:00Z)', null, true],
    ['(,2026-11-06T13:00:00+02)', 'UTC', true],
    ['(,2026-11-06 12:30:00)', 'Europe/Rome', true],
    ['(,2026-11-06 12:30:00)', 'America/New_York', false],
    ['[2027-01-01,infinity)', 'UTC', false],
    ['(,2026-11-07)', 'UTC', false],
    [null, null, null],
    ['invalid', 'UTC', null],
    ['(,invalid)', 'UTC', null],
    ['(,2026-02-30T00:00:00Z)', 'UTC', null],
    ['(,2026-11-06 12:30:00)', 'invalid', null],
    ['(,2026-11-06 12:30:00)', null, null],
  ];
  client.getProduct = async () => ({ offers: cases.map(([validity, validityTz], i) => ({
    id: i, validity, validityTz,
    packoffers: [{ validity, validityTz, pack: { id: i, validity, validityTz } }],
  })) });
  const { packs } = await client.getPacks(2930);
  for (const [i, [validity, validityTz, expired]] of cases.entries()) {
    assert.equal(packs[i].expired, expired, String(validity));
    assert.equal('expired' in packs[i].offers[0], false);
    assert.equal('expired' in packs[i].offers[0].packOffer, false);
    const bounds = typeof validity === 'string'
      ? /^[[(]\s*("[^"]*"|[^,]*),\s*("[^"]*"|[^,]*)\s*([)\]])$/.exec(validity.trim())
      : null;
    assert.equal(packs[i].offers[0].validityStart, bounds?.[1].trim().replace(/^"|"$/g, '').trim() || null);
    assert.equal(packs[i].offers[0].validityEnd, bounds?.[2].trim().replace(/^"|"$/g, '').trim() || null);
    assert.equal('validity' in packs[i].offers[0], false);
    assert.equal(packs[i].offers[0].validityTz, validityTz);
    assert.equal(packs[i].offers[0].packOffer.validityStart, packs[i].offers[0].validityStart);
    assert.equal(packs[i].offers[0].packOffer.validityEnd, packs[i].offers[0].validityEnd);
    assert.equal(packs[i].offers[0].packOffer.validityTz, validityTz);
  }
});

test('getPacks returns an empty catalog for missing offers', async () => {
  const client = new AtomLegalClient({ environment: 'staging' });
  client.getProduct = async () => ({});
  assert.deepEqual(await client.getPacks(2930), { packs: [] });
});

test('legal discovery still uses product retrieval and included documents', async () => {
  const client = new AtomLegalClient({ environment: 'staging' });
  client.getProduct = async (id, include) => {
    assert.equal(id, 2930);
    assert.equal(include, 'legaldocuments');
    return { included: [{ id: '1', type: 'legaldocuments', name: 'Privacy', documentType: 'data_privacy' }] };
  };
  const result = await client.discoverDocuments(2930, 'FR');
  assert.equal(result.requestedLanguage, 'fr');
  assert.deepEqual(result.formatsDiscovered, ['data_privacy']);
});
