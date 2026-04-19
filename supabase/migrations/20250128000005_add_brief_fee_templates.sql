-- Migration: Brief Fee Templates System
-- Requirements: 11.1, 11.2, 11.3
-- Purpose: Enable advocates to create reusable brief fee templates for common case types

-- 1. Create brief_fee_templates table
CREATE TABLE IF NOT EXISTS brief_fee_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  advocate_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  template_name TEXT NOT NULL,
  case_type TEXT NOT NULL, -- e.g., 'Motion', 'Appeal', 'Trial', 'Consultation'
  description TEXT,
  is_default BOOLEAN DEFAULT FALSE,
  
  -- Fee Structure
  base_fee DECIMAL(10,2) NOT NULL CHECK (base_fee >= 0),
  hourly_rate DECIMAL(10,2) CHECK (hourly_rate >= 0),
  estimated_hours DECIMAL(5,2),
  
  -- Included Services (JSONB array)
  included_services JSONB DEFAULT '[]'::jsonb,
  -- Example: [
  --   {"name": "Initial consultation", "hours": 1, "rate": 2500},
  --   {"name": "Draft heads of argument", "hours": 4, "rate": 3000}
  -- ]
  
  -- Terms & Conditions
  payment_terms TEXT, -- e.g., "50% upfront, 50% on completion"
  cancellation_policy TEXT,
  additional_notes TEXT,
  
  -- Usage Tracking
  times_used INTEGER DEFAULT 0,
  last_used_at TIMESTAMPTZ,
  
  -- Metadata
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  deleted_at TIMESTAMPTZ
);

-- 2. Create indexes for efficient queries
CREATE UNIQUE INDEX IF NOT EXISTS idx_brief_fee_templates_unique_active_name
  ON brief_fee_templates(advocate_id, template_name)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_brief_fee_templates_advocate ON brief_fee_templates(advocate_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_brief_fee_templates_case_type ON brief_fee_templates(case_type) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_brief_fee_templates_default ON brief_fee_templates(advocate_id, is_default) WHERE is_default = TRUE AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_brief_fee_templates_used ON brief_fee_templates(times_used DESC) WHERE deleted_at IS NULL;

ALTER TABLE matters
ADD COLUMN IF NOT EXISTS template_id UUID REFERENCES brief_fee_templates(id) ON DELETE SET NULL;

ALTER TABLE matters
ADD COLUMN IF NOT EXISTS estimated_value DECIMAL(12,2);

-- 3. Create view for template usage statistics
CREATE OR REPLACE VIEW brief_fee_template_stats AS
SELECT 
  t.id AS template_id,
  t.template_name,
  t.case_type,
  t.base_fee,
  t.times_used,
  t.last_used_at,
  t.is_default,
  t.advocate_id,
  COUNT(m.id) AS matter_count,
  COALESCE(SUM(m.estimated_value), 0) AS total_estimated_value,
  COALESCE(AVG(m.estimated_value), 0) AS avg_matter_value
FROM brief_fee_templates t
LEFT JOIN matters m ON m.template_id = t.id AND m.deleted_at IS NULL
WHERE t.deleted_at IS NULL
GROUP BY t.id, t.template_name, t.case_type, t.base_fee, t.times_used, t.last_used_at, t.is_default, t.advocate_id;

-- 4. Create function to increment template usage counter
CREATE OR REPLACE FUNCTION increment_template_usage()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.template_id IS NOT NULL THEN
    UPDATE brief_fee_templates
    SET 
      times_used = times_used + 1,
      last_used_at = NOW(),
      updated_at = NOW()
    WHERE id = NEW.template_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Create trigger on matters table
DROP TRIGGER IF EXISTS trg_increment_template_usage ON matters;
CREATE TRIGGER trg_increment_template_usage
  AFTER INSERT ON matters
  FOR EACH ROW
  EXECUTE FUNCTION increment_template_usage();

-- 6. Create function to set default template (only one per case type)
CREATE OR REPLACE FUNCTION set_default_template(
  p_template_id UUID,
  p_advocate_id UUID,
  p_case_type TEXT
)
RETURNS VOID AS $$
BEGIN
  -- Unset all other defaults for this case type
  UPDATE brief_fee_templates
  SET is_default = FALSE, updated_at = NOW()
  WHERE advocate_id = p_advocate_id
    AND case_type = p_case_type
    AND id != p_template_id
    AND deleted_at IS NULL;
  
  -- Set the new default
  UPDATE brief_fee_templates
  SET is_default = TRUE, updated_at = NOW()
  WHERE id = p_template_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Create function to duplicate template
CREATE OR REPLACE FUNCTION duplicate_template(
  p_template_id UUID,
  p_new_name TEXT
)
RETURNS UUID AS $$
DECLARE
  v_new_id UUID;
  v_template RECORD;
BEGIN
  -- Get original template
  SELECT * INTO v_template
  FROM brief_fee_templates
  WHERE id = p_template_id;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Template not found';
  END IF;
  
  -- Create duplicate
  INSERT INTO brief_fee_templates (
    advocate_id,
    template_name,
    case_type,
    description,
    base_fee,
    hourly_rate,
    estimated_hours,
    included_services,
    payment_terms,
    cancellation_policy,
    additional_notes
  ) VALUES (
    v_template.advocate_id,
    p_new_name,
    v_template.case_type,
    v_template.description,
    v_template.base_fee,
    v_template.hourly_rate,
    v_template.estimated_hours,
    v_template.included_services,
    v_template.payment_terms,
    v_template.cancellation_policy,
    v_template.additional_notes
  ) RETURNING id INTO v_new_id;
  
  RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. Add template_id column to matters table
ALTER TABLE matters 
ADD COLUMN IF NOT EXISTS template_id UUID REFERENCES brief_fee_templates(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_matters_template ON matters(template_id) WHERE deleted_at IS NULL;

-- 9. Create RLS policies for brief_fee_templates
ALTER TABLE brief_fee_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS brief_fee_templates_advocate_read ON brief_fee_templates;
DROP POLICY IF EXISTS brief_fee_templates_advocate_create ON brief_fee_templates;
DROP POLICY IF EXISTS brief_fee_templates_advocate_update ON brief_fee_templates;
DROP POLICY IF EXISTS brief_fee_templates_advocate_delete ON brief_fee_templates;

-- Advocates can see only their own templates
CREATE POLICY brief_fee_templates_advocate_read ON brief_fee_templates
  FOR SELECT
  USING (advocate_id = auth.uid());

-- Advocates can create their own templates
CREATE POLICY brief_fee_templates_advocate_create ON brief_fee_templates
  FOR INSERT
  WITH CHECK (advocate_id = auth.uid());

-- Advocates can update their own templates
CREATE POLICY brief_fee_templates_advocate_update ON brief_fee_templates
  FOR UPDATE
  USING (advocate_id = auth.uid());

-- Advocates can delete their own templates (soft delete)
CREATE POLICY brief_fee_templates_advocate_delete ON brief_fee_templates
  FOR DELETE
  USING (advocate_id = auth.uid());

-- 10. Grant permissions
GRANT SELECT ON brief_fee_template_stats TO authenticated;

-- 11. Add comments for documentation
COMMENT ON TABLE brief_fee_templates IS 'Reusable templates for brief fee matters with predefined services and rates';
COMMENT ON VIEW brief_fee_template_stats IS 'Usage statistics for brief fee templates including matter count and values';
COMMENT ON FUNCTION increment_template_usage IS 'Auto-increments usage counter when template is used to create a matter';
COMMENT ON FUNCTION set_default_template IS 'Sets a template as default for a case type (only one default per type)';
COMMENT ON FUNCTION duplicate_template IS 'Creates a copy of an existing template with a new name';
COMMENT ON COLUMN matters.template_id IS 'Reference to the brief fee template used to create this matter';
