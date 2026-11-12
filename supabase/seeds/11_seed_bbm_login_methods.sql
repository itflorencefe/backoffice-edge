/*
  BBM pack seed: login methods for product za-bbm (service bbm).
  msisdn + google + email (OTP) for staging and production.
  Resolves product by slug. Unknown updated_by users are NULL.
*/
DO $$
DECLARE
  v_product uuid;
BEGIN
  SELECT p.id INTO v_product
  FROM backoffice.products p
  JOIN backoffice.services s ON s.id = p.service_id
  WHERE s.slug = 'bbm' AND p.slug = 'za-bbm';

  IF v_product IS NULL THEN
    RAISE NOTICE 'Skipped seed 11: product bbm/za-bbm not found';
    RETURN;
  END IF;

  INSERT INTO backoffice.product_login_methods (
    id, product_id, environment, type, enabled, is_default, display_order,
    label_i18n_key, icon, allow_signup, feature_flag, min_app_version, max_app_version,
    config, signup_url, updated_by
  )
  SELECT v.id, v_product, v.environment, v.type, v.enabled, v.is_default, v.display_order,
         v.label_i18n_key, v.icon, v.allow_signup, v.feature_flag, v.min_app_version, v.max_app_version,
         v.config, v.signup_url, v.updated_by
  FROM (VALUES
  ('f3a163f9-c2b7-4f4e-bb66-314600dc36ad'::uuid, 'staging', 'msisdn', true, false, 20,
   'login.tab.msisdn', 'phone', false, NULL, NULL, NULL,
   '{"mode":"otp","otp_length":6,"otp_channel":"sms","otp_ttl_seconds":300,"otp_max_attempts":5,"otp_numeric_only":true,"otp_resend_seconds":30,"error_message_i18n_key":"login.msisdn.error"}'::jsonb,
   NULL, NULL::uuid),
  ('47378a51-5ddf-44b6-bcab-4e3cefab6043'::uuid, 'production', 'msisdn', true, false, 20,
   'login.tab.msisdn', 'phone', false, NULL, NULL, NULL,
   '{"mode":"otp","otp_length":6,"otp_channel":"sms","otp_ttl_seconds":300,"otp_max_attempts":5,"otp_numeric_only":true,"otp_resend_seconds":30,"error_message_i18n_key":"login.msisdn.error"}'::jsonb,
   NULL, 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d'::uuid),
  ('8f57fe52-054f-40d4-96a3-76f5dc9f7093'::uuid, 'staging', 'google', true, false, 30,
   'login.tab.google', 'google', false, NULL, NULL, NULL,
   '{"app_id":""}'::jsonb,
   NULL, NULL::uuid),
  ('a674d554-081b-442c-a336-834bb3351dcb'::uuid, 'production', 'google', true, false, 30,
   'login.tab.google', 'google', false, NULL, NULL, NULL,
   '{"app_id":""}'::jsonb,
   NULL, 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d'::uuid),
  ('4d304bab-8010-4dbf-a934-0aa4dc8042b6'::uuid, 'staging', 'email', true, false, 40,
   'login.tab.email', 'mail', false, NULL, NULL, NULL,
   '{"mode":"otp","otp_length":6,"email_regex":"^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$","otp_channel":"email","otp_ttl_seconds":300,"otp_max_attempts":5,"otp_numeric_only":true,"email_regex_flags":"i","otp_resend_seconds":30,"error_message_i18n_key":"login.email.error"}'::jsonb,
   NULL, 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d'::uuid),
  ('bbb4dccf-1088-45d8-a586-f905413836da'::uuid, 'production', 'email', true, false, 40,
   'login.tab.email', 'mail', false, NULL, NULL, NULL,
   '{"mode":"otp","otp_length":6,"email_regex":"^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$","otp_channel":"email","otp_ttl_seconds":300,"otp_max_attempts":5,"otp_numeric_only":true,"email_regex_flags":"i","otp_resend_seconds":30,"error_message_i18n_key":"login.email.error"}'::jsonb,
   NULL, 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d'::uuid)
  ) AS v(
    id, environment, type, enabled, is_default, display_order,
    label_i18n_key, icon, allow_signup, feature_flag, min_app_version, max_app_version,
    config, signup_url, updated_by
  )
  ON CONFLICT (product_id, environment, type) DO NOTHING;
END $$;
