-- 00010: Auto-enable RLS on any new table created in the public schema.
-- Safety net: if a future migration forgets ALTER TABLE ... ENABLE ROW LEVEL SECURITY,
-- this event trigger catches it automatically.
-- Only applies to public schema tables; system schemas are excluded.

CREATE OR REPLACE FUNCTION public.auto_enable_rls()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  obj RECORD;
BEGIN
  FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
  LOOP
    IF obj.command_tag = 'CREATE TABLE' THEN
      -- Only auto-enable on public schema tables
      IF obj.schema_name = 'public' THEN
        EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', obj.object_identity);
        RAISE NOTICE 'Auto-enabled RLS on %', obj.object_identity;
      END IF;
    END IF;
  END LOOP;
END;
$$;

CREATE EVENT TRIGGER auto_enable_rls_trigger
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE')
  EXECUTE FUNCTION public.auto_enable_rls();
