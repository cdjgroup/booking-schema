-- 00005: Services table (what a business offers)

CREATE TABLE public.services (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  description   TEXT DEFAULT '',
  duration_min  INTEGER NOT NULL CHECK (duration_min > 0 AND duration_min <= 1440),
  price_cents   INTEGER NOT NULL DEFAULT 0 CHECK (price_cents >= 0),
  color         TEXT DEFAULT '#3B82F6',
  sort_order    INTEGER NOT NULL DEFAULT 0,
  is_active     BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.services IS 'Bookable services offered by a business';
COMMENT ON COLUMN public.services.duration_min IS 'Service duration in minutes (1-1440, i.e. up to 24 hours)';
COMMENT ON COLUMN public.services.price_cents IS 'Price in cents (integer avoids floating-point issues, matches Stripe)';
COMMENT ON COLUMN public.services.color IS 'Hex color for calendar display';

CREATE INDEX idx_services_business ON public.services(business_id);
CREATE INDEX idx_services_active ON public.services(business_id) WHERE is_active = true;

CREATE TRIGGER set_services_updated_at
  BEFORE UPDATE ON public.services
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_updated_at();

-- RLS
ALTER TABLE public.services ENABLE ROW LEVEL SECURITY;

-- Business owners have full CRUD
CREATE POLICY "Owners can read own services"
  ON public.services FOR SELECT
  TO authenticated
  USING (public.is_business_owner(business_id));

CREATE POLICY "Owners can insert services"
  ON public.services FOR INSERT
  TO authenticated
  WITH CHECK (public.is_business_owner(business_id));

CREATE POLICY "Owners can update own services"
  ON public.services FOR UPDATE
  TO authenticated
  USING (public.is_business_owner(business_id))
  WITH CHECK (public.is_business_owner(business_id));

CREATE POLICY "Owners can delete own services"
  ON public.services FOR DELETE
  TO authenticated
  USING (public.is_business_owner(business_id));

-- Anonymous users can see active services (for booking page)
CREATE POLICY "Anyone can view active services"
  ON public.services FOR SELECT
  TO anon
  USING (is_active = true);
