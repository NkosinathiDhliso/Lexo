-- Partner Approval System
-- Migration: 20251010000002_add_partner_approvals

-- Create partner_approvals table
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

-- Add billing_status to matters table
ALTER TABLE matters
ADD COLUMN IF NOT EXISTS billing_status TEXT CHECK (billing_status IN ('pending', 'approved', 'rejected', 'invoiced')) DEFAULT 'pending';

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_partner_approvals_matter_id ON partner_approvals(matter_id);
CREATE INDEX IF NOT EXISTS idx_partner_approvals_partner_id ON partner_approvals(partner_id);
CREATE INDEX IF NOT EXISTS idx_partner_approvals_status ON partner_approvals(status);
CREATE INDEX IF NOT EXISTS idx_matters_billing_status ON matters(billing_status);

-- Enable RLS
ALTER TABLE partner_approvals ENABLE ROW LEVEL SECURITY;

-- RLS Policies for partner_approvals (drop if exists first)
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

-- Function to update matter billing status
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

-- Trigger to auto-update matter billing status
DROP TRIGGER IF EXISTS trigger_update_matter_billing_status ON partner_approvals;
CREATE TRIGGER trigger_update_matter_billing_status
  AFTER INSERT OR UPDATE OF status ON partner_approvals
  FOR EACH ROW
  EXECUTE FUNCTION update_matter_billing_status();

-- Grant permissions
GRANT SELECT, INSERT, UPDATE ON partner_approvals TO authenticated;

COMMENT ON TABLE partner_approvals IS 'Partner approval records for billing readiness';
COMMENT ON COLUMN matters.billing_status IS 'Current billing approval status';
