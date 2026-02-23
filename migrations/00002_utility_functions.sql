-- 00002: Utility functions used across tables

-- Trigger function: auto-set updated_at to NOW() on row update.
-- Attached to every table that has an updated_at column.
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;
