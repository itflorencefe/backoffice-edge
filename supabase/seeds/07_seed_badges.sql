-- XP badge catalog: Winfinity (export UUIDs) + Bravigo clones (stable UUIDs).
-- Safe to re-run: UPSERT on (id). description/event_id dropped in dual-schema Step 1.

INSERT INTO application.badges (
  id, name, image_url, criteria, created_at, service_id
)
VALUES

  -- Winfinity
  (
    'c7ea02c8-bcbf-46bc-8495-c82cacdea43a'::uuid,
    'Rookie',
    'file://assets/images/badges/rookie.png',
    '{"tier": "Rookie", "xpEarned": 500}'::jsonb,
    '2026-06-08 22:52:17.440161+00'::timestamptz,
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51'::uuid
  ),
  (
    '590b1964-d0db-4998-9761-1ab5745c99b6'::uuid,
    'Explorer',
    'file://assets/images/badges/explorer.png',
    '{"tier": "Explorer", "xpEarned": 10000}'::jsonb,
    '2026-06-08 22:52:17.440161+00'::timestamptz,
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51'::uuid
  ),
  (
    'a0089750-474b-4b3b-bcb8-67b0482f18cc'::uuid,
    'Challenger',
    'file://assets/images/badges/challenger.png',
    '{"tier": "Challenger", "xpEarned": 35000}'::jsonb,
    '2026-06-08 22:52:17.440161+00'::timestamptz,
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51'::uuid
  ),
  (
    '301b6af5-aff1-4055-89f8-edfc1429e5a1'::uuid,
    'Master',
    'file://assets/images/badges/master.png',
    '{"tier": "Master", "xpEarned": 100000}'::jsonb,
    '2026-06-08 22:52:17.440161+00'::timestamptz,
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51'::uuid
  ),
  (
    '8438b48b-63b7-418d-9c16-3ed24aa3b29e'::uuid,
    'Legend',
    'file://assets/images/badges/legend.png',
    '{"tier": "Legend", "xpEarned": 300000}'::jsonb,
    '2026-06-08 22:52:17.440161+00'::timestamptz,
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51'::uuid
  ),
  -- Bravigo (same tiers; stable UUIDs)
  (
    'd7fbb1f8-d132-5764-8e79-052529553e07'::uuid,
    'Rookie',
    'file://assets/images/badges/rookie.png',
    '{"tier": "Rookie", "xpEarned": 500}'::jsonb,
    '2026-06-08 22:52:17.440161+00'::timestamptz,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid
  ),
  (
    '7c8cd5c1-f0cb-5527-9503-37b0aafa9c30'::uuid,
    'Explorer',
    'file://assets/images/badges/explorer.png',
    '{"tier": "Explorer", "xpEarned": 10000}'::jsonb,
    '2026-06-08 22:52:17.440161+00'::timestamptz,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid
  ),
  (
    'e5495637-a712-556d-b2be-af29ebcc271a'::uuid,
    'Challenger',
    'file://assets/images/badges/challenger.png',
    '{"tier": "Challenger", "xpEarned": 35000}'::jsonb,
    '2026-06-08 22:52:17.440161+00'::timestamptz,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid
  ),
  (
    '666c0c49-9c2b-513d-a3d5-b8cb9bd49565'::uuid,
    'Master',
    'file://assets/images/badges/master.png',
    '{"tier": "Master", "xpEarned": 100000}'::jsonb,
    '2026-06-08 22:52:17.440161+00'::timestamptz,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid
  ),
  (
    'c80d60bc-3620-5770-8b5e-6d3830e83114'::uuid,
    'Legend',
    'file://assets/images/badges/legend.png',
    '{"tier": "Legend", "xpEarned": 300000}'::jsonb,
    '2026-06-08 22:52:17.440161+00'::timestamptz,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid
  )
ON CONFLICT (id) DO UPDATE SET
  name       = EXCLUDED.name,
  image_url  = EXCLUDED.image_url,
  criteria   = EXCLUDED.criteria,
  service_id = EXCLUDED.service_id;
