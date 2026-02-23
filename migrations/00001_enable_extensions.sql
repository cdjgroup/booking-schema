-- 00001: Enable required PostgreSQL extensions
-- moddatetime: auto-update updated_at columns via trigger
-- citext: case-insensitive text type (for business slugs)
-- btree_gist: GiST index support for exclusion constraints (double-booking prevention)

CREATE EXTENSION IF NOT EXISTS moddatetime WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS btree_gist;
