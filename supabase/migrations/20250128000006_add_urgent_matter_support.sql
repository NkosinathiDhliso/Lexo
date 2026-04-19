-- Migration: Add Urgent Matter Support
-- Description: Add urgency tracking to matters table and create utility functions
-- Requirements: 7.1, 7.2, 7.6

-- Add urgency columns to matters table
ALTER TABLE matters
ADD COLUMN IF NOT EXISTS is_urgent BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS urgency_reason TEXT,
ADD COLUMN IF NOT EXISTS urgent_created_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS urgent_deadline TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS instructing_attorney TEXT,
ADD COLUMN IF NOT EXISTS instructing_firm TEXT;

ALTER TABLE advocates
ADD COLUMN IF NOT EXISTS first_name TEXT,
ADD COLUMN IF NOT EXISTS last_name TEXT,
ADD COLUMN IF NOT EXISTS full_name TEXT;

-- Add indexes for urgent matter filtering
CREATE INDEX IF NOT EXISTS idx_matters_urgent ON matters(is_urgent) WHERE is_urgent = TRUE;
CREATE INDEX IF NOT EXISTS idx_matters_urgent_deadline ON matters(urgent_deadline) WHERE is_urgent = TRUE AND urgent_deadline IS NOT NULL;

-- Add comments
COMMENT ON COLUMN matters.is_urgent IS 'Flag indicating this is an urgent matter (bypasses pro forma)';
COMMENT ON COLUMN matters.urgency_reason IS 'Reason for urgency (e.g., "Bail hearing tomorrow")';
COMMENT ON COLUMN matters.urgent_created_at IS 'Timestamp when matter was marked urgent';
COMMENT ON COLUMN matters.urgent_deadline IS 'Optional deadline for urgent matter';

-- Update existing matters to set is_urgent = FALSE if NULL
UPDATE matters SET is_urgent = FALSE WHERE is_urgent IS NULL;

-- Create function to automatically set urgent_created_at
CREATE OR REPLACE FUNCTION set_urgent_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.is_urgent = TRUE AND OLD.is_urgent = FALSE THEN
    NEW.urgent_created_at = NOW();
  ELSIF NEW.is_urgent = FALSE THEN
    NEW.urgent_created_at = NULL;
    NEW.urgency_reason = NULL;
    NEW.urgent_deadline = NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for urgent timestamp
DROP TRIGGER IF EXISTS trg_set_urgent_timestamp ON matters;
CREATE TRIGGER trg_set_urgent_timestamp
  BEFORE UPDATE ON matters
  FOR EACH ROW
  EXECUTE FUNCTION set_urgent_timestamp();

-- Create view for urgent matters dashboard
CREATE OR REPLACE VIEW urgent_matters_view AS
SELECT 
  m.id,
  m.reference_number,
  m.title,
  m.matter_type,
  m.client_name,
  m.instructing_attorney,
  m.instructing_firm,
  m.agreed_fee,
  m.status,
  m.urgency_reason,
  m.urgent_created_at,
  m.urgent_deadline,
  m.created_at,
  COALESCE(
    NULLIF(TRIM(COALESCE(a.first_name, '') || ' ' || COALESCE(a.last_name, '')), ''),
    a.full_name,
    a.email
  ) AS advocate_name,
  EXTRACT(EPOCH FROM (NOW() - m.urgent_created_at)) / 3600 AS hours_since_urgent,
  CASE 
    WHEN m.urgent_deadline IS NOT NULL THEN
      EXTRACT(EPOCH FROM (m.urgent_deadline - NOW())) / 3600
    ELSE NULL
  END AS hours_until_deadline
FROM matters m
JOIN advocates a ON m.advocate_id = a.id
WHERE m.is_urgent = TRUE
  AND m.archived_at IS NULL
ORDER BY m.urgent_created_at DESC;

COMMENT ON VIEW urgent_matters_view IS 'Dashboard view for all active urgent matters with time tracking';

-- Grant permissions
GRANT SELECT ON urgent_matters_view TO authenticated;
GRANT SELECT ON urgent_matters_view TO service_role;
