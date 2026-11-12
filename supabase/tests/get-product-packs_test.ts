import { assertEquals } from "@std/assert";
import { get, loadFunction, post, readJson, withFake } from "./harness.ts";

const handler = await loadFunction("get-product-packs");

const row = {
  productId: 2930, packId: "50", packName: "Configured pack", value: 150,
  labels: [{ label: "Most popular", color: { type: "solid", value: "#6650CF" } }],
  offerId: "offer-9", price: 4.99, currency: "PEN",
};

Deno.test("get-product-packs: returns the configured packs of one Atom product, in saved order", async () => {
  await withFake(async (fake) => {
    fake.seed("backoffice.product_packs", [
      { ...row, packId: "60", sortOrder: 1, price: "1.50", providerName: "hidden", packOfferId: "link" },
      { ...row, sortOrder: 0, providerName: "hidden", packValidityEnd: "2099-01-01" },
      { ...row, productId: 1, packId: "other", sortOrder: 0 },
    ]);
    for (const res of [
      await handler(get("get-product-packs", { atom_product_id: "2930" })),
      await handler(post("get-product-packs", { atom_product_id: 2930 })),
    ]) {
      assertEquals(res.status, 200);
      assertEquals(res.headers.get("Cache-Control"), "no-store");
      assertEquals(await readJson(res), { ok: true, packs: [row, { ...row, packId: "60", price: 1.5 }] });
    }
    const empty = await handler(get("get-product-packs", { atom_product_id: "77" }));
    assertEquals(await readJson(empty), { ok: true, packs: [] });
  });
});

Deno.test("get-product-packs: validation, methods and database failures", async () => {
  await withFake(async (fake) => {
    const options = await handler(new Request("http://edge.test/get-product-packs", { method: "OPTIONS" }));
    assertEquals(options.status, 204);
    const del = await handler(new Request("http://edge.test/get-product-packs?atom_product_id=1", { method: "DELETE" }));
    assertEquals(del.status, 405);
    await del.body?.cancel();
    for (const id of ["", "abc", "-1", "0", "1.5", "2147483648"]) {
      const res = await handler(get("get-product-packs", { atom_product_id: id }));
      assertEquals(res.status, 400, id);
      await res.body?.cancel();
    }
    const errors: unknown[] = [];
    const realError = console.error;
    console.error = (...args: unknown[]) => errors.push(args);
    try {
      fake.fail("backoffice.product_packs", "GET");
      const failed = await handler(get("get-product-packs", { atom_product_id: "2930" }));
      assertEquals(failed.status, 500);
      assertEquals(await readJson(failed), { ok: false, error: "Unable to load product packs." });
    } finally {
      console.error = realError;
    }
    assertEquals(errors.length, 1);
  });
});
