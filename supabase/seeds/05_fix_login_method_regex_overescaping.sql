-- ===========================================================================
-- Fix over-escaped regex values in bo_product_login_methods.config
-- ---------------------------------------------------------------------------
-- Historical: seed 04 used to import login methods with over-escaped regexes.
-- Those inserts were removed when login methods moved to email/msisdn/google/
-- apple channels (20261106120000). This file stays as an idempotent no-op when
-- no matching rows exist (typical after reset).
--
-- This migration is a forward, idempotent repair:
--   * Guarded WHERE clauses only match rows that STILL contain a doubled
--     backslash, so re-runs (and already-fixed production rows) are no-ops.
--   * jsonb_set rewrites only the single affected key, leaving every other
--     config key, row, manual edit, and later-added product untouched.
--   * Conservative replacements: only the known sequences are collapsed
--     (\\d -> \d, \\s -> \s, \\. -> \.), so nothing else can be altered.
-- ===========================================================================

-- Fix password_regex: collapse "\\d" -> "\d"
UPDATE backoffice.product_login_methods
SET config = jsonb_set(
      config,
      '{password_regex}',
      to_jsonb(replace(config->>'password_regex', E'\\\\d', E'\\d'))
    )
WHERE config ? 'password_regex'
  AND strpos(config->>'password_regex', E'\\\\d') > 0;
-- Fix email_regex: collapse "\\s" -> "\s" and "\\." -> "\."
UPDATE backoffice.product_login_methods
SET config = jsonb_set(
      config,
      '{email_regex}',
      to_jsonb(
        replace(
          replace(config->>'email_regex', E'\\\\s', E'\\s'),
          E'\\\\.', E'\\.'
        )
      )
    )
WHERE config ? 'email_regex'
  AND (
        strpos(config->>'email_regex', E'\\\\s') > 0
     OR strpos(config->>'email_regex', E'\\\\.') > 0
  );
