-- ============================================================================
-- Quick Brief Capture: Advocate Templates System
-- ============================================================================
-- This migration creates the advocate_quick_templates table for storing
-- custom templates that advocates use in the Quick Brief Capture feature.
-- Templates are categorized and track usage frequency for intelligent sorting.
-- ============================================================================

-- Create advocate_quick_templates table
CREATE TABLE IF NOT EXISTS advocate_quick_templates (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  advocate_id UUID REFERENCES user_profiles(user_id) ON DELETE CASCADE,
  category TEXT NOT NULL CHECK (category IN (
    'matter_title',
    'work_type',
    'practice_area',
    'urgency_preset',
    'issue_template'
  )),
  value TEXT NOT NULL,
  usage_count INTEGER DEFAULT 0,
  last_used_at TIMESTAMPTZ,
  is_custom BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Ensure unique templates per advocate per category
  UNIQUE(advocate_id, category, value)
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_advocate_templates_advocate 
  ON advocate_quick_templates(advocate_id);

CREATE INDEX IF NOT EXISTS idx_advocate_templates_category 
  ON advocate_quick_templates(advocate_id, category);

CREATE INDEX IF NOT EXISTS idx_advocate_templates_usage 
  ON advocate_quick_templates(advocate_id, category, usage_count DESC);

-- Add updated_at trigger
CREATE OR REPLACE FUNCTION update_advocate_quick_templates_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS advocate_quick_templates_updated_at ON advocate_quick_templates;
CREATE TRIGGER advocate_quick_templates_updated_at
  BEFORE UPDATE ON advocate_quick_templates
  FOR EACH ROW
  EXECUTE FUNCTION update_advocate_quick_templates_updated_at();

-- ============================================================================
-- Row Level Security (RLS) Policies
-- ============================================================================

-- Enable RLS
ALTER TABLE advocate_quick_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Advocates can view own templates" ON advocate_quick_templates;
DROP POLICY IF EXISTS "Advocates can insert own templates" ON advocate_quick_templates;
DROP POLICY IF EXISTS "Advocates can update own templates" ON advocate_quick_templates;
DROP POLICY IF EXISTS "Advocates can delete own templates" ON advocate_quick_templates;

-- Policy: Advocates can view their own templates and system defaults
CREATE POLICY "Advocates can view own templates"
  ON advocate_quick_templates FOR SELECT
  USING (advocate_id = auth.uid() OR advocate_id IS NULL);

-- Policy: Advocates can insert their own templates
CREATE POLICY "Advocates can insert own templates"
  ON advocate_quick_templates FOR INSERT
  WITH CHECK (advocate_id = auth.uid());

-- Policy: Advocates can update their own templates
CREATE POLICY "Advocates can update own templates"
  ON advocate_quick_templates FOR UPDATE
  USING (advocate_id = auth.uid());

-- Policy: Advocates can delete their own templates
CREATE POLICY "Advocates can delete own templates"
  ON advocate_quick_templates FOR DELETE
  USING (advocate_id = auth.uid());

-- ============================================================================
-- Seed System Default Templates
-- ============================================================================

-- Default work types
INSERT INTO advocate_quick_templates (advocate_id, category, value, is_custom, usage_count) VALUES
  (NULL, 'work_type', 'Opinion', false, 0),
  (NULL, 'work_type', 'Court Appearance', false, 0),
  (NULL, 'work_type', 'Drafting', false, 0),
  (NULL, 'work_type', 'Research', false, 0),
  (NULL, 'work_type', 'Consultation', false, 0),
  (NULL, 'work_type', 'Heads of Argument', false, 0),
  (NULL, 'work_type', 'Arbitration', false, 0),
  (NULL, 'work_type', 'Mediation', false, 0)
ON CONFLICT (advocate_id, category, value) DO NOTHING;

-- Default practice areas
INSERT INTO advocate_quick_templates (advocate_id, category, value, is_custom, usage_count) VALUES
  (NULL, 'practice_area', 'Labour Law', false, 0),
  (NULL, 'practice_area', 'Commercial', false, 0),
  (NULL, 'practice_area', 'Tax', false, 0),
  (NULL, 'practice_area', 'Constitutional', false, 0),
  (NULL, 'practice_area', 'Criminal', false, 0),
  (NULL, 'practice_area', 'Family', false, 0),
  (NULL, 'practice_area', 'Property', false, 0),
  (NULL, 'practice_area', 'Administrative', false, 0),
  (NULL, 'practice_area', 'Insolvency', false, 0),
  (NULL, 'practice_area', 'Competition', false, 0)
ON CONFLICT (advocate_id, category, value) DO NOTHING;

-- Default urgency presets
INSERT INTO advocate_quick_templates (advocate_id, category, value, is_custom, usage_count) VALUES
  (NULL, 'urgency_preset', 'Same Day', false, 0),
  (NULL, 'urgency_preset', '1-2 Days', false, 0),
  (NULL, 'urgency_preset', 'Within a Week', false, 0),
  (NULL, 'urgency_preset', 'Within 2 Weeks', false, 0),
  (NULL, 'urgency_preset', 'Within a Month', false, 0)
ON CONFLICT (advocate_id, category, value) DO NOTHING;

-- Default issue templates
INSERT INTO advocate_quick_templates (advocate_id, category, value, is_custom, usage_count) VALUES
  (NULL, 'issue_template', 'Breach of Contract', false, 0),
  (NULL, 'issue_template', 'Employment Dispute', false, 0),
  (NULL, 'issue_template', 'Restraint of Trade', false, 0),
  (NULL, 'issue_template', 'Shareholder Dispute', false, 0),
  (NULL, 'issue_template', 'Tax Assessment Challenge', false, 0),
  (NULL, 'issue_template', 'Unfair Dismissal', false, 0),
  (NULL, 'issue_template', 'Contractual Interpretation', false, 0),
  (NULL, 'issue_template', 'Delictual Claim', false, 0)
ON CONFLICT (advocate_id, category, value) DO NOTHING;

-- Default matter title templates
INSERT INTO advocate_quick_templates (advocate_id, category, value, is_custom, usage_count) VALUES
  (NULL, 'matter_title', 'Contract Dispute - [Client Name]', false, 0),
  (NULL, 'matter_title', 'Opinion on [Topic]', false, 0),
  (NULL, 'matter_title', 'Court Appearance - [Case Name]', false, 0),
  (NULL, 'matter_title', '[Client Name] v [Opposing Party]', false, 0),
  (NULL, 'matter_title', 'Consultation - [Matter Type]', false, 0)
ON CONFLICT (advocate_id, category, value) DO NOTHING;

-- ============================================================================
-- Add practice_area column to matters table (if not exists)
-- ============================================================================

DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'matters' AND column_name = 'practice_area'
  ) THEN
    ALTER TABLE matters ADD COLUMN practice_area TEXT;
    
    -- Add index for filtering by practice area
    CREATE INDEX IF NOT EXISTS idx_matters_practice_area ON matters(practice_area);
    
    COMMENT ON COLUMN matters.practice_area IS 'Practice area categorization for the matter (e.g., Labour Law, Commercial, Tax)';
  END IF;
END $$;

-- ============================================================================
-- Add creation_source column to matters table (if not exists)
-- ============================================================================

DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'matters' AND column_name = 'creation_source'
  ) THEN
    ALTER TABLE matters ADD COLUMN creation_source TEXT CHECK (creation_source IN (
      'manual',
      'attorney_portal',
      'quick_brief_capture',
      'pro_forma_conversion',
      'import'
    ));
    
    -- Add index for analytics
    CREATE INDEX IF NOT EXISTS idx_matters_creation_source ON matters(creation_source);
    
    COMMENT ON COLUMN matters.creation_source IS 'Source of matter creation for analytics and tracking';
  END IF;
END $$;

-- ============================================================================
-- Add is_quick_create column to matters table (if not exists)
-- ============================================================================

DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'matters' AND column_name = 'is_quick_create'
  ) THEN
    ALTER TABLE matters ADD COLUMN is_quick_create BOOLEAN DEFAULT false;
    
    -- Add index for filtering quick-created matters
    CREATE INDEX IF NOT EXISTS idx_matters_quick_create ON matters(is_quick_create) WHERE is_quick_create = true;
    
    COMMENT ON COLUMN matters.is_quick_create IS 'Flag indicating matter was created via Quick Brief Capture';
  END IF;
END $$;

-- ============================================================================
-- Comments for documentation
-- ============================================================================

COMMENT ON TABLE advocate_quick_templates IS 'Stores custom templates for Quick Brief Capture feature, including system defaults and advocate-specific templates';
COMMENT ON COLUMN advocate_quick_templates.advocate_id IS 'Reference to user_profiles.user_id, or NULL for system default templates';
COMMENT ON COLUMN advocate_quick_templates.category IS 'Template category: matter_title, work_type, practice_area, urgency_preset, or issue_template';
COMMENT ON COLUMN advocate_quick_templates.value IS 'The template text/value';
COMMENT ON COLUMN advocate_quick_templates.usage_count IS 'Number of times this template has been used (for sorting by frequency)';
COMMENT ON COLUMN advocate_quick_templates.last_used_at IS 'Timestamp of last usage for recency sorting';
COMMENT ON COLUMN advocate_quick_templates.is_custom IS 'True for advocate-created templates, false for system defaults';

-- ============================================================================
-- Grant permissions
-- ============================================================================

-- Grant authenticated users access to the table
GRANT SELECT, INSERT, UPDATE, DELETE ON advocate_quick_templates TO authenticated;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_class
    WHERE relkind = 'S'
      AND relname = 'advocate_quick_templates_id_seq'
  ) THEN
    EXECUTE 'GRANT USAGE ON SEQUENCE advocate_quick_templates_id_seq TO authenticated';
  END IF;
END $$;

-- ============================================================================
-- Migration complete
-- ============================================================================

-- Log migration completion
DO $$
BEGIN
  RAISE NOTICE 'Migration 20250127000000_create_advocate_quick_templates completed successfully';
  RAISE NOTICE 'Created advocate_quick_templates table with % system templates', 
    (SELECT COUNT(*) FROM advocate_quick_templates WHERE advocate_id IS NULL);
END $$;
