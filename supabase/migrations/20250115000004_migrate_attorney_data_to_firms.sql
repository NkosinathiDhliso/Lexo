-- Migrate attorney_users data to firms table
-- This migration copies existing attorney data to the new firms table structure

ALTER TABLE attorney_users
ADD COLUMN IF NOT EXISTS firm_name TEXT,
ADD COLUMN IF NOT EXISTS full_name TEXT,
ADD COLUMN IF NOT EXISTS first_name TEXT,
ADD COLUMN IF NOT EXISTS last_name TEXT,
ADD COLUMN IF NOT EXISTS practice_number TEXT,
ADD COLUMN IF NOT EXISTS phone_number TEXT,
ADD COLUMN IF NOT EXISTS address TEXT,
ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'active',
ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW(),
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW(),
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Insert data from attorney_users into firms table
-- Handle duplicates gracefully using ON CONFLICT
INSERT INTO firms (
  id,
  firm_name,
  attorney_name,
  practice_number,
  phone_number,
  email,
  address,
  status,
  created_at,
  updated_at
)
SELECT 
  id,
  COALESCE(firm_name, 'Unknown Firm') as firm_name,
  COALESCE(full_name, first_name || ' ' || last_name, 'Unknown Attorney') as attorney_name,
  practice_number,
  phone_number,
  email,
  COALESCE(address, '') as address,
  CASE 
    WHEN status = 'active' THEN 'active'
    WHEN status = 'inactive' THEN 'inactive'
    ELSE 'active'
  END as status,
  created_at,
  updated_at
FROM attorney_users
WHERE deleted_at IS NULL  -- Only migrate non-deleted attorneys
ON CONFLICT (email) DO UPDATE SET
  -- Update existing records if email already exists
  firm_name = EXCLUDED.firm_name,
  attorney_name = EXCLUDED.attorney_name,
  practice_number = EXCLUDED.practice_number,
  phone_number = EXCLUDED.phone_number,
  address = EXCLUDED.address,
  status = EXCLUDED.status,
  updated_at = NOW();

-- Log migration results
DO $$
DECLARE
  migrated_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO migrated_count FROM firms;
  RAISE NOTICE 'Migration complete: % firms in table', migrated_count;
END $$;

-- Add comment
COMMENT ON TABLE firms IS 'Migrated from attorney_users table - stores instructing law firms';

