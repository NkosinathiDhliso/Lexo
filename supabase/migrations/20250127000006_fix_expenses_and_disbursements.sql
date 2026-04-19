-- Fix expenses and disbursements schema issues
-- This migration addresses:
-- 1. Missing disbursements table (code expects it but it doesn't exist)
-- 2. Missing columns in expenses table (payment_date, disbursement_type, etc.)
-- 3. RLS policies for logged_services table

-- ============================================================================
-- PART 1: Create disbursements table (if it doesn't exist)
-- ============================================================================

CREATE TABLE IF NOT EXISTS disbursements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  matter_id UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
  advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
  
  description TEXT NOT NULL CHECK (length(description) >= 3),
  amount DECIMAL(12,2) NOT NULL CHECK (amount > 0),
  date_incurred DATE NOT NULL DEFAULT CURRENT_DATE,
  
  vat_applicable BOOLEAN DEFAULT true,
  vat_amount DECIMAL(12,2) GENERATED ALWAYS AS (
    CASE WHEN vat_applicable THEN amount * 0.15 ELSE 0 END
  ) STORED,
  total_amount DECIMAL(12,2) GENERATED ALWAYS AS (
    CASE WHEN vat_applicable THEN amount * 1.15 ELSE amount END
  ) STORED,
  
  receipt_link TEXT,
  invoice_id UUID REFERENCES invoices(id) ON DELETE SET NULL,
  is_billed BOOLEAN DEFAULT false,
  
  deleted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for disbursements
CREATE INDEX IF NOT EXISTS idx_disbursements_matter ON disbursements(matter_id);
CREATE INDEX IF NOT EXISTS idx_disbursements_advocate ON disbursements(advocate_id);
CREATE INDEX IF NOT EXISTS idx_disbursements_invoice ON disbursements(invoice_id);
CREATE INDEX IF NOT EXISTS idx_disbursements_date ON disbursements(date_incurred);
CREATE INDEX IF NOT EXISTS idx_disbursements_is_billed ON disbursements(is_billed);
CREATE INDEX IF NOT EXISTS idx_disbursements_deleted ON disbursements(deleted_at) WHERE deleted_at IS NULL;

-- Add updated_at trigger for disbursements
CREATE OR REPLACE FUNCTION update_disbursements_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS disbursements_updated_at ON disbursements;
CREATE TRIGGER disbursements_updated_at
  BEFORE UPDATE ON disbursements
  FOR EACH ROW
  EXECUTE FUNCTION update_disbursements_updated_at();

-- Enable RLS for disbursements
ALTER TABLE disbursements ENABLE ROW LEVEL SECURITY;

-- RLS Policies for disbursements
DROP POLICY IF EXISTS "Advocates can view own disbursements" ON disbursements;
CREATE POLICY "Advocates can view own disbursements"
  ON disbursements
  FOR SELECT
  TO authenticated
  USING (advocate_id = auth.uid() AND deleted_at IS NULL);

DROP POLICY IF EXISTS "Advocates can insert own disbursements" ON disbursements;
CREATE POLICY "Advocates can insert own disbursements"
  ON disbursements
  FOR INSERT
  TO authenticated
  WITH CHECK (advocate_id = auth.uid());

DROP POLICY IF EXISTS "Advocates can update own unbilled disbursements" ON disbursements;
CREATE POLICY "Advocates can update own unbilled disbursements"
  ON disbursements
  FOR UPDATE
  TO authenticated
  USING (advocate_id = auth.uid() AND is_billed = false AND deleted_at IS NULL)
  WITH CHECK (advocate_id = auth.uid() AND is_billed = false);

DROP POLICY IF EXISTS "Advocates can delete own unbilled disbursements" ON disbursements;
CREATE POLICY "Advocates can delete own unbilled disbursements"
  ON disbursements
  FOR DELETE
  TO authenticated
  USING (advocate_id = auth.uid() AND is_billed = false AND deleted_at IS NULL);

-- ============================================================================
-- PART 2: Add missing columns to expenses table
-- ============================================================================

-- Add missing columns if they don't exist
DO $$ 
BEGIN
  -- Add disbursement_type column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'expenses' AND column_name = 'disbursement_type'
  ) THEN
    ALTER TABLE expenses ADD COLUMN disbursement_type TEXT DEFAULT 'other';
  END IF;

  -- Add payment_date column (alias for expense_date)
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'expenses' AND column_name = 'payment_date'
  ) THEN
    ALTER TABLE expenses ADD COLUMN payment_date DATE;
    -- Copy existing expense_date values
    UPDATE expenses SET payment_date = expense_date WHERE payment_date IS NULL;
    -- Set default
    ALTER TABLE expenses ALTER COLUMN payment_date SET DEFAULT CURRENT_DATE;
    ALTER TABLE expenses ALTER COLUMN payment_date SET NOT NULL;
  END IF;

  -- Add date column (alias for expense_date for backwards compatibility)
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'expenses' AND column_name = 'date'
  ) THEN
    ALTER TABLE expenses ADD COLUMN date DATE;
    -- Copy existing expense_date values
    UPDATE expenses SET date = expense_date WHERE date IS NULL;
    -- Set default
    ALTER TABLE expenses ALTER COLUMN date SET DEFAULT CURRENT_DATE;
    ALTER TABLE expenses ALTER COLUMN date SET NOT NULL;
  END IF;

  -- Add receipt_number column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'expenses' AND column_name = 'receipt_number'
  ) THEN
    ALTER TABLE expenses ADD COLUMN receipt_number TEXT;
  END IF;

  -- Add vendor_name column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'expenses' AND column_name = 'vendor_name'
  ) THEN
    ALTER TABLE expenses ADD COLUMN vendor_name TEXT;
  END IF;

  -- Add is_billable column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'expenses' AND column_name = 'is_billable'
  ) THEN
    ALTER TABLE expenses ADD COLUMN is_billable BOOLEAN DEFAULT true;
  END IF;
END $$;

-- Create trigger to keep date and expense_date in sync
CREATE OR REPLACE FUNCTION sync_expenses_date_columns()
RETURNS TRIGGER AS $$
BEGIN
  -- If date is updated, sync to expense_date and payment_date
  IF NEW.date IS DISTINCT FROM OLD.date THEN
    NEW.expense_date = NEW.date;
    NEW.payment_date = NEW.date;
  END IF;
  
  -- If expense_date is updated, sync to date and payment_date
  IF NEW.expense_date IS DISTINCT FROM OLD.expense_date THEN
    NEW.date = NEW.expense_date;
    NEW.payment_date = NEW.expense_date;
  END IF;
  
  -- If payment_date is updated, sync to date and expense_date
  IF NEW.payment_date IS DISTINCT FROM OLD.payment_date THEN
    NEW.date = NEW.payment_date;
    NEW.expense_date = NEW.payment_date;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS expenses_sync_date_columns ON expenses;
CREATE TRIGGER expenses_sync_date_columns
  BEFORE INSERT OR UPDATE ON expenses
  FOR EACH ROW
  EXECUTE FUNCTION sync_expenses_date_columns();

-- ============================================================================
-- PART 3: Fix logged_services RLS policies
-- ============================================================================

-- Drop existing policies if they exist
DROP POLICY IF EXISTS "Advocates can view own logged services" ON logged_services;
DROP POLICY IF EXISTS "Advocates can insert own logged services" ON logged_services;
DROP POLICY IF EXISTS "Advocates can update own uninvoiced logged services" ON logged_services;
DROP POLICY IF EXISTS "Advocates can delete own uninvoiced logged services" ON logged_services;

-- Recreate with correct permissions
CREATE POLICY "Advocates can view own logged services"
  ON logged_services
  FOR SELECT
  TO authenticated
  USING (advocate_id = auth.uid());

CREATE POLICY "Advocates can insert own logged services"
  ON logged_services
  FOR INSERT
  TO authenticated
  WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "Advocates can update own uninvoiced logged services"
  ON logged_services
  FOR UPDATE
  TO authenticated
  USING (advocate_id = auth.uid() AND invoice_id IS NULL)
  WITH CHECK (advocate_id = auth.uid() AND invoice_id IS NULL);

CREATE POLICY "Advocates can delete own uninvoiced logged services"
  ON logged_services
  FOR DELETE
  TO authenticated
  USING (advocate_id = auth.uid() AND invoice_id IS NULL);

-- ============================================================================
-- PART 4: Create helper functions for disbursements
-- ============================================================================

-- Function to get unbilled disbursements for a matter
CREATE OR REPLACE FUNCTION get_unbilled_disbursements(matter_id_param UUID)
RETURNS TABLE (
  id UUID,
  matter_id UUID,
  advocate_id UUID,
  description TEXT,
  amount DECIMAL,
  date_incurred DATE,
  vat_applicable BOOLEAN,
  vat_amount DECIMAL,
  total_amount DECIMAL,
  receipt_link TEXT,
  invoice_id UUID,
  is_billed BOOLEAN,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    d.id,
    d.matter_id,
    d.advocate_id,
    d.description,
    d.amount,
    d.date_incurred,
    d.vat_applicable,
    d.vat_amount,
    d.total_amount,
    d.receipt_link,
    d.invoice_id,
    d.is_billed,
    d.created_at,
    d.updated_at
  FROM disbursements d
  WHERE d.matter_id = matter_id_param
    AND d.is_billed = false
    AND d.deleted_at IS NULL
    AND d.advocate_id = auth.uid()
  ORDER BY d.date_incurred DESC, d.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to mark disbursements as billed
CREATE OR REPLACE FUNCTION mark_disbursements_as_billed(
  disbursement_ids UUID[],
  invoice_id_param UUID
)
RETURNS INTEGER AS $$
DECLARE
  updated_count INTEGER;
BEGIN
  UPDATE disbursements
  SET 
    is_billed = true,
    invoice_id = invoice_id_param,
    updated_at = NOW()
  WHERE id = ANY(disbursement_ids)
    AND advocate_id = auth.uid()
    AND is_billed = false
    AND deleted_at IS NULL;
  
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- PART 5: Create disbursement summary view
-- ============================================================================

DROP VIEW IF EXISTS disbursement_summary;

CREATE OR REPLACE VIEW disbursement_summary AS
SELECT 
  m.id as matter_id,
  m.title as matter_title,
  m.client_name,
  m.advocate_id,
  COUNT(d.id) as disbursement_count,
  COALESCE(SUM(d.amount), 0) as total_amount_excl_vat,
  COALESCE(SUM(d.vat_amount), 0) as total_vat_amount,
  COALESCE(SUM(d.total_amount), 0) as total_amount_incl_vat,
  COALESCE(SUM(CASE WHEN d.is_billed THEN d.total_amount ELSE 0 END), 0) as billed_amount,
  COALESCE(SUM(CASE WHEN NOT d.is_billed THEN d.total_amount ELSE 0 END), 0) as unbilled_amount,
  MIN(d.date_incurred) as earliest_disbursement,
  MAX(d.date_incurred) as latest_disbursement
FROM matters m
LEFT JOIN disbursements d ON d.matter_id = m.id AND d.deleted_at IS NULL
WHERE m.deleted_at IS NULL
GROUP BY m.id, m.title, m.client_name, m.advocate_id;

-- Add comments
COMMENT ON TABLE disbursements IS 'Stores disbursements (out-of-pocket expenses) for matters';
COMMENT ON COLUMN disbursements.vat_applicable IS 'Whether VAT should be applied to this disbursement';
COMMENT ON COLUMN disbursements.vat_amount IS 'Calculated VAT amount (15% if applicable)';
COMMENT ON COLUMN disbursements.total_amount IS 'Total amount including VAT if applicable';
COMMENT ON COLUMN disbursements.is_billed IS 'Whether this disbursement has been included in an invoice';
COMMENT ON COLUMN disbursements.deleted_at IS 'Soft delete timestamp';

