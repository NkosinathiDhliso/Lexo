-- Ensure legacy migrations can call public.uuid_generate_v4()
-- even when extensions are installed in the extensions schema.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;

DO $do$
BEGIN
  IF to_regprocedure('public.uuid_generate_v4()') IS NULL THEN
    IF to_regprocedure('extensions.uuid_generate_v4()') IS NOT NULL THEN
      EXECUTE $fn$
        CREATE FUNCTION public.uuid_generate_v4()
        RETURNS uuid
        LANGUAGE sql
        VOLATILE
        AS $$ SELECT extensions.uuid_generate_v4(); $$;
      $fn$;
    ELSIF to_regprocedure('extensions.gen_random_uuid()') IS NOT NULL THEN
      EXECUTE $fn$
        CREATE FUNCTION public.uuid_generate_v4()
        RETURNS uuid
        LANGUAGE sql
        VOLATILE
        AS $$ SELECT extensions.gen_random_uuid(); $$;
      $fn$;
    ELSIF to_regprocedure('public.gen_random_uuid()') IS NOT NULL THEN
      EXECUTE $fn$
        CREATE FUNCTION public.uuid_generate_v4()
        RETURNS uuid
        LANGUAGE sql
        VOLATILE
        AS $$ SELECT public.gen_random_uuid(); $$;
      $fn$;
    ELSE
      RAISE EXCEPTION 'Unable to locate uuid generation functions (uuid-ossp/pgcrypto).';
    END IF;
  END IF;
END
$do$;
