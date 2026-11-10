-- Product packs (Atom). Port of bravigo-migration packs/bbm 20261107150000_bbm_product_packs.sql
-- to the backoffice schema: table, label validators and reorder RPC live in `backoffice`.
BEGIN;

CREATE OR REPLACE FUNCTION backoffice.valid_product_pack_color(value json)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT SET search_path = '' AS $$
DECLARE
  item json;
  stop_position numeric;
  previous_position numeric := -1;
BEGIN
  IF json_typeof(value) IS DISTINCT FROM 'object' THEN RETURN false; END IF;
  IF value ->> 'type' = 'solid' THEN
    RETURN json_typeof(value -> 'value') IS NOT DISTINCT FROM 'string'
      AND btrim(COALESCE(value ->> 'value', '')) <> '';
  END IF;
  IF value ->> 'type' IS DISTINCT FROM 'linear-gradient'
    OR json_typeof(value -> 'colors') IS DISTINCT FROM 'array'
    OR json_typeof(value -> 'locations') IS DISTINCT FROM 'array' THEN RETURN false; END IF;
  IF json_array_length(value -> 'colors') < 2 OR
    json_array_length(value -> 'colors') <> json_array_length(value -> 'locations') THEN RETURN false; END IF;
  FOR item IN SELECT * FROM json_array_elements(value -> 'colors') LOOP
    IF json_typeof(item) IS DISTINCT FROM 'string' OR btrim(item #>> '{}') = '' THEN RETURN false; END IF;
  END LOOP;
  FOR item IN SELECT * FROM json_array_elements(value -> 'locations') LOOP
    IF json_typeof(item) IS DISTINCT FROM 'number' THEN RETURN false; END IF;
    stop_position := (item #>> '{}')::numeric;
    IF stop_position < 0 OR stop_position > 1 OR stop_position < previous_position THEN RETURN false; END IF;
    previous_position := stop_position;
  END LOOP;
  FOR item IN SELECT * FROM json_array_elements(json_build_array(value -> 'start', value -> 'end')) LOOP
    IF json_typeof(item) IS DISTINCT FROM 'object' OR json_typeof(item -> 'x') IS DISTINCT FROM 'number'
      OR json_typeof(item -> 'y') IS DISTINCT FROM 'number' THEN RETURN false; END IF;
    IF (item ->> 'x')::numeric NOT BETWEEN 0 AND 1 OR (item ->> 'y')::numeric NOT BETWEEN 0 AND 1 THEN RETURN false; END IF;
  END LOOP;
  RETURN (value -> 'start' ->> 'x')::numeric <> (value -> 'end' ->> 'x')::numeric
    OR (value -> 'start' ->> 'y')::numeric <> (value -> 'end' ->> 'y')::numeric;
END;
$$;

CREATE OR REPLACE FUNCTION backoffice.valid_product_pack_labels(value json)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path = '' AS $$
  SELECT json_typeof(value) = 'array' AND NOT EXISTS (
    SELECT 1 FROM json_array_elements(CASE WHEN json_typeof(value) = 'array'
      THEN value ELSE '[]'::json END) AS items(item)
    WHERE json_typeof(item) IS DISTINCT FROM 'object'
      OR json_typeof(item -> 'label') IS DISTINCT FROM 'string'
      OR btrim(COALESCE(item ->> 'label', '')) = ''
      OR (COALESCE(json_typeof(item -> 'color'), 'null') <> 'null'
        AND backoffice.valid_product_pack_color(item -> 'color') IS DISTINCT FROM true)
  );
$$;
CREATE TABLE IF NOT EXISTS backoffice.bo_product_packs (
  "productId" integer NOT NULL CONSTRAINT bo_product_packs_product_id_check CHECK ("productId" > 0),
  "packId" text NOT NULL CHECK (length(btrim("packId")) > 0),
  "packName" text NOT NULL CHECK (length(btrim("packName")) > 0),
  value integer CONSTRAINT bo_product_packs_value_check CHECK (value > 0),
  labels json NOT NULL DEFAULT '[]'::json
    CONSTRAINT bo_product_packs_labels_check CHECK (backoffice.valid_product_pack_labels(labels)),
  "sortOrder" integer NOT NULL DEFAULT 0
    CONSTRAINT bo_product_packs_sort_order_check CHECK ("sortOrder" >= 0),
  "packValidityEnd" text,
  "packValidityTz" text,
  "offerValidityEnd" text,
  "offerValidityTz" text,
  "packOfferValidityEnd" text,
  "packOfferValidityTz" text,
  "packOfferId" text,
  "offerId" text,
  price numeric CONSTRAINT bo_product_packs_price_check
    CHECK (price >= 0 AND price != 'NaN'::numeric AND price != 'Infinity'::numeric),
  currency text,
  "providerName" text,
  CONSTRAINT bo_product_packs_pkey PRIMARY KEY ("productId", "packId")
);

-- Setup may reapply this squash to a table created by an earlier version.
-- Replace obsolete inline checks with the current validator. Keep legacy rows;
-- the new check is enforced for every subsequent insert/update.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'backoffice.bo_product_packs'::regclass
      AND conname = 'bo_product_packs_labels_check'
      AND position('valid_product_pack_labels' IN pg_get_constraintdef(oid)) > 0
  ) THEN
    ALTER TABLE backoffice.bo_product_packs
      DROP CONSTRAINT IF EXISTS bo_product_packs_labels_check,
      ADD CONSTRAINT bo_product_packs_labels_check
        CHECK (backoffice.valid_product_pack_labels(labels)) NOT VALID;
  END IF;
END;
$$;

-- End dates and timezones are stored as supplied by Atom. Live states are derived
-- by the Atom edge function at comparison time; no expired snapshots are persisted.
ALTER TABLE backoffice.bo_product_packs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON backoffice.bo_product_packs FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON backoffice.bo_product_packs TO authenticated;
GRANT ALL ON backoffice.bo_product_packs TO service_role;

DROP POLICY IF EXISTS "Backoffice viewers read product packs" ON backoffice.bo_product_packs;
CREATE POLICY "Backoffice viewers read product packs"
  ON backoffice.bo_product_packs FOR SELECT TO authenticated
  USING (public.is_backoffice_role('viewer'));

DROP POLICY IF EXISTS "Backoffice editors insert product packs" ON backoffice.bo_product_packs;
CREATE POLICY "Backoffice editors insert product packs"
  ON backoffice.bo_product_packs FOR INSERT TO authenticated
  WITH CHECK (public.is_backoffice_role('editor'));

DROP POLICY IF EXISTS "Backoffice editors update product packs" ON backoffice.bo_product_packs;
CREATE POLICY "Backoffice editors update product packs"
  ON backoffice.bo_product_packs FOR UPDATE TO authenticated
  USING (public.is_backoffice_role('editor'))
  WITH CHECK (public.is_backoffice_role('editor'));

DROP POLICY IF EXISTS "Backoffice editors delete product packs" ON backoffice.bo_product_packs;
CREATE POLICY "Backoffice editors delete product packs"
  ON backoffice.bo_product_packs FOR DELETE TO authenticated
  USING (public.is_backoffice_role('editor'));

CREATE INDEX IF NOT EXISTS bo_product_packs_order_idx
  ON backoffice.bo_product_packs ("productId", "sortOrder", "packId");

-- Atomic order update. Caller permissions and table RLS remain in effect.
CREATE OR REPLACE FUNCTION backoffice.reorder_product_packs(p_product_id integer, p_pack_ids text[])
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  saved_count integer;
  updated_count integer;
BEGIN
  IF p_pack_ids IS NULL OR cardinality(p_pack_ids) = 0 OR
    cardinality(p_pack_ids) <> (SELECT count(DISTINCT id) FROM unnest(p_pack_ids) AS ids(id)) THEN
    RAISE EXCEPTION 'Provide each saved pack ID exactly once';
  END IF;
  PERFORM 1 FROM backoffice.bo_product_packs WHERE "productId" = p_product_id FOR UPDATE;
  SELECT count(*) INTO saved_count FROM backoffice.bo_product_packs WHERE "productId" = p_product_id;
  IF saved_count <> cardinality(p_pack_ids) THEN
    RAISE EXCEPTION 'Saved packs changed. Reload before reordering';
  END IF;
  UPDATE backoffice.bo_product_packs p SET "sortOrder" = ids.position - 1
    FROM unnest(p_pack_ids) WITH ORDINALITY AS ids(id, position)
    WHERE p."productId" = p_product_id AND p."packId" = ids.id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  IF updated_count <> saved_count THEN
    RAISE EXCEPTION 'Unable to reorder all saved packs. Check permissions and reload';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION backoffice.reorder_product_packs(integer, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION backoffice.reorder_product_packs(integer, text[]) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
