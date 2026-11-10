import { assertEquals } from "@std/assert";
import { type FakeSupabase, loadFunction, post, readJson, withFake } from "./harness.ts";
import { atomStub } from "./stubs/atom-api.ts";

const ATOM_URL = "https://atom.test";
const handler = await loadFunction("atom", { ATOM_BASE_URL: ATOM_URL, ATOM_USER: "atom-user", ATOM_SDK_ACCESS_KEY: "atom-key" });

const PRODUCT = 2883;
const auth = { Authorization: "Bearer backoffice-jwt" };

atomStub.products.set(String(PRODUCT), {
  offers: [
    {
      id: 9981, name: { en: "Offer A" }, price: 4.99, validity: "[,)", validityTz: "UTC",
      platform: { id: 7, name: "Provider" }, currency: { id: "EUR" },
      packoffers: [{ id: "po-1", validity: '["2020-01-01 00:00:00","2099-01-01 00:00:00")', validityTz: "UTC", pack: { id: 32811, name: "Pack A", validity: "[,2000-01-01)", validityTz: "UTC" } }],
    },
  ],
  legaldocuments: [{ id: 5, name: "Terms", documentType: "terms" }],
});

/** Atom login and the backoffice role RPC (true only for the backoffice JWT). */
function routes(fake: FakeSupabase, isBackoffice = true) {
  fake.route((req, url) => {
    if (url.origin === ATOM_URL && url.pathname === "/auth/token") {
      return Response.json({ access_token: "atom-token" });
    }
    if (url.pathname === "/rest/v1/rpc/is_backoffice_role") {
      const bearer = req.headers.get("Authorization");
      return Response.json(isBackoffice && bearer === auth.Authorization);
    }
    return undefined;
  });
}

const call = (body: unknown, headers: Record<string, string> = {}) => handler(post("atom", body, headers));

Deno.test("atom: catalog and pack modes need a backoffice user, legal documents stay public", async () => {
  await withFake(async (fake) => {
    routes(fake);
    for (const mode of ["packs", "product", "checkLocalPacks", "skus"]) {
      const res = await call({ mode, atom_product_id: PRODUCT, platform: "ios" });
      assertEquals(res.status, 403, mode);
      assertEquals((await readJson(res)).error, "Backoffice access required");
    }
    const other = await call({ mode: "packs", atom_product_id: PRODUCT }, { Authorization: "Bearer app-user-jwt" });
    assertEquals(other.status, 403);
    await other.body?.cancel();

    const discover = await call({ mode: "discover", atom_product_id: PRODUCT, language: "IT" });
    assertEquals(discover.status, 200);
    assertEquals(await readJson(discover), {
      ok: true, requestedLanguage: "it",
      documents: [{ id: "5", name: "Terms", sourceDocumentFormat: "Terms", documentFormat: "terms" }],
      formatsDiscovered: ["terms"],
    });
  });
});

Deno.test("atom: packs returns Atom packs with live states computed by the edge", async () => {
  await withFake(async (fake) => {
    routes(fake);
    const res = await call({ mode: "packs", atom_product_id: PRODUCT }, auth);
    assertEquals(res.status, 200);
    const body = await readJson(res);
    assertEquals(body.packs, [{
      id: "32811", name: "Pack A", validityStart: null, validityEnd: "2000-01-01", validityTz: "UTC", live: false,
      offers: [{
        id: "9981", name: "Offer A", providerId: "7", provider: "Provider", price: 4.99, currency: "EUR",
        validityStart: null, validityEnd: null, validityTz: "UTC", live: true,
        packOffer: {
          id: "po-1", used: null, data: null,
          validityStart: "2020-01-01 00:00:00", validityEnd: "2099-01-01 00:00:00", validityTz: "UTC", live: true,
        },
      }],
    }]);
  });
});

Deno.test("atom: checkLocalPacks reads saved packs from backoffice and reports differences", async () => {
  await withFake(async (fake) => {
    routes(fake);
    const saved = {
      productId: PRODUCT, packId: "32811", packName: "Saved A", value: 10, labels: [], sortOrder: 0,
      packValidityEnd: null, packValidityTz: null, offerValidityEnd: null, offerValidityTz: "UTC",
      packOfferValidityEnd: "2099-01-01 00:00:00", packOfferValidityTz: "UTC", packOfferId: "po-1", offerId: "9981",
      price: 3.99, currency: "EUR", providerName: "Provider",
    };
    fake.seed("backoffice.bo_product_packs", [saved, { ...saved, productId: 1, packId: "other" }]);
    const res = await call({ mode: "checkLocalPacks", atom_product_id: PRODUCT }, auth);
    assertEquals(res.status, 200);
    assertEquals(res.headers.get("Cache-Control"), "no-store");
    const body = await readJson(res);
    assertEquals((body.packs as { packId: string }[]).map((p) => p.packId), ["32811"]);
    assertEquals((body.messages as { code: string }[]).map((m) => m.code), ["pack-expiry-changed", "price-changed"]);
    assertEquals(body.errors, []);

    // Atom unavailable: saved packs are still returned, with a check error instead of warnings.
    atomStub.products.delete("404");
    fake.seed("backoffice.bo_product_packs", [{ ...saved, productId: 404 }]);
    const down = await readJson(await call({ mode: "checkLocalPacks", atom_product_id: 404 }, auth));
    assertEquals([down.ok, (down.packs as unknown[]).length, (down.messages as unknown[]).length, (down.errors as unknown[]).length], [true, 1, 0, 1]);
  });
});

Deno.test("atom: request validation", async () => {
  await withFake(async (fake) => {
    routes(fake);
    const options = await handler(new Request("http://edge.test/atom", { method: "OPTIONS" }));
    assertEquals(options.status, 204);
    const getRes = await handler(new Request("http://edge.test/atom"));
    assertEquals(getRes.status, 405);
    await getRes.body?.cancel();
    for (const body of [{ mode: "nope", atom_product_id: 1 }, { mode: "packs" }, { mode: "documents", atom_product_id: 1 }]) {
      const res = await call(body, auth);
      assertEquals(res.status, 400);
      await res.body?.cancel();
    }
  });
});
