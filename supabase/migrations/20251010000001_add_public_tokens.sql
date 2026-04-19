-- Add public tokens for attorney portal access
-- Migration: 20251010_add_public_tokens

-- Add public_token to proforma_requests table
ALTER TABLE proforma_requests 
ADD COLUMN IF NOT EXISTS public_token UUID DEFAULT gen_random_uuid() UNIQUE;

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_proforma_public_token 
ON proforma_requests(public_token);

-- Add public_token to engagement_agreements table
ALTER TABLE engagement_agreements 
ADD COLUMN IF NOT EXISTS public_token UUID DEFAULT gen_random_uuid() UNIQUE;

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_engagement_public_token 
ON engagement_agreements(public_token);

-- Add email tracking columns
ALTER TABLE proforma_requests
ADD COLUMN IF NOT EXISTS link_sent_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS link_sent_to TEXT;

ALTER TABLE engagement_agreements
ADD COLUMN IF NOT EXISTS link_sent_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS link_sent_to TEXT;

-- Function to regenerate public token (for security)
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

-- Grant execute permission
GRANT EXECUTE ON FUNCTION regenerate_public_token TO authenticated;

COMMENT ON COLUMN proforma_requests.public_token IS 'Unique token for attorney portal access';
COMMENT ON COLUMN engagement_agreements.public_token IS 'Unique token for attorney signing portal access';
