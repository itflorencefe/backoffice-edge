-- Storage buckets (idempotent). Schema/policies live in baseline migration.
INSERT INTO storage.buckets (id, name, public) VALUES ('avatars', 'avatars', true) ON CONFLICT (id) DO NOTHING;
INSERT INTO storage.buckets (id, name, public) VALUES ('product-assets', 'product-assets', true) ON CONFLICT (id) DO NOTHING;
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('quiz-videos', 'quiz-videos', true, 52428800, ARRAY['video/mp4','video/webm','video/quicktime'])
ON CONFLICT (id) DO NOTHING;
