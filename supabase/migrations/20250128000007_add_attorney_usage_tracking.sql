-- Migration: Attorney Usage Tracking System
-- Description: Track attorney usage frequency and enable recurring attorney features
-- Requirements: 8.3, 8.4, 8.5

-- Create attorney usage stats table
CREATE TABLE IF NOT EXISTS attorney_usage_stats (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
  attorney_id UUID NOT NULL REFERENCES attorneys(id) ON DELETE CASCADE,
  firm_id UUID REFERENCES firms(id) ON DELETE CASCADE,
  
  -- Usage tracking
  matter_count INTEGER DEFAULT 0,
  last_worked_with TIMESTAMPTZ,
  first_worked_with TIMESTAMPTZ,
  total_fees_paid DECIMAL(10,2) DEFAULT 0,
  
  -- Metadata
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Unique constraint: one stats record per advocate-attorney pair
  UNIQUE(advocate_id, attorney_id)
);

-- Create indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_attorney_usage_advocate ON attorney_usage_stats(advocate_id);
CREATE INDEX IF NOT EXISTS idx_attorney_usage_attorney ON attorney_usage_stats(attorney_id);
CREATE INDEX IF NOT EXISTS idx_attorney_usage_last_worked ON attorney_usage_stats(advocate_id, last_worked_with DESC);
CREATE INDEX IF NOT EXISTS idx_attorney_usage_matter_count ON attorney_usage_stats(advocate_id, matter_count DESC);

-- Add comments
COMMENT ON TABLE attorney_usage_stats IS 'Tracks attorney usage frequency for recurring attorney features';
COMMENT ON COLUMN attorney_usage_stats.matter_count IS 'Total number of matters with this attorney';
COMMENT ON COLUMN attorney_usage_stats.last_worked_with IS 'Most recent matter creation date';
COMMENT ON COLUMN attorney_usage_stats.first_worked_with IS 'First matter creation date';
COMMENT ON COLUMN attorney_usage_stats.total_fees_paid IS 'Total fees paid by this attorney across all matters';

-- Add portal invitation fields to attorneys table
ALTER TABLE attorneys
ADD COLUMN IF NOT EXISTS portal_invitation_sent BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS portal_invitation_sent_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS portal_invitation_accepted BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS portal_invitation_accepted_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS is_registered BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id);

-- Create index for registration status queries
CREATE INDEX IF NOT EXISTS idx_attorneys_registered ON attorneys(is_registered);
CREATE INDEX IF NOT EXISTS idx_attorneys_pending_invitation ON attorneys(portal_invitation_sent, portal_invitation_accepted) 
  WHERE portal_invitation_sent = TRUE AND portal_invitation_accepted = FALSE;

-- Add comments
COMMENT ON COLUMN attorneys.portal_invitation_sent IS 'Whether portal invitation email has been sent';
COMMENT ON COLUMN attorneys.portal_invitation_sent_at IS 'When portal invitation was sent';
COMMENT ON COLUMN attorneys.portal_invitation_accepted IS 'Whether attorney has accepted and registered';
COMMENT ON COLUMN attorneys.is_registered IS 'Whether attorney has a user account';
COMMENT ON COLUMN attorneys.user_id IS 'Link to auth.users if attorney is registered';

-- Function to increment attorney usage stats
CREATE OR REPLACE FUNCTION increment_attorney_usage_stats()
RETURNS TRIGGER AS $$
BEGIN
  -- Only process when a new matter is created with an attorney
  IF TG_OP = 'INSERT' AND NEW.instructing_attorney IS NOT NULL THEN
    -- Try to find the attorney record
    DECLARE
      v_attorney_id UUID;
      v_firm_id UUID;
    BEGIN
      -- Find attorney by name and email (loose matching)
      SELECT id, firm_id INTO v_attorney_id, v_firm_id
      FROM attorneys
      WHERE attorney_name = NEW.instructing_attorney
        AND email = NEW.instructing_attorney_email
      LIMIT 1;
      
      -- If attorney found, update or insert usage stats
      IF v_attorney_id IS NOT NULL THEN
        INSERT INTO attorney_usage_stats (
          advocate_id,
          attorney_id,
          firm_id,
          matter_count,
          last_worked_with,
          first_worked_with
        ) VALUES (
          NEW.advocate_id,
          v_attorney_id,
          v_firm_id,
          1,
          NEW.created_at,
          NEW.created_at
        )
        ON CONFLICT (advocate_id, attorney_id) 
        DO UPDATE SET
          matter_count = attorney_usage_stats.matter_count + 1,
          last_worked_with = NEW.created_at,
          updated_at = NOW();
      END IF;
    END;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger to auto-update usage stats
DROP TRIGGER IF EXISTS trg_increment_attorney_usage_stats ON matters;
CREATE TRIGGER trg_increment_attorney_usage_stats
  AFTER INSERT ON matters
  FOR EACH ROW
  EXECUTE FUNCTION increment_attorney_usage_stats();

-- Create view for recurring attorneys (top 10 by usage)
CREATE OR REPLACE VIEW recurring_attorneys_view AS
SELECT 
  aus.advocate_id,
  a.id AS attorney_id,
  a.attorney_name,
  a.email,
  a.phone,
  f.id AS firm_id,
  f.firm_name,
  aus.matter_count,
  aus.last_worked_with,
  aus.first_worked_with,
  aus.total_fees_paid,
  a.is_registered,
  a.portal_invitation_sent,
  a.portal_invitation_accepted,
  -- Calculate recency score (matters in last 90 days)
  (
    SELECT COUNT(*)
    FROM matters m
    WHERE m.advocate_id = aus.advocate_id
      AND m.instructing_attorney_email = a.email
      AND m.created_at > NOW() - INTERVAL '90 days'
  ) AS recent_matter_count,
  -- Days since last worked
  EXTRACT(EPOCH FROM (NOW() - aus.last_worked_with)) / 86400 AS days_since_last_worked
FROM attorney_usage_stats aus
JOIN attorneys a ON aus.attorney_id = a.id
LEFT JOIN firms f ON aus.firm_id = f.id
WHERE aus.matter_count > 0
ORDER BY aus.matter_count DESC, aus.last_worked_with DESC;

COMMENT ON VIEW recurring_attorneys_view IS 'Dashboard view for frequently used attorneys with usage statistics';

-- Grant permissions
GRANT SELECT ON attorney_usage_stats TO authenticated;
GRANT INSERT, UPDATE ON attorney_usage_stats TO authenticated;
GRANT SELECT ON recurring_attorneys_view TO authenticated;

-- Enable RLS
ALTER TABLE attorney_usage_stats ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Advocates can only see their own usage stats
CREATE POLICY "Advocates manage own attorney usage stats"
ON attorney_usage_stats
FOR ALL
USING (advocate_id = auth.uid());
