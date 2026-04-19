-- ============================================================================
-- CONSOLIDATED ROOT SQL FIXES
-- Generated: 2025-01-12
-- This file consolidates all SQL scripts that were in the root directory
-- ============================================================================

-- ============================================================================
-- SECTION 1: DIAGNOSTIC QUERIES FOR AUTH ISSUES
-- ============================================================================

-- Check if advocates table exists
-- SELECT EXISTS (
--   SELECT FROM information_schema.tables 
--   WHERE table_schema = 'public' 
--   AND table_name = 'advocates'
-- ) AS advocates_table_exists;

-- ============================================================================
-- SECTION 2: CLOUD STORAGE TABLES AND PERMISSIONS
-- ============================================================================

-- Create cloud_storage_connections table
CREATE TABLE IF NOT EXISTS cloud_storage_connections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
  
  -- Provider information
  provider TEXT NOT NULL CHECK (provider IN ('onedrive', 'google_drive', 'dropbox', 'icloud', 'box')),
  provider_account_id TEXT NOT NULL,
  provider_account_email TEXT,
  provider_account_name TEXT,
  
  -- OAuth tokens (encrypted)
  access_token TEXT NOT NULL,
  refresh_token TEXT,
  token_expires_at TIMESTAMPTZ,
  
  -- Storage configuration
  root_folder_id TEXT,
  root_folder_path TEXT DEFAULT '/AdvocateHub',
  
  -- Status
  is_active BOOLEAN DEFAULT true,
  is_primary BOOLEAN DEFAULT false,
  last_sync_at TIMESTAMPTZ,
  sync_status TEXT DEFAULT 'active' CHECK (sync_status IN ('active', 'error', 'disconnected', 'syncing')),
  sync_error TEXT,
  
  -- Metadata
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create cloud_storage_sync_log table
CREATE TABLE IF NOT EXISTS cloud_storage_sync_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id UUID NOT NULL REFERENCES cloud_storage_connections(id) ON DELETE CASCADE,
  
  sync_type TEXT NOT NULL CHECK (sync_type IN ('upload', 'download', 'delete', 'update', 'full_sync')),
  local_document_id UUID REFERENCES document_uploads(id) ON DELETE SET NULL,
  provider_file_id TEXT,
  provider_file_path TEXT,
  
  status TEXT NOT NULL CHECK (status IN ('pending', 'in_progress', 'completed', 'failed')),
  error_message TEXT,
  
  file_size_bytes BIGINT,
  sync_duration_ms INTEGER,
  
  started_at TIMESTAMPTZ DEFAULT NOW(),
  completed_at TIMESTAMPTZ
);

-- Create document_cloud_storage table
CREATE TABLE IF NOT EXISTS document_cloud_storage (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_upload_id UUID NOT NULL REFERENCES document_uploads(id) ON DELETE CASCADE,
  connection_id UUID NOT NULL REFERENCES cloud_storage_connections(id) ON DELETE CASCADE,
  
  provider_file_id TEXT NOT NULL,
  provider_file_path TEXT NOT NULL,
  provider_web_url TEXT,
  provider_download_url TEXT,
  
  is_synced BOOLEAN DEFAULT true,
  last_synced_at TIMESTAMPTZ DEFAULT NOW(),
  local_hash TEXT,
  provider_hash TEXT,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(document_upload_id, connection_id)
);

-- Create indexes for cloud storage
CREATE INDEX IF NOT EXISTS idx_cloud_storage_connections_advocate_id ON cloud_storage_connections(advocate_id);
CREATE INDEX IF NOT EXISTS idx_cloud_storage_connections_provider ON cloud_storage_connections(provider);
CREATE INDEX IF NOT EXISTS idx_cloud_storage_connections_is_active ON cloud_storage_connections(is_active);
CREATE UNIQUE INDEX IF NOT EXISTS idx_cloud_storage_connections_unique_primary ON cloud_storage_connections(advocate_id) WHERE is_primary = true;

CREATE INDEX IF NOT EXISTS idx_cloud_storage_sync_log_connection_id ON cloud_storage_sync_log(connection_id);
CREATE INDEX IF NOT EXISTS idx_cloud_storage_sync_log_status ON cloud_storage_sync_log(status);
CREATE INDEX IF NOT EXISTS idx_cloud_storage_sync_log_started_at ON cloud_storage_sync_log(started_at);

CREATE INDEX IF NOT EXISTS idx_document_cloud_storage_document_id ON document_cloud_storage(document_upload_id);
CREATE INDEX IF NOT EXISTS idx_document_cloud_storage_connection_id ON document_cloud_storage(connection_id);
CREATE INDEX IF NOT EXISTS idx_document_cloud_storage_provider_file_id ON document_cloud_storage(provider_file_id);

-- Enable RLS on cloud storage tables
ALTER TABLE cloud_storage_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE cloud_storage_sync_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE document_cloud_storage ENABLE ROW LEVEL SECURITY;

-- Grant permissions
GRANT ALL ON cloud_storage_connections TO authenticated;
GRANT ALL ON cloud_storage_sync_log TO authenticated;
GRANT ALL ON document_cloud_storage TO authenticated;

-- Drop existing cloud storage policies
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT policyname FROM pg_policies WHERE tablename = 'cloud_storage_connections') LOOP
        EXECUTE 'DROP POLICY IF EXISTS ' || quote_ident(r.policyname) || ' ON cloud_storage_connections';
    END LOOP;
    
    FOR r IN (SELECT policyname FROM pg_policies WHERE tablename = 'cloud_storage_sync_log') LOOP
        EXECUTE 'DROP POLICY IF EXISTS ' || quote_ident(r.policyname) || ' ON cloud_storage_sync_log';
    END LOOP;
    
    FOR r IN (SELECT policyname FROM pg_policies WHERE tablename = 'document_cloud_storage') LOOP
        EXECUTE 'DROP POLICY IF EXISTS ' || quote_ident(r.policyname) || ' ON document_cloud_storage';
    END LOOP;
END $$;

-- Create cloud storage RLS policies
CREATE POLICY "cloud_storage_select" ON cloud_storage_connections
    FOR SELECT TO authenticated
    USING (advocate_id = auth.uid());

CREATE POLICY "cloud_storage_insert" ON cloud_storage_connections
    FOR INSERT TO authenticated
    WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "cloud_storage_update" ON cloud_storage_connections
    FOR UPDATE TO authenticated
    USING (advocate_id = auth.uid());

CREATE POLICY "cloud_storage_delete" ON cloud_storage_connections
    FOR DELETE TO authenticated
    USING (advocate_id = auth.uid());

CREATE POLICY "sync_log_select" ON cloud_storage_sync_log
    FOR SELECT TO authenticated
    USING (connection_id IN (SELECT id FROM cloud_storage_connections WHERE advocate_id = auth.uid()));

CREATE POLICY "sync_log_insert" ON cloud_storage_sync_log
    FOR INSERT TO authenticated
    WITH CHECK (true);

CREATE POLICY "doc_storage_select" ON document_cloud_storage
    FOR SELECT TO authenticated
    USING (document_upload_id IN (SELECT id FROM document_uploads WHERE uploaded_by = auth.uid()));

CREATE POLICY "doc_storage_insert" ON document_cloud_storage
    FOR INSERT TO authenticated
    WITH CHECK (document_upload_id IN (SELECT id FROM document_uploads WHERE uploaded_by = auth.uid()));

CREATE POLICY "doc_storage_update" ON document_cloud_storage
    FOR UPDATE TO authenticated
    USING (document_upload_id IN (SELECT id FROM document_uploads WHERE uploaded_by = auth.uid()));

CREATE POLICY "doc_storage_delete" ON document_cloud_storage
    FOR DELETE TO authenticated
    USING (document_upload_id IN (SELECT id FROM document_uploads WHERE uploaded_by = auth.uid()));

-- Cloud storage functions
CREATE OR REPLACE FUNCTION update_cloud_storage_connections_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_document_cloud_storage_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ensure_single_primary_provider()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.is_primary = true THEN
    UPDATE cloud_storage_connections
    SET is_primary = false
    WHERE advocate_id = NEW.advocate_id
      AND id != NEW.id
      AND is_primary = true;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Cloud storage triggers
DROP TRIGGER IF EXISTS trigger_update_cloud_storage_connections_updated_at ON cloud_storage_connections;
CREATE TRIGGER trigger_update_cloud_storage_connections_updated_at
  BEFORE UPDATE ON cloud_storage_connections
  FOR EACH ROW
  EXECUTE FUNCTION update_cloud_storage_connections_updated_at();

DROP TRIGGER IF EXISTS trigger_update_document_cloud_storage_updated_at ON document_cloud_storage;
CREATE TRIGGER trigger_update_document_cloud_storage_updated_at
  BEFORE UPDATE ON document_cloud_storage
  FOR EACH ROW
  EXECUTE FUNCTION update_document_cloud_storage_updated_at();

DROP TRIGGER IF EXISTS trigger_ensure_single_primary_provider ON cloud_storage_connections;
CREATE TRIGGER trigger_ensure_single_primary_provider
  BEFORE INSERT OR UPDATE ON cloud_storage_connections
  FOR EACH ROW
  WHEN (NEW.is_primary = true)
  EXECUTE FUNCTION ensure_single_primary_provider();

-- ============================================================================
-- SECTION 3: MATTERS TABLE FIXES
-- ============================================================================

-- Add user_id column to matters table
ALTER TABLE matters ADD COLUMN IF NOT EXISTS user_id UUID;
CREATE INDEX IF NOT EXISTS idx_matters_user_id ON matters(user_id);

-- Update existing rows
UPDATE matters SET user_id = advocate_id WHERE user_id IS NULL;

-- Add billing_status column
ALTER TABLE matters
ADD COLUMN IF NOT EXISTS billing_status TEXT CHECK (billing_status IN ('pending', 'approved', 'rejected', 'invoiced')) DEFAULT 'pending';

CREATE INDEX IF NOT EXISTS idx_matters_billing_status ON matters(billing_status);

-- Add extended matter fields
ALTER TABLE matters
ADD COLUMN IF NOT EXISTS state TEXT DEFAULT 'active' CHECK (
    state IN ('active', 'paused', 'on_hold', 'awaiting_court', 'completed', 'archived')
),
ADD COLUMN IF NOT EXISTS court_date DATE,
ADD COLUMN IF NOT EXISTS paused_reason TEXT,
ADD COLUMN IF NOT EXISTS paused_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS agreed_fee_cap DECIMAL(12,2),
ADD COLUMN IF NOT EXISTS agreed_hourly_rate DECIMAL(12,2),
ADD COLUMN IF NOT EXISTS agreed_timeline_days INTEGER;

CREATE INDEX IF NOT EXISTS idx_matters_state ON matters(state);
CREATE INDEX IF NOT EXISTS idx_matters_court_date ON matters(court_date) WHERE state = 'awaiting_court';

-- Sync user_id with advocate_id
CREATE OR REPLACE FUNCTION sync_matters_user_id()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.advocate_id IS NOT NULL THEN
    NEW.user_id := NEW.advocate_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS sync_matters_user_id_trigger ON matters;
CREATE TRIGGER sync_matters_user_id_trigger
  BEFORE INSERT OR UPDATE ON matters
  FOR EACH ROW
  EXECUTE FUNCTION sync_matters_user_id();

-- Drop ALL existing matters policies
DROP POLICY IF EXISTS "matters_select_policy" ON matters;
DROP POLICY IF EXISTS "matters_insert_policy" ON matters;
DROP POLICY IF EXISTS "matters_update_policy" ON matters;
DROP POLICY IF EXISTS "matters_delete_policy" ON matters;
DROP POLICY IF EXISTS "Advocates can view their own matters" ON matters;
DROP POLICY IF EXISTS "Advocates can create their own matters" ON matters;
DROP POLICY IF EXISTS "Advocates can update their own matters" ON matters;
DROP POLICY IF EXISTS "Advocates can delete their own matters" ON matters;

-- Create clean matters policies
CREATE POLICY "matters_select_policy"
  ON matters FOR SELECT
  TO authenticated
  USING (
    advocate_id = auth.uid() OR 
    user_id = auth.uid() OR
    EXISTS (
      SELECT 1 FROM team_members
      WHERE team_members.user_id = auth.uid()
      AND team_members.organization_id = matters.advocate_id
      AND team_members.status = 'active'
    )
  );

CREATE POLICY "matters_insert_policy"
  ON matters FOR INSERT
  TO authenticated
  WITH CHECK (
    advocate_id = auth.uid() OR 
    user_id = auth.uid()
  );

CREATE POLICY "matters_update_policy"
  ON matters FOR UPDATE
  TO authenticated
  USING (
    advocate_id = auth.uid() OR 
    user_id = auth.uid() OR
    EXISTS (
      SELECT 1 FROM team_members
      WHERE team_members.user_id = auth.uid()
      AND team_members.organization_id = matters.advocate_id
      AND team_members.status = 'active'
      AND team_members.role IN ('admin', 'advocate')
    )
  )
  WITH CHECK (
    advocate_id = auth.uid() OR 
    user_id = auth.uid()
  );

CREATE POLICY "matters_delete_policy"
  ON matters FOR DELETE
  TO authenticated
  USING (
    advocate_id = auth.uid() OR 
    user_id = auth.uid()
  );

-- ============================================================================
-- SECTION 4: PARTNER APPROVALS SYSTEM
-- ============================================================================

CREATE TABLE IF NOT EXISTS partner_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  matter_id UUID REFERENCES matters(id) ON DELETE CASCADE NOT NULL,
  partner_id UUID NOT NULL,
  status TEXT CHECK (status IN ('pending', 'approved', 'rejected')) DEFAULT 'pending',
  comments TEXT,
  checklist JSONB,
  approved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_partner_approvals_matter_id ON partner_approvals(matter_id);
CREATE INDEX IF NOT EXISTS idx_partner_approvals_partner_id ON partner_approvals(partner_id);
CREATE INDEX IF NOT EXISTS idx_partner_approvals_status ON partner_approvals(status);

ALTER TABLE partner_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view partner approvals" ON partner_approvals;
CREATE POLICY "Users can view partner approvals"
  ON partner_approvals FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM matters m
      WHERE m.id = partner_approvals.matter_id
      AND m.advocate_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Users can create approvals" ON partner_approvals;
CREATE POLICY "Users can create approvals"
  ON partner_approvals FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM matters m
      WHERE m.id = partner_approvals.matter_id
      AND m.advocate_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Users can update their approvals" ON partner_approvals;
CREATE POLICY "Users can update their approvals"
  ON partner_approvals FOR UPDATE
  USING (partner_id = auth.uid())
  WITH CHECK (partner_id = auth.uid());

GRANT SELECT, INSERT, UPDATE ON partner_approvals TO authenticated;

-- Partner approval trigger
CREATE OR REPLACE FUNCTION update_matter_billing_status()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE matters
  SET 
    billing_status = NEW.status,
    updated_at = NOW()
  WHERE id = NEW.matter_id;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_update_matter_billing_status ON partner_approvals;
CREATE TRIGGER trigger_update_matter_billing_status
  AFTER INSERT OR UPDATE OF status ON partner_approvals
  FOR EACH ROW
  EXECUTE FUNCTION update_matter_billing_status();

-- ============================================================================
-- SECTION 5: PUBLIC TOKENS FOR ATTORNEY PORTAL
-- ============================================================================

ALTER TABLE proforma_requests 
ADD COLUMN IF NOT EXISTS public_token UUID DEFAULT gen_random_uuid() UNIQUE;

CREATE INDEX IF NOT EXISTS idx_proforma_public_token 
ON proforma_requests(public_token);

ALTER TABLE engagement_agreements 
ADD COLUMN IF NOT EXISTS public_token UUID DEFAULT gen_random_uuid() UNIQUE;

CREATE INDEX IF NOT EXISTS idx_engagement_public_token 
ON engagement_agreements(public_token);

ALTER TABLE proforma_requests
ADD COLUMN IF NOT EXISTS link_sent_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS link_sent_to TEXT;

ALTER TABLE engagement_agreements
ADD COLUMN IF NOT EXISTS link_sent_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS link_sent_to TEXT;

-- Function to regenerate public token
CREATE OR REPLACE FUNCTION regenerate_public_token(
  table_name TEXT,
  record_id UUID
) RETURNS UUID AS $$
DECLARE
  new_token UUID;
BEGIN
  new_token := gen_random_uuid();
  
  IF table_name = 'proforma_requests' THEN
    UPDATE proforma_requests 
    SET public_token = new_token 
    WHERE id = record_id;
  ELSIF table_name = 'engagement_agreements' THEN
    UPDATE engagement_agreements 
    SET public_token = new_token 
    WHERE id = record_id;
  ELSE
    RAISE EXCEPTION 'Invalid table name';
  END IF;
  
  RETURN new_token;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION regenerate_public_token TO authenticated;

-- ============================================================================
-- SECTION 6: INVOICE BAR REMINDERS
-- ============================================================================

ALTER TABLE invoices
ADD COLUMN IF NOT EXISTS bar_reminder_sent BOOLEAN DEFAULT FALSE;

-- ============================================================================
-- SECTION 7: SUPABASE STORAGE SETUP
-- ============================================================================

-- Create documents bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'documents',
  'documents',
  false,
  52428800, -- 50MB limit
  ARRAY['application/pdf', 'image/jpeg', 'image/png', 'image/jpg', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'text/plain']
)
ON CONFLICT (id) DO NOTHING;

-- Add url column to document_uploads
ALTER TABLE document_uploads
ADD COLUMN IF NOT EXISTS url TEXT;

-- ============================================================================
-- COMPLETION MESSAGE
-- ============================================================================

DO $$
BEGIN
  RAISE NOTICE '============================================================================';
  RAISE NOTICE 'CONSOLIDATED ROOT SQL FIXES APPLIED SUCCESSFULLY';
  RAISE NOTICE '============================================================================';
  RAISE NOTICE 'Applied:';
  RAISE NOTICE '  ✓ Cloud storage tables and permissions';
  RAISE NOTICE '  ✓ Matters table fixes and policies';
  RAISE NOTICE '  ✓ Partner approvals system';
  RAISE NOTICE '  ✓ Public tokens for attorney portal';
  RAISE NOTICE '  ✓ Invoice bar reminders';
  RAISE NOTICE '  ✓ Supabase storage setup';
  RAISE NOTICE '============================================================================';
END $$;
