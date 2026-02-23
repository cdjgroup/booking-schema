-- 00008: Customers table (people who book appointments)
-- These are NOT auth users -- they're created during the public booking flow.

CREATE TABLE public.customers (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  email         TEXT NOT NULL CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
  phone         TEXT,
  notes         TEXT DEFAULT '',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- One customer record per email per business
  CONSTRAINT unique_customer_email_per_business UNIQUE (business_id, email)
);

COMMENT ON TABLE public.customers IS 'Booking customers (not auth users). Created during anonymous booking flow.';

CREATE INDEX idx_customers_business ON public.customers(business_id);
CREATE INDEX idx_customers_email ON public.customers(business_id, email);

CREATE TRIGGER set_customers_updated_at
  BEFORE UPDATE ON public.customers
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_updated_at();

-- RLS
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

-- Business owners can manage customers
CREATE POLICY "Owners can read own customers"
  ON public.customers FOR SELECT
  TO authenticated
  USING (public.is_business_owner(business_id));

CREATE POLICY "Owners can update own customers"
  ON public.customers FOR UPDATE
  TO authenticated
  USING (public.is_business_owner(business_id))
  WITH CHECK (public.is_business_owner(business_id));

CREATE POLICY "Owners can delete own customers"
  ON public.customers FOR DELETE
  TO authenticated
  USING (public.is_business_owner(business_id));

CREATE POLICY "Owners can insert own customers"
  ON public.customers FOR INSERT
  TO authenticated
  WITH CHECK (public.is_business_owner(business_id));

-- Note: no anonymous INSERT or SELECT policies. Anonymous customer creation
-- and lookup happen inside the SECURITY DEFINER create_booking() function
-- (00009), which validates all inputs and prevents spam. This keeps PII safe
-- from scrapers. The authenticated INSERT policy above enables dashboard
-- customer creation by business owners.
