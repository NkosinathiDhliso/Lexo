-- ============================================
-- Schema Alignment Migration
-- Ensures database schema matches current state
-- ============================================

-- This migration safely adds missing columns to user_profiles
-- without assuming advocates table exists

DO $$
BEGIN
  RAISE NOTICE '========================================';
  RAISE NOTICE 'Starting Schema Alignment Migration';
  RAISE NOTICE '========================================';
END $$;

-- ============================================
-- PART 1: Ensure user_profiles has all needed columns
-- ============================================

DO $$
BEGIN
  -- Practice information
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'practice_number') THEN
    ALTER TABLE user_profiles ADD COLUMN practice_number TEXT;
    RAISE NOTICE '✓ Added practice_number column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'year_admitted') THEN
    ALTER TABLE user_profiles ADD COLUMN year_admitted INTEGER;
    RAISE NOTICE '✓ Added year_admitted column';
  END IF;
  
  -- Rates and fees
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'hourly_rate') THEN
    ALTER TABLE user_profiles ADD COLUMN hourly_rate NUMERIC(10,2) DEFAULT 0;
    RAISE NOTICE '✓ Added hourly_rate column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'contingency_rate') THEN
    ALTER TABLE user_profiles ADD COLUMN contingency_rate NUMERIC(5,2);
    RAISE NOTICE '✓ Added contingency_rate column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'success_fee_rate') THEN
    ALTER TABLE user_profiles ADD COLUMN success_fee_rate NUMERIC(5,2);
    RAISE NOTICE '✓ Added success_fee_rate column';
  END IF;
  
  -- Contact and address
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'chambers_address') THEN
    ALTER TABLE user_profiles ADD COLUMN chambers_address TEXT;
    RAISE NOTICE '✓ Added chambers_address column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'postal_address') THEN
    ALTER TABLE user_profiles ADD COLUMN postal_address TEXT;
    RAISE NOTICE '✓ Added postal_address column';
  END IF;
  
  -- Firm branding
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'firm_name') THEN
    ALTER TABLE user_profiles ADD COLUMN firm_name TEXT;
    RAISE NOTICE '✓ Added firm_name column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'firm_tagline') THEN
    ALTER TABLE user_profiles ADD COLUMN firm_tagline TEXT;
    RAISE NOTICE '✓ Added firm_tagline column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'firm_logo_url') THEN
    ALTER TABLE user_profiles ADD COLUMN firm_logo_url TEXT;
    RAISE NOTICE '✓ Added firm_logo_url column';
  END IF;
  
  -- Financial
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'vat_number') THEN
    ALTER TABLE user_profiles ADD COLUMN vat_number TEXT;
    RAISE NOTICE '✓ Added vat_number column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'bank_name') THEN
    ALTER TABLE user_profiles ADD COLUMN bank_name TEXT;
    RAISE NOTICE '✓ Added bank_name column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'bank_account_number') THEN
    ALTER TABLE user_profiles ADD COLUMN bank_account_number TEXT;
    RAISE NOTICE '✓ Added bank_account_number column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'bank_branch_code') THEN
    ALTER TABLE user_profiles ADD COLUMN bank_branch_code TEXT;
    RAISE NOTICE '✓ Added bank_branch_code column';
  END IF;
  
  -- Status and role
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'is_active') THEN
    ALTER TABLE user_profiles ADD COLUMN is_active BOOLEAN DEFAULT true;
    RAISE NOTICE '✓ Added is_active column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'user_role') THEN
    ALTER TABLE user_profiles ADD COLUMN user_role user_role DEFAULT 'junior_advocate';
    RAISE NOTICE '✓ Added user_role column';
  END IF;
  
  -- Additional profile fields
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'initials') THEN
    ALTER TABLE user_profiles ADD COLUMN initials TEXT;
    RAISE NOTICE '✓ Added initials column';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'full_name') THEN
    ALTER TABLE user_profiles ADD COLUMN full_name TEXT;
    RAISE NOTICE '✓ Added full_name column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'email') THEN
    ALTER TABLE user_profiles ADD COLUMN email TEXT;
    RAISE NOTICE '✓ Added email column';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'last_login_at') THEN
    ALTER TABLE user_profiles ADD COLUMN last_login_at TIMESTAMPTZ;
    RAISE NOTICE '✓ Added last_login_at column';
  END IF;
END $$;

-- ============================================
-- PART 2: Create advocates_view for backward compatibility
-- ============================================

CREATE OR REPLACE VIEW advocates_view AS
SELECT 
  user_id as id,
  email,
  COALESCE(full_name, email) as full_name,
  initials,
  practice_number,
  NULL::text as bar,
  year_admitted,
  hourly_rate,
  phone as phone_number,
  chambers_address,
  postal_address,
  user_role,
  is_active,
  created_at,
  updated_at
FROM user_profiles
WHERE practice_number IS NOT NULL;

DO $$
BEGIN
  RAISE NOTICE '✓ Created advocates_view';
END $$;

-- ============================================
-- PART 3: Update foreign key constraints
-- ============================================

DO $$
DECLARE
  fk_record RECORD;
  new_constraint_name TEXT;
  fk_exists BOOLEAN;
BEGIN
  RAISE NOTICE '========================================';
  RAISE NOTICE 'Updating foreign key constraints';
  RAISE NOTICE '========================================';
  
  -- Find all foreign keys pointing to advocates_deprecated
  FOR fk_record IN 
    SELECT 
      tc.table_name,
      tc.constraint_name,
      kcu.column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu 
      ON tc.constraint_name = kcu.constraint_name
    JOIN information_schema.constraint_column_usage ccu 
      ON ccu.constraint_name = tc.constraint_name
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_name = 'advocates_deprecated'
      AND tc.table_schema = 'public'
  LOOP
    -- Generate new constraint name
    new_constraint_name := fk_record.table_name || '_' || fk_record.column_name || '_user_profiles_fkey';
    
    -- Check if new constraint already exists
    SELECT EXISTS (
      SELECT 1 FROM information_schema.table_constraints
      WHERE constraint_name = new_constraint_name
        AND table_schema = 'public'
    ) INTO fk_exists;
    
    IF NOT fk_exists THEN
      -- Drop old constraint
      EXECUTE format('ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I', 
        fk_record.table_name, fk_record.constraint_name);
      
      -- Add new constraint pointing to user_profiles
      EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES user_profiles(user_id) ON DELETE CASCADE',
        fk_record.table_name, new_constraint_name, fk_record.column_name);
      
      RAISE NOTICE '✓ Updated FK: %.% -> user_profiles', fk_record.table_name, fk_record.column_name;
    ELSE
      RAISE NOTICE '⚠️ FK already exists: %', new_constraint_name;
    END IF;
  END LOOP;
END $$;

-- ============================================
-- FINAL SUMMARY
-- ============================================

DO $$
DECLARE
  profile_count INTEGER;
  fk_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO profile_count FROM user_profiles;
  
  SELECT COUNT(*) INTO fk_count
  FROM information_schema.table_constraints
  WHERE constraint_type = 'FOREIGN KEY'
    AND constraint_name LIKE '%user_profiles%'
    AND table_schema = 'public';
  
  RAISE NOTICE '========================================';
  RAISE NOTICE '🎉 SCHEMA ALIGNMENT COMPLETE!';
  RAISE NOTICE '========================================';
  RAISE NOTICE 'User profiles: %', profile_count;
  RAISE NOTICE 'Foreign keys to user_profiles: %', fk_count;
  RAISE NOTICE '========================================';
END $$;
