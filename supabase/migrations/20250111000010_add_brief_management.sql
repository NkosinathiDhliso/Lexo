-- ============================================================================
-- Brief Management System
-- Addresses workflow disconnect: Multiple briefs per case
-- ============================================================================

-- Brief Status Enum
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'brief_status') THEN
    CREATE TYPE brief_status AS ENUM (
      'pending',
      'active',
      'completed',
      'cancelled'
    );
  END IF;
END
$$;

-- Brief Type Enum (South African advocate practice)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'brief_type') THEN
    CREATE TYPE brief_type AS ENUM (
      'opinion',
      'drafting',
      'consultation',
      'trial',
      'appeal',
      'application',
      'motion',
      'arbitration',
      'mediation',
      'other'
    );
  END IF;
END
$$;

-- Briefs Table
-- Represents individual briefs within a matter
-- A matter (case) can have multiple briefs over time
CREATE TABLE IF NOT EXISTS briefs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  matter_id UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
  advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
  
  -- Brief identification
  brief_number TEXT UNIQUE,
  brief_title TEXT NOT NULL,
  brief_type brief_type NOT NULL,
  description TEXT,
  
  -- Brief details
  date_received DATE NOT NULL DEFAULT CURRENT_DATE,
  date_accepted DATE,
  deadline DATE,
  date_completed DATE,
  
  -- Financial terms (can differ per brief)
  fee_type fee_type DEFAULT 'hourly',
  agreed_fee DECIMAL(12,2),
  fee_cap DECIMAL(12,2),
  
  -- Brief status
  status brief_status DEFAULT 'pending',
  priority TEXT CHECK (priority IN ('low', 'medium', 'high', 'urgent')) DEFAULT 'medium',
  
  -- Work tracking
  wip_value DECIMAL(12,2) DEFAULT 0,
  billed_amount DECIMAL(12,2) DEFAULT 0,
  
  -- Source tracking
  source_proforma_id UUID REFERENCES proforma_requests(id) ON DELETE SET NULL,
  
  -- Metadata
  notes TEXT,
  tags TEXT[],
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  deleted_at TIMESTAMPTZ
);

-- Add brief_id to time_entries (optional - allows tracking time to specific briefs)
ALTER TABLE time_entries 
ADD COLUMN IF NOT EXISTS brief_id UUID REFERENCES briefs(id) ON DELETE SET NULL;

-- Add brief_id to expenses (optional - allows tracking expenses to specific briefs)
ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS brief_id UUID REFERENCES briefs(id) ON DELETE SET NULL;

-- Add brief_id to invoices (optional - allows invoicing specific briefs)
ALTER TABLE invoices 
ADD COLUMN IF NOT EXISTS brief_id UUID REFERENCES briefs(id) ON DELETE SET NULL;

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_briefs_matter ON briefs(matter_id);
CREATE INDEX IF NOT EXISTS idx_briefs_advocate ON briefs(advocate_id);
CREATE INDEX IF NOT EXISTS idx_briefs_status ON briefs(status);
CREATE INDEX IF NOT EXISTS idx_briefs_brief_number ON briefs(brief_number);
CREATE INDEX IF NOT EXISTS idx_briefs_date_received ON briefs(date_received DESC);
CREATE INDEX IF NOT EXISTS idx_briefs_deadline ON briefs(deadline);
CREATE INDEX IF NOT EXISTS idx_briefs_source_proforma ON briefs(source_proforma_id);

CREATE INDEX IF NOT EXISTS idx_time_entries_brief ON time_entries(brief_id);
CREATE INDEX IF NOT EXISTS idx_expenses_brief ON expenses(brief_id);
CREATE INDEX IF NOT EXISTS idx_invoices_brief ON invoices(brief_id);

-- ============================================================================
-- Functions
-- ============================================================================

-- Function to generate brief reference number
-- Format: BRF-YYYY-NNNN
CREATE OR REPLACE FUNCTION generate_brief_number()
RETURNS TEXT AS $$
DECLARE
  year_part TEXT;
  sequence_num INTEGER;
  brief_num TEXT;
BEGIN
  year_part := TO_CHAR(CURRENT_DATE, 'YYYY');
  
  SELECT COALESCE(MAX(
    CAST(SUBSTRING(brief_number FROM 'BRF-\d{4}-(\d+)') AS INTEGER)
  ), 0) + 1
  INTO sequence_num
  FROM briefs
  WHERE brief_number LIKE 'BRF-' || year_part || '-%';
  
  brief_num := 'BRF-' || year_part || '-' || LPAD(sequence_num::TEXT, 4, '0');
  
  RETURN brief_num;
END;
$$ LANGUAGE plpgsql;

-- Trigger to auto-generate brief number
CREATE OR REPLACE FUNCTION set_brief_number_trigger()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.brief_number IS NULL THEN
    NEW.brief_number := generate_brief_number();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_brief_number ON briefs;
CREATE TRIGGER set_brief_number
  BEFORE INSERT ON briefs
  FOR EACH ROW
  WHEN (NEW.brief_number IS NULL)
  EXECUTE FUNCTION set_brief_number_trigger();

-- Function to update brief WIP value
CREATE OR REPLACE FUNCTION update_brief_wip()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE briefs
  SET wip_value = (
    SELECT COALESCE(SUM(amount), 0)
    FROM time_entries
    WHERE brief_id = COALESCE(NEW.brief_id, OLD.brief_id)
      AND is_billed = false
  ) + (
    SELECT COALESCE(SUM(amount), 0)
    FROM expenses
    WHERE brief_id = COALESCE(NEW.brief_id, OLD.brief_id)
      AND billed = false
  )
  WHERE id = COALESCE(NEW.brief_id, OLD.brief_id);
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Triggers to update brief WIP
DROP TRIGGER IF EXISTS update_brief_wip_on_time_entry ON time_entries;
CREATE TRIGGER update_brief_wip_on_time_entry
  AFTER INSERT OR UPDATE OR DELETE ON time_entries
  FOR EACH ROW
  EXECUTE FUNCTION update_brief_wip();

DROP TRIGGER IF EXISTS update_brief_wip_on_expense ON expenses;
CREATE TRIGGER update_brief_wip_on_expense
  AFTER INSERT OR UPDATE OR DELETE ON expenses
  FOR EACH ROW
  EXECUTE FUNCTION update_brief_wip();

-- Update timestamp trigger
DROP TRIGGER IF EXISTS update_briefs_updated_at ON briefs;
CREATE TRIGGER update_briefs_updated_at
  BEFORE UPDATE ON briefs
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- ============================================================================
-- Row Level Security (RLS)
-- ============================================================================

ALTER TABLE briefs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own briefs" ON briefs;
DROP POLICY IF EXISTS "Users can create briefs" ON briefs;
DROP POLICY IF EXISTS "Users can update their own briefs" ON briefs;
DROP POLICY IF EXISTS "Users can delete their own briefs" ON briefs;

CREATE POLICY "Users can view their own briefs"
  ON briefs FOR SELECT
  USING (advocate_id = auth.uid());

CREATE POLICY "Users can create briefs"
  ON briefs FOR INSERT
  WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "Users can update their own briefs"
  ON briefs FOR UPDATE
  USING (advocate_id = auth.uid());

CREATE POLICY "Users can delete their own briefs"
  ON briefs FOR DELETE
  USING (advocate_id = auth.uid());

-- ============================================================================
-- Comments
-- ============================================================================

COMMENT ON TABLE briefs IS 'Individual briefs within a matter - allows multiple briefs per case';
COMMENT ON COLUMN briefs.brief_number IS 'Auto-generated: BRF-YYYY-NNNN';
COMMENT ON COLUMN briefs.matter_id IS 'Links to the parent matter/case';
COMMENT ON COLUMN briefs.brief_type IS 'Type of legal work: opinion, drafting, trial, etc.';
COMMENT ON COLUMN briefs.source_proforma_id IS 'Links to pro forma if brief was created from one';
COMMENT ON COLUMN briefs.wip_value IS 'Work in Progress value for this specific brief';
COMMENT ON COLUMN briefs.billed_amount IS 'Total amount already billed for this brief';

COMMENT ON COLUMN time_entries.brief_id IS 'Optional: Links time entry to specific brief within matter';
COMMENT ON COLUMN expenses.brief_id IS 'Optional: Links expense to specific brief within matter';
COMMENT ON COLUMN invoices.brief_id IS 'Optional: Links invoice to specific brief within matter';
