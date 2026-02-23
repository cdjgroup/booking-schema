-- 00003: Profiles table (extends auth.users with app-specific fields)

CREATE TABLE public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name   TEXT,
  avatar_url  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.profiles IS 'App-level user profile, 1:1 with auth.users';

-- Auto-update updated_at on every UPDATE
CREATE TRIGGER set_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_updated_at();

-- Auto-create a profile row when a new user signs up.
-- This runs as SECURITY DEFINER so it can insert into profiles
-- even though the user hasn't been granted direct insert.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  _full_name TEXT;
  _avatar_url TEXT;
BEGIN
  -- Sanitize full_name: trim whitespace, cap at 255 chars
  _full_name := TRIM(LEFT(COALESCE(NEW.raw_user_meta_data ->> 'full_name', ''), 255));

  -- Sanitize avatar_url: only allow http(s) URLs, cap at 2048 chars
  _avatar_url := COALESCE(NEW.raw_user_meta_data ->> 'avatar_url', '');
  IF _avatar_url <> '' AND _avatar_url !~ '^https?://' THEN
    _avatar_url := '';  -- Reject non-URL values silently
  END IF;
  _avatar_url := LEFT(_avatar_url, 2048);

  INSERT INTO public.profiles (id, full_name, avatar_url)
  VALUES (NEW.id, _full_name, _avatar_url);
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- RLS: users can only read and update their own profile
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own profile"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (id = (SELECT auth.uid()));

CREATE POLICY "Users can update own profile"
  ON public.profiles FOR UPDATE
  TO authenticated
  USING (id = (SELECT auth.uid()))
  WITH CHECK (id = (SELECT auth.uid()));
