-- 00006: Staff table (people who provide services)

CREATE TABLE public.staff (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  user_id       UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  name          TEXT NOT NULL,
  email         TEXT,
  role          TEXT NOT NULL DEFAULT 'provider'
                CHECK (role IN ('owner', 'provider', 'admin')),
  is_active     BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.staff IS 'Staff members who provide services. user_id is nullable -- staff do not need login accounts.';
COMMENT ON COLUMN public.staff.user_id IS 'Optional link to auth user. NULL for staff who only appear on the schedule.';
COMMENT ON COLUMN public.staff.role IS 'Text + CHECK instead of enum to avoid ALTER TYPE migration pain.';

CREATE INDEX idx_staff_business ON public.staff(business_id);
CREATE INDEX idx_staff_user ON public.staff(user_id) WHERE user_id IS NOT NULL;
CREATE INDEX idx_staff_active ON public.staff(business_id) WHERE is_active = true;

CREATE TRIGGER set_staff_updated_at
  BEFORE UPDATE ON public.staff
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_updated_at();

-- RLS
ALTER TABLE public.staff ENABLE ROW LEVEL SECURITY;

-- Business owners have full CRUD
CREATE POLICY "Owners can read own staff"
  ON public.staff FOR SELECT
  TO authenticated
  USING (public.is_business_owner(business_id));

CREATE POLICY "Owners can insert staff"
  ON public.staff FOR INSERT
  TO authenticated
  WITH CHECK (public.is_business_owner(business_id));

CREATE POLICY "Owners can update own staff"
  ON public.staff FOR UPDATE
  TO authenticated
  USING (public.is_business_owner(business_id))
  WITH CHECK (public.is_business_owner(business_id));

CREATE POLICY "Owners can delete own staff"
  ON public.staff FOR DELETE
  TO authenticated
  USING (public.is_business_owner(business_id));

-- Anonymous users can see active staff (for booking page)
CREATE POLICY "Anyone can view active staff"
  ON public.staff FOR SELECT
  TO anon
  USING (is_active = true);
