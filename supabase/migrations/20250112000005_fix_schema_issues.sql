-- Fix schema issues identified in the application
-- 1. Add cost_variance_percentage column to scope_amendments (alias for variance_percentage)
-- 2. Add uploaded_at column to document_uploads (alias for created_at)
-- 3. Ensure proper RLS policies for scope_amendments

-- ================================================================================
-- FIX SCOPE_AMENDMENTS TABLE
-- ================================================================================

-- Add cost_variance_percentage as an alias/view for variance_percentage
ALTER TABLE scope_amendments 
ADD COLUMN IF NOT EXISTS cost_variance_percentage DECIMAL(5,2);

DO $$
DECLARE
    col_generated TEXT;
BEGIN
    SELECT is_generated
    INTO col_generated
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'scope_amendments'
      AND column_name = 'cost_variance_percentage';

    IF col_generated IS DISTINCT FROM 'ALWAYS' THEN
        UPDATE scope_amendments
        SET cost_variance_percentage = variance_percentage
        WHERE cost_variance_percentage IS DISTINCT FROM variance_percentage;
    END IF;
END $$;

COMMENT ON COLUMN scope_amendments.cost_variance_percentage IS 'Alias for variance_percentage to match frontend expectations';

-- ================================================================================
-- FIX DOCUMENT_UPLOADS TABLE
-- ================================================================================

-- Add uploaded_at as an alias for created_at
ALTER TABLE document_uploads 
ADD COLUMN IF NOT EXISTS uploaded_at TIMESTAMPTZ;

DO $$
DECLARE
    col_generated TEXT;
BEGIN
    SELECT is_generated
    INTO col_generated
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'document_uploads'
      AND column_name = 'uploaded_at';

    IF col_generated IS DISTINCT FROM 'ALWAYS' THEN
        UPDATE document_uploads
        SET uploaded_at = created_at
        WHERE uploaded_at IS DISTINCT FROM created_at;
    END IF;
END $$;

COMMENT ON COLUMN document_uploads.uploaded_at IS 'Alias for created_at to match frontend expectations';

-- ================================================================================
-- ENSURE RLS POLICIES FOR SCOPE_AMENDMENTS
-- ================================================================================

-- Enable RLS
ALTER TABLE scope_amendments ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist
DROP POLICY IF EXISTS "scope_amendments_select_policy" ON scope_amendments;
DROP POLICY IF EXISTS "scope_amendments_insert_policy" ON scope_amendments;
DROP POLICY IF EXISTS "scope_amendments_update_policy" ON scope_amendments;

-- Create comprehensive RLS policies for scope_amendments
CREATE POLICY "scope_amendments_select_policy" ON scope_amendments
    FOR SELECT USING (
        auth.uid() IN (
            SELECT id FROM advocates WHERE id = advocate_id
            UNION
            SELECT advocate_id FROM matters WHERE id = matter_id
        )
    );

CREATE POLICY "scope_amendments_insert_policy" ON scope_amendments
    FOR INSERT WITH CHECK (
        auth.uid() IN (
            SELECT id FROM advocates WHERE id = advocate_id
            UNION
            SELECT advocate_id FROM matters WHERE id = matter_id
        )
    );

CREATE POLICY "scope_amendments_update_policy" ON scope_amendments
    FOR UPDATE USING (
        auth.uid() IN (
            SELECT id FROM advocates WHERE id = advocate_id
            UNION
            SELECT advocate_id FROM matters WHERE id = matter_id
        )
    );

-- ================================================================================
-- ENSURE RLS POLICIES FOR DOCUMENT_UPLOADS
-- ================================================================================

-- Enable RLS
ALTER TABLE document_uploads ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist
DROP POLICY IF EXISTS "document_uploads_select_policy" ON document_uploads;
DROP POLICY IF EXISTS "document_uploads_insert_policy" ON document_uploads;
DROP POLICY IF EXISTS "document_uploads_update_policy" ON document_uploads;

-- Create comprehensive RLS policies for document_uploads
CREATE POLICY "document_uploads_select_policy" ON document_uploads
    FOR SELECT USING (
        auth.uid() IN (
            SELECT uploaded_by WHERE uploaded_by IS NOT NULL
            UNION
            SELECT advocate_id FROM matters WHERE id = matter_id
        )
    );

CREATE POLICY "document_uploads_insert_policy" ON document_uploads
    FOR INSERT WITH CHECK (
        auth.uid() = uploaded_by OR
        auth.uid() IN (
            SELECT advocate_id FROM matters WHERE id = matter_id
        )
    );

CREATE POLICY "document_uploads_update_policy" ON document_uploads
    FOR UPDATE USING (
        auth.uid() = uploaded_by OR
        auth.uid() IN (
            SELECT advocate_id FROM matters WHERE id = matter_id
        )
    );

-- ================================================================================
-- GRANT PERMISSIONS
-- ================================================================================

-- Grant permissions to authenticated users
GRANT SELECT, INSERT, UPDATE ON scope_amendments TO authenticated;
GRANT SELECT, INSERT, UPDATE ON document_uploads TO authenticated;
GRANT SELECT, INSERT, UPDATE ON document_extracted_data TO authenticated;

-- ================================================================================
-- REFRESH SCHEMA CACHE
-- ================================================================================

-- Notify PostgREST to reload schema cache
NOTIFY pgrst, 'reload schema';