-- Migration: Attorney Portal Invitation Tokens & Matter Access
-- Requirements: 8.6, 8.7
-- Purpose: Enable portal invitations and historical matter linking

-- 1. Create attorney_invitation_tokens table
CREATE TABLE IF NOT EXISTS attorney_invitation_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  attorney_id UUID NOT NULL REFERENCES attorneys(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  used_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  
  CONSTRAINT valid_expiry CHECK (expires_at > created_at)
);

-- 2. Create attorney_matter_access table
-- Links registered attorneys to their accessible matters
CREATE TABLE IF NOT EXISTS attorney_matter_access (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  attorney_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  matter_id UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
  granted_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(attorney_user_id, matter_id)
);

ALTER TABLE matters
ADD COLUMN IF NOT EXISTS instructing_attorney_id UUID REFERENCES attorneys(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS instructing_attorney_email TEXT;

-- 3. Create indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_invitation_tokens_attorney ON attorney_invitation_tokens(attorney_id);
CREATE INDEX IF NOT EXISTS idx_invitation_tokens_token ON attorney_invitation_tokens(token) WHERE used_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_invitation_tokens_expires ON attorney_invitation_tokens(expires_at) WHERE used_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_matter_access_attorney ON attorney_matter_access(attorney_user_id);
CREATE INDEX IF NOT EXISTS idx_matter_access_matter ON attorney_matter_access(matter_id);
CREATE INDEX IF NOT EXISTS idx_matter_access_granted ON attorney_matter_access(granted_at);

-- 4. Create function to validate invitation token
CREATE OR REPLACE FUNCTION validate_invitation_token(
  p_token TEXT
)
RETURNS TABLE (
  attorney_id UUID,
  attorney_email TEXT,
  is_valid BOOLEAN,
  error_message TEXT
) AS $$
DECLARE
  v_token_record RECORD;
BEGIN
  -- Get token record
  SELECT 
    t.attorney_id,
    a.email,
    t.expires_at,
    t.used_at
  INTO v_token_record
  FROM attorney_invitation_tokens t
  JOIN attorneys a ON a.id = t.attorney_id
  WHERE t.token = p_token;
  
  -- Token not found
  IF NOT FOUND THEN
    RETURN QUERY SELECT 
      NULL::UUID, 
      NULL::TEXT,
      FALSE,
      'Invalid invitation token'::TEXT;
    RETURN;
  END IF;
  
  -- Token already used
  IF v_token_record.used_at IS NOT NULL THEN
    RETURN QUERY SELECT 
      v_token_record.attorney_id,
      v_token_record.email,
      FALSE,
      'Invitation already accepted'::TEXT;
    RETURN;
  END IF;
  
  -- Token expired
  IF v_token_record.expires_at < NOW() THEN
    RETURN QUERY SELECT 
      v_token_record.attorney_id,
      v_token_record.email,
      FALSE,
      'Invitation expired'::TEXT;
    RETURN;
  END IF;
  
  -- Token is valid
  RETURN QUERY SELECT 
    v_token_record.attorney_id,
    v_token_record.email,
    TRUE,
    NULL::TEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Create function to mark token as used
CREATE OR REPLACE FUNCTION mark_invitation_used(
  p_token TEXT,
  p_user_id UUID
)
RETURNS BOOLEAN AS $$
BEGIN
  UPDATE attorney_invitation_tokens
  SET 
    used_at = NOW(),
    used_by = p_user_id
  WHERE token = p_token
    AND used_at IS NULL
    AND expires_at > NOW();
  
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. Create function to auto-grant matter access on attorney registration
-- This is called when attorney registers and links to historical matters
CREATE OR REPLACE FUNCTION grant_attorney_matter_access(
  p_attorney_email TEXT,
  p_user_id UUID
)
RETURNS INTEGER AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  -- Insert access records for all matters with this attorney's email
  INSERT INTO attorney_matter_access (attorney_user_id, matter_id, granted_at)
  SELECT 
    p_user_id,
    m.id,
    NOW()
  FROM matters m
  WHERE m.instructing_attorney_email = p_attorney_email
  ON CONFLICT (attorney_user_id, matter_id) DO NOTHING;
  
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Create RLS policies for attorney_invitation_tokens
ALTER TABLE attorney_invitation_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS attorney_invitation_tokens_advocate_read ON attorney_invitation_tokens;
DROP POLICY IF EXISTS attorney_invitation_tokens_advocate_create ON attorney_invitation_tokens;

-- Advocates can see tokens for their own attorneys
CREATE POLICY attorney_invitation_tokens_advocate_read ON attorney_invitation_tokens
  FOR SELECT
  USING (
    attorney_id IN (
      SELECT a.id 
      FROM attorneys a 
      WHERE a.firm_id IN (
        SELECT f.id 
        FROM firms f 
        WHERE f.advocate_id = auth.uid()
      )
    )
  );

-- Advocates can create tokens for their own attorneys
CREATE POLICY attorney_invitation_tokens_advocate_create ON attorney_invitation_tokens
  FOR INSERT
  WITH CHECK (
    attorney_id IN (
      SELECT a.id 
      FROM attorneys a 
      WHERE a.firm_id IN (
        SELECT f.id 
        FROM firms f 
        WHERE f.advocate_id = auth.uid()
      )
    )
  );

-- 8. Create RLS policies for attorney_matter_access
ALTER TABLE attorney_matter_access ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS attorney_matter_access_attorney_read ON attorney_matter_access;
DROP POLICY IF EXISTS attorney_matter_access_advocate_read ON attorney_matter_access;
DROP POLICY IF EXISTS attorney_matter_access_advocate_create ON attorney_matter_access;

-- Attorneys can see their own matter access
CREATE POLICY attorney_matter_access_attorney_read ON attorney_matter_access
  FOR SELECT
  USING (attorney_user_id = auth.uid());

-- Advocates can see matter access for their own matters
CREATE POLICY attorney_matter_access_advocate_read ON attorney_matter_access
  FOR SELECT
  USING (
    matter_id IN (
      SELECT m.id 
      FROM matters m 
      WHERE m.advocate_id = auth.uid()
    )
  );

-- Advocates can grant access to their own matters
CREATE POLICY attorney_matter_access_advocate_create ON attorney_matter_access
  FOR INSERT
  WITH CHECK (
    matter_id IN (
      SELECT m.id 
      FROM matters m 
      WHERE m.advocate_id = auth.uid()
    )
  );

-- 9. Create view for attorney accessible matters
CREATE OR REPLACE VIEW attorney_accessible_matters AS
SELECT 
  ama.attorney_user_id,
  m.*,
  f.firm_name,
  a.attorney_name AS instructing_attorney_name
FROM attorney_matter_access ama
JOIN matters m ON m.id = ama.matter_id
LEFT JOIN firms f ON f.id = m.firm_id
LEFT JOIN attorneys a ON a.id = m.instructing_attorney_id;

-- 10. Grant permissions
GRANT SELECT ON attorney_accessible_matters TO authenticated;

COMMENT ON TABLE attorney_invitation_tokens IS 'Stores portal invitation tokens sent to attorneys with 7-day expiry';
COMMENT ON TABLE attorney_matter_access IS 'Links registered attorneys to matters they can access in the portal';
COMMENT ON FUNCTION validate_invitation_token IS 'Validates invitation token and returns attorney details if valid';
COMMENT ON FUNCTION mark_invitation_used IS 'Marks invitation token as used when attorney registers';
COMMENT ON FUNCTION grant_attorney_matter_access IS 'Auto-grants matter access to attorney based on email when they register';
COMMENT ON VIEW attorney_accessible_matters IS 'Shows all matters accessible to each registered attorney';
