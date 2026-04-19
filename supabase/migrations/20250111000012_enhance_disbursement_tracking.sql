-- ============================================================================
-- Enhanced Disbursement/Expense Tracking
-- Addresses workflow disconnect: Handling disbursements within matter workflow
-- ============================================================================

-- Add disbursement-specific fields to expenses table
ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS disbursement_type TEXT CHECK (disbursement_type IN (
  'court_fees',
  'filing_fees',
  'expert_witness',
  'travel',
  'accommodation',
  'courier',
  'photocopying',
  'research',
  'translation',
  'other'
));

ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS payment_method TEXT CHECK (payment_method IN (
  'cash',
  'eft',
  'credit_card',
  'cheque',
  'petty_cash'
));

ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS payment_date DATE;

ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS receipt_number TEXT;

ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS vendor_name TEXT;

ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS is_reimbursable BOOLEAN DEFAULT true;

ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS reimbursed BOOLEAN DEFAULT false;

ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS reimbursement_date DATE;

ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS markup_percentage DECIMAL(5,2) DEFAULT 0;

ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS markup_amount DECIMAL(12,2) DEFAULT 0;

ALTER TABLE expenses 
ADD COLUMN IF NOT EXISTS client_charge_amount DECIMAL(12,2);

ALTER TABLE expenses
ADD COLUMN IF NOT EXISTS billable BOOLEAN DEFAULT true,
ADD COLUMN IF NOT EXISTS billed BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS date DATE,
ADD COLUMN IF NOT EXISTS category TEXT,
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Add indexes for new fields
CREATE INDEX IF NOT EXISTS idx_expenses_disbursement_type ON expenses(disbursement_type);
CREATE INDEX IF NOT EXISTS idx_expenses_payment_date ON expenses(payment_date);
CREATE INDEX IF NOT EXISTS idx_expenses_billed ON expenses(billed);
CREATE INDEX IF NOT EXISTS idx_expenses_reimbursed ON expenses(reimbursed);

-- Comments
COMMENT ON COLUMN expenses.disbursement_type IS 'Category of disbursement for better tracking';
COMMENT ON COLUMN expenses.payment_method IS 'How the expense was paid';
COMMENT ON COLUMN expenses.payment_date IS 'When the expense was paid';
COMMENT ON COLUMN expenses.receipt_number IS 'Receipt or invoice number from vendor';
COMMENT ON COLUMN expenses.vendor_name IS 'Name of vendor/service provider';
COMMENT ON COLUMN expenses.is_reimbursable IS 'Whether this expense should be reimbursed by client';
COMMENT ON COLUMN expenses.reimbursed IS 'Whether advocate has been reimbursed';
COMMENT ON COLUMN expenses.reimbursement_date IS 'Date advocate was reimbursed';
COMMENT ON COLUMN expenses.markup_percentage IS 'Percentage markup on expense (if applicable)';
COMMENT ON COLUMN expenses.markup_amount IS 'Calculated markup amount';
COMMENT ON COLUMN expenses.client_charge_amount IS 'Total amount to charge client (amount + markup)';

-- ============================================================================
-- Function to calculate client charge amount
-- ============================================================================

CREATE OR REPLACE FUNCTION calculate_expense_client_charge()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.markup_percentage IS NOT NULL AND NEW.markup_percentage > 0 THEN
    NEW.markup_amount := NEW.amount * (NEW.markup_percentage / 100);
  ELSE
    NEW.markup_amount := 0;
  END IF;
  
  NEW.client_charge_amount := NEW.amount + COALESCE(NEW.markup_amount, 0);
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS calculate_expense_client_charge_trigger ON expenses;
CREATE TRIGGER calculate_expense_client_charge_trigger
  BEFORE INSERT OR UPDATE ON expenses
  FOR EACH ROW
  EXECUTE FUNCTION calculate_expense_client_charge();

-- ============================================================================
-- Disbursement Summary View
-- ============================================================================

CREATE OR REPLACE VIEW disbursement_summary AS
SELECT 
  m.id as matter_id,
  m.title as matter_title,
  m.client_name,
  COUNT(e.id) as total_disbursements,
  SUM(e.amount) as total_amount,
  SUM(e.client_charge_amount) as total_client_charge,
  SUM(CASE WHEN e.billed = false THEN e.amount ELSE 0 END) as unbilled_amount,
  SUM(CASE WHEN e.billed = true THEN e.amount ELSE 0 END) as billed_amount,
  SUM(CASE WHEN e.reimbursed = false AND e.is_reimbursable = true THEN e.amount ELSE 0 END) as unreimbursed_amount,
  COUNT(CASE WHEN e.billed = false THEN 1 END) as unbilled_count,
  COUNT(CASE WHEN e.reimbursed = false AND e.is_reimbursable = true THEN 1 END) as unreimbursed_count
FROM matters m
LEFT JOIN expenses e ON e.matter_id = m.id AND e.deleted_at IS NULL
WHERE m.deleted_at IS NULL
GROUP BY m.id, m.title, m.client_name;

COMMENT ON VIEW disbursement_summary IS 'Summary of disbursements per matter';

-- ============================================================================
-- Disbursement by Type View
-- ============================================================================

CREATE OR REPLACE VIEW disbursement_by_type AS
SELECT 
  m.id as matter_id,
  m.title as matter_title,
  e.disbursement_type,
  COUNT(e.id) as count,
  SUM(e.amount) as total_amount,
  SUM(e.client_charge_amount) as total_client_charge,
  SUM(CASE WHEN e.billed = false THEN e.amount ELSE 0 END) as unbilled_amount
FROM matters m
INNER JOIN expenses e ON e.matter_id = m.id AND e.deleted_at IS NULL
WHERE m.deleted_at IS NULL
GROUP BY m.id, m.title, e.disbursement_type;

COMMENT ON VIEW disbursement_by_type IS 'Disbursements grouped by type per matter';

-- ============================================================================
-- Quick Disbursement Entry Function
-- ============================================================================

CREATE OR REPLACE FUNCTION quick_add_disbursement(
  p_matter_id UUID,
  p_description TEXT,
  p_amount DECIMAL,
  p_disbursement_type TEXT,
  p_payment_date DATE DEFAULT CURRENT_DATE,
  p_receipt_number TEXT DEFAULT NULL,
  p_vendor_name TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_expense_id UUID;
  v_advocate_id UUID;
BEGIN
  v_advocate_id := auth.uid();
  
  IF v_advocate_id IS NULL THEN
    RAISE EXCEPTION 'User not authenticated';
  END IF;
  
  -- Verify matter belongs to user
  IF NOT EXISTS (
    SELECT 1 FROM matters 
    WHERE id = p_matter_id AND advocate_id = v_advocate_id
  ) THEN
    RAISE EXCEPTION 'Matter not found or access denied';
  END IF;
  
  INSERT INTO expenses (
    matter_id,
    advocate_id,
    description,
    amount,
    disbursement_type,
    payment_date,
    receipt_number,
    vendor_name,
    date,
    category,
    billable,
    billed
  ) VALUES (
    p_matter_id,
    v_advocate_id,
    p_description,
    p_amount,
    p_disbursement_type,
    p_payment_date,
    p_receipt_number,
    p_vendor_name,
    p_payment_date,
    p_disbursement_type,
    true,
    false
  )
  RETURNING id INTO v_expense_id;
  
  RETURN v_expense_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION quick_add_disbursement TO authenticated;

COMMENT ON FUNCTION quick_add_disbursement IS 'Quick function to add a disbursement to a matter';

-- ============================================================================
-- Disbursement Approval Workflow (Optional)
-- ============================================================================

CREATE TABLE IF NOT EXISTS disbursement_approvals (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  expense_id UUID NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
  matter_id UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
  advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
  
  requested_amount DECIMAL(12,2) NOT NULL,
  approved_amount DECIMAL(12,2),
  
  status TEXT CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')) DEFAULT 'pending',
  
  requested_by UUID REFERENCES advocates(id),
  approved_by UUID REFERENCES advocates(id),
  
  request_notes TEXT,
  approval_notes TEXT,
  
  requested_at TIMESTAMPTZ DEFAULT NOW(),
  approved_at TIMESTAMPTZ,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_disbursement_approvals_expense ON disbursement_approvals(expense_id);
CREATE INDEX IF NOT EXISTS idx_disbursement_approvals_matter ON disbursement_approvals(matter_id);
CREATE INDEX IF NOT EXISTS idx_disbursement_approvals_status ON disbursement_approvals(status);

ALTER TABLE disbursement_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own disbursement approvals" ON disbursement_approvals;
DROP POLICY IF EXISTS "Users can create disbursement approvals" ON disbursement_approvals;
DROP POLICY IF EXISTS "Users can update their own disbursement approvals" ON disbursement_approvals;

CREATE POLICY "Users can view their own disbursement approvals"
  ON disbursement_approvals FOR SELECT
  USING (advocate_id = auth.uid() OR requested_by = auth.uid() OR approved_by = auth.uid());

CREATE POLICY "Users can create disbursement approvals"
  ON disbursement_approvals FOR INSERT
  WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "Users can update their own disbursement approvals"
  ON disbursement_approvals FOR UPDATE
  USING (advocate_id = auth.uid() OR approved_by = auth.uid());

DROP TRIGGER IF EXISTS update_disbursement_approvals_updated_at ON disbursement_approvals;
CREATE TRIGGER update_disbursement_approvals_updated_at
  BEFORE UPDATE ON disbursement_approvals
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

COMMENT ON TABLE disbursement_approvals IS 'Optional approval workflow for large disbursements';

-- ============================================================================
-- Update matter WIP to include disbursements properly
-- ============================================================================

CREATE OR REPLACE FUNCTION update_matter_wip()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE matters
  SET wip_value = (
    SELECT COALESCE(SUM(amount), 0)
    FROM time_entries
    WHERE matter_id = COALESCE(NEW.matter_id, OLD.matter_id)
      AND is_billed = false
  ) + (
    SELECT COALESCE(SUM(client_charge_amount), 0)
    FROM expenses
    WHERE matter_id = COALESCE(NEW.matter_id, OLD.matter_id)
      AND billed = false
      AND deleted_at IS NULL
  )
  WHERE id = COALESCE(NEW.matter_id, OLD.matter_id);
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Recreate triggers
DROP TRIGGER IF EXISTS update_matter_wip_on_time_entry ON time_entries;
DROP TRIGGER IF EXISTS update_matter_wip_on_expense ON expenses;

CREATE TRIGGER update_matter_wip_on_time_entry
  AFTER INSERT OR UPDATE OR DELETE ON time_entries
  FOR EACH ROW
  EXECUTE FUNCTION update_matter_wip();

CREATE TRIGGER update_matter_wip_on_expense
  AFTER INSERT OR UPDATE OR DELETE ON expenses
  FOR EACH ROW
  EXECUTE FUNCTION update_matter_wip();
