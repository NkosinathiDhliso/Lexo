-- ============================================================================
-- CREATE ATTORNEYS TABLE
-- Normalizes attorney storage - separates attorneys from firms
-- Each firm can have multiple attorneys
-- ============================================================================

-- Drop the table first if it exists (for clean retry)
DROP TABLE IF EXISTS attorneys CASCADE;

-- Create attorneys table
CREATE TABLE attorneys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  attorney_name TEXT NOT NULL,
  email TEXT NOT NULL,
  phone TEXT,
  practice_number TEXT,
  firm_id UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Ensure unique email per attorney
  CONSTRAINT attorneys_email_unique UNIQUE (email)
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_attorneys_firm_id ON attorneys(firm_id);
CREATE INDEX IF NOT EXISTS idx_attorneys_email ON attorneys(email);
CREATE INDEX IF NOT EXISTS idx_attorneys_status ON attorneys(status);
CREATE INDEX IF NOT EXISTS idx_attorneys_attorney_name ON attorneys(attorney_name);

-- Add updated_at trigger
CREATE OR REPLACE FUNCTION update_attorneys_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS attorneys_updated_at ON attorneys;
CREATE TRIGGER attorneys_updated_at
  BEFORE UPDATE ON attorneys
  FOR EACH ROW
  EXECUTE FUNCTION update_attorneys_updated_at();

-- Enable Row Level Security
ALTER TABLE attorneys ENABLE ROW LEVEL SECURITY;

-- RLS Policies for attorneys
-- Advocates can view attorneys from their firms
CREATE POLICY "Advocates can view attorneys from their firms"
  ON attorneys
  FOR SELECT
  TO authenticated
  USING (
    firm_id IN (
      SELECT id FROM firms WHERE advocate_id = auth.uid()
    )
  );

-- Advocates can insert attorneys to their firms
CREATE POLICY "Advocates can insert attorneys to their firms"
  ON attorneys
  FOR INSERT
  TO authenticated
  WITH CHECK (
    firm_id IN (
      SELECT id FROM firms WHERE advocate_id = auth.uid()
    )
  );

-- Advocates can update attorneys in their firms
CREATE POLICY "Advocates can update attorneys in their firms"
  ON attorneys
  FOR UPDATE
  TO authenticated
  USING (
    firm_id IN (
      SELECT id FROM firms WHERE advocate_id = auth.uid()
    )
  )
  WITH CHECK (
    firm_id IN (
      SELECT id FROM firms WHERE advocate_id = auth.uid()
    )
  );

-- Advocates can delete attorneys from their firms
CREATE POLICY "Advocates can delete attorneys from their firms"
  ON attorneys
  FOR DELETE
  TO authenticated
  USING (
    firm_id IN (
      SELECT id FROM firms WHERE advocate_id = auth.uid()
    )
  );

-- Add comments for documentation
COMMENT ON TABLE attorneys IS 'Stores attorneys from instructing law firms. Each firm can have multiple attorneys.';
COMMENT ON COLUMN attorneys.attorney_name IS 'Full name of the attorney';
COMMENT ON COLUMN attorneys.email IS 'Email address (unique per attorney)';
COMMENT ON COLUMN attorneys.phone IS 'Contact phone number';
COMMENT ON COLUMN attorneys.practice_number IS 'Attorney practice registration number';
COMMENT ON COLUMN attorneys.firm_id IS 'Reference to the law firm this attorney belongs to';
COMMENT ON COLUMN attorneys.status IS 'Active or inactive status';

-- ============================================================================
-- ADD ADVOCATE_ID TO FIRMS TABLE
-- Links firms to the advocate who added them
-- ============================================================================

-- Add advocate_id column to firms if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' 
    AND table_name = 'firms' 
    AND column_name = 'advocate_id'
  ) THEN
    ALTER TABLE firms ADD COLUMN advocate_id UUID;
    ALTER TABLE firms ADD CONSTRAINT firms_advocate_id_fkey 
      FOREIGN KEY (advocate_id) REFERENCES advocates(id) ON DELETE CASCADE;
    CREATE INDEX idx_firms_advocate_id ON firms(advocate_id);
    COMMENT ON COLUMN firms.advocate_id IS 'The advocate who added/manages this firm';
    
    -- Set advocate_id for all existing firms to the first advocate (temporary)
    -- You should manually update this to the correct advocate_id
    UPDATE firms 
    SET advocate_id = (SELECT id FROM advocates LIMIT 1)
    WHERE advocate_id IS NULL;
  END IF;
END $$;

-- Update RLS policies for firms to use advocate_id
DROP POLICY IF EXISTS "Advocates can view all firms" ON firms;
DROP POLICY IF EXISTS "Authenticated users can insert firms" ON firms;
DROP POLICY IF EXISTS "Authenticated users can update firms" ON firms;
DROP POLICY IF EXISTS "Authenticated users can delete firms" ON firms;

-- New policies using advocate_id
CREATE POLICY "Advocates can view their firms"
  ON firms
  FOR SELECT
  TO authenticated
  USING (advocate_id = auth.uid());

CREATE POLICY "Advocates can insert their firms"
  ON firms
  FOR INSERT
  TO authenticated
  WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "Advocates can update their firms"
  ON firms
  FOR UPDATE
  TO authenticated
  USING (advocate_id = auth.uid())
  WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "Advocates can delete their firms"
  ON firms
  FOR DELETE
  TO authenticated
  USING (advocate_id = auth.uid());

-- ============================================================================
-- MIGRATE EXISTING DATA
-- Convert existing firms.attorney_name to attorneys table entries
-- ============================================================================

-- For each existing firm, create an attorney record
INSERT INTO attorneys (attorney_name, email, phone, practice_number, firm_id, status)
SELECT 
  f.attorney_name,
  f.email,
  f.phone_number,
  f.practice_number,
  f.id,
  f.status
FROM firms f
WHERE f.attorney_name IS NOT NULL
  AND f.email IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM attorneys a WHERE a.email = f.email
  );

-- ============================================================================
-- ADD FAVORITE_ATTORNEYS TO USER_PREFERENCES
-- ============================================================================

-- Check if user_preferences table exists and handle accordingly
DO $$
BEGIN
  -- If table doesn't exist, create it
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables 
    WHERE table_schema = 'public' 
    AND table_name = 'user_preferences'
  ) THEN
    CREATE TABLE user_preferences (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      advocate_id UUID UNIQUE NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
      favorite_attorneys UUID[] DEFAULT '{}',
      created_at TIMESTAMPTZ DEFAULT NOW(),
      updated_at TIMESTAMPTZ DEFAULT NOW()
    );
    
    CREATE INDEX idx_user_preferences_advocate_id ON user_preferences(advocate_id);
    COMMENT ON TABLE user_preferences IS 'Stores user-specific preferences including favorite attorneys';
    COMMENT ON COLUMN user_preferences.favorite_attorneys IS 'Array of attorney IDs marked as favorites';
  ELSE
    -- Ensure advocate_id exists for policy compatibility
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
      AND table_name = 'user_preferences'
      AND column_name = 'advocate_id'
    ) THEN
      ALTER TABLE user_preferences ADD COLUMN advocate_id UUID;

      -- Backfill from legacy user_id if present
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'user_preferences'
        AND column_name = 'user_id'
      ) THEN
        UPDATE user_preferences
        SET advocate_id = user_id
        WHERE advocate_id IS NULL;
      END IF;

      ALTER TABLE user_preferences
      ADD CONSTRAINT user_preferences_advocate_id_fkey
      FOREIGN KEY (advocate_id) REFERENCES advocates(id) ON DELETE CASCADE;
    END IF;

    CREATE UNIQUE INDEX IF NOT EXISTS idx_user_preferences_advocate_id
      ON user_preferences(advocate_id);

    -- If table exists but column doesn't, add it
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns 
      WHERE table_schema = 'public'
      AND table_name = 'user_preferences' 
      AND column_name = 'favorite_attorneys'
    ) THEN
      ALTER TABLE user_preferences ADD COLUMN favorite_attorneys UUID[] DEFAULT '{}';
      COMMENT ON COLUMN user_preferences.favorite_attorneys IS 'Array of attorney IDs marked as favorites';
    END IF;
  END IF;
END $$;

-- Enable RLS on user_preferences (only if not already enabled)
DO $$
BEGIN
  ALTER TABLE user_preferences ENABLE ROW LEVEL SECURITY;
EXCEPTION
  WHEN OTHERS THEN NULL;  -- Ignore if already enabled
END $$;

-- Drop existing policies first (to avoid conflicts)
DROP POLICY IF EXISTS "Users can view their own preferences" ON user_preferences;
DROP POLICY IF EXISTS "Users can insert their own preferences" ON user_preferences;
DROP POLICY IF EXISTS "Users can update their own preferences" ON user_preferences;

-- RLS policies for user_preferences
CREATE POLICY "Users can view their own preferences"
  ON user_preferences
  FOR SELECT
  TO authenticated
  USING (advocate_id = auth.uid());

CREATE POLICY "Users can insert their own preferences"
  ON user_preferences
  FOR INSERT
  TO authenticated
  WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "Users can update their own preferences"
  ON user_preferences
  FOR UPDATE
  TO authenticated
  USING (advocate_id = auth.uid())
  WITH CHECK (advocate_id = auth.uid());

-- Add updated_at trigger for user_preferences (drop first if exists)
DROP TRIGGER IF EXISTS user_preferences_updated_at ON user_preferences;
DROP FUNCTION IF EXISTS update_user_preferences_updated_at();

CREATE OR REPLACE FUNCTION update_user_preferences_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER user_preferences_updated_at
  BEFORE UPDATE ON user_preferences
  FOR EACH ROW
  EXECUTE FUNCTION update_user_preferences_updated_at();
