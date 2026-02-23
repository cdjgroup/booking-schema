-- 00007: Availability table (weekly schedule for staff)

-- RLS helper: checks if the caller owns the business that a staff member belongs to.
-- Traverses staff → business → owner. Used by availability policies.
CREATE OR REPLACE FUNCTION public.is_staff_business_owner(_staff_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff s
    JOIN public.businesses b ON b.id = s.business_id
    WHERE s.id = _staff_id
      AND b.owner_id = (SELECT auth.uid())
  );
$$;

CREATE TABLE public.availability (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id      UUID NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  day_of_week   SMALLINT NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  start_time    TIME NOT NULL,
  end_time      TIME NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- end_time must be after start_time (no overnight shifts in v1)
  CONSTRAINT valid_time_range CHECK (end_time > start_time),
  -- One entry per staff per day (can be relaxed later for split shifts)
  CONSTRAINT unique_staff_day UNIQUE (staff_id, day_of_week)
);

COMMENT ON TABLE public.availability IS 'Weekly recurring schedule. Uses TIME (not TIMESTAMPTZ) because this is a timezone-agnostic weekly pattern.';
COMMENT ON COLUMN public.availability.day_of_week IS '0=Sunday, 1=Monday, ..., 6=Saturday (JS Date.getDay() convention)';

CREATE INDEX idx_availability_staff ON public.availability(staff_id);

CREATE TRIGGER set_availability_updated_at
  BEFORE UPDATE ON public.availability
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_updated_at();

-- RLS
ALTER TABLE public.availability ENABLE ROW LEVEL SECURITY;

-- Business owners manage availability via staff→business chain
CREATE POLICY "Owners can read own availability"
  ON public.availability FOR SELECT
  TO authenticated
  USING (public.is_staff_business_owner(staff_id));

CREATE POLICY "Owners can insert availability"
  ON public.availability FOR INSERT
  TO authenticated
  WITH CHECK (public.is_staff_business_owner(staff_id));

CREATE POLICY "Owners can update own availability"
  ON public.availability FOR UPDATE
  TO authenticated
  USING (public.is_staff_business_owner(staff_id))
  WITH CHECK (public.is_staff_business_owner(staff_id));

CREATE POLICY "Owners can delete own availability"
  ON public.availability FOR DELETE
  TO authenticated
  USING (public.is_staff_business_owner(staff_id));

-- Anonymous users can see availability (for time slot selection)
CREATE POLICY "Anyone can view availability"
  ON public.availability FOR SELECT
  TO anon
  USING (true);
