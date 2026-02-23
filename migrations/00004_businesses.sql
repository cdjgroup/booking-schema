-- 00004: Businesses table (the core tenant entity)

CREATE TABLE public.businesses (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  slug        extensions.citext NOT NULL UNIQUE,
  description TEXT DEFAULT '',
  timezone    TEXT NOT NULL DEFAULT 'America/New_York',
  settings    JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Slug must be URL-safe: lowercase letters, numbers, hyphens only, 3-63 chars
  CONSTRAINT valid_slug CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'),
  -- Prevent collisions with Next.js routes and reserved paths
  CONSTRAINT no_reserved_slug CHECK (slug NOT IN (
    'admin', 'api', 'auth', 'book', 'dashboard', 'login', 'logout',
    'settings', 'signup', '_next', 'favicon', 'robots', 'sitemap'
  ))
);

COMMENT ON TABLE public.businesses IS 'Multi-tenant root: each business has services, staff, and bookings';
COMMENT ON COLUMN public.businesses.slug IS 'URL-safe identifier for public booking page (e.g., /book/acme-salon)';
COMMENT ON COLUMN public.businesses.settings IS 'Flexible JSONB for business-level config (booking window, cancellation policy, etc.)';

CREATE INDEX idx_businesses_owner ON public.businesses(owner_id);
CREATE INDEX idx_businesses_slug ON public.businesses(slug);

CREATE TRIGGER set_businesses_updated_at
  BEFORE UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_updated_at();

-- RLS helper: returns TRUE if the calling user owns the business.
-- Used by child tables (services, staff, customers, bookings) to check ownership
-- without repeating the join logic in every policy.
-- SECURITY DEFINER runs with the function owner's privileges (bypasses RLS on
-- the businesses table), which is necessary so child-table policies can read it.
-- Defined here (not in 00002) because LANGUAGE sql validates table refs at creation time.
CREATE OR REPLACE FUNCTION public.is_business_owner(_business_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.businesses
    WHERE id = _business_id
      AND owner_id = (SELECT auth.uid())
  );
$$;

-- RLS
ALTER TABLE public.businesses ENABLE ROW LEVEL SECURITY;

-- Owners can do everything with their own businesses
CREATE POLICY "Owners can read own businesses"
  ON public.businesses FOR SELECT
  TO authenticated
  USING (owner_id = (SELECT auth.uid()));

CREATE POLICY "Owners can insert businesses"
  ON public.businesses FOR INSERT
  TO authenticated
  WITH CHECK (owner_id = (SELECT auth.uid()));

CREATE POLICY "Owners can update own businesses"
  ON public.businesses FOR UPDATE
  TO authenticated
  USING (owner_id = (SELECT auth.uid()))
  WITH CHECK (owner_id = (SELECT auth.uid()));

CREATE POLICY "Owners can delete own businesses"
  ON public.businesses FOR DELETE
  TO authenticated
  USING (owner_id = (SELECT auth.uid()));

-- Anonymous users can view businesses (public booking page)
CREATE POLICY "Anyone can view businesses"
  ON public.businesses FOR SELECT
  TO anon
  USING (true);
