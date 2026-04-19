-- Ensure dependencies exist for legacy references
CREATE TABLE IF NOT EXISTS rate_cards (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    advocate_id UUID REFERENCES advocates(id) ON DELETE CASCADE,
    name TEXT,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

ALTER TABLE proforma_requests ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE matters ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE invoices ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Extend proforma_requests table
ALTER TABLE proforma_requests 
ADD COLUMN IF NOT EXISTS client_response_status TEXT DEFAULT 'pending' CHECK (client_response_status IN ('pending', 'accepted', 'negotiating', 'rejected')),
ADD COLUMN IF NOT EXISTS negotiation_history JSONB DEFAULT '[]'::jsonb,
ADD COLUMN IF NOT EXISTS rejection_reason TEXT,
ADD COLUMN IF NOT EXISTS rejection_date TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS rate_card_id UUID REFERENCES rate_cards(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS estimated_total DECIMAL(12,2);

CREATE INDEX IF NOT EXISTS idx_proforma_requests_response_status ON proforma_requests(client_response_status) WHERE deleted_at IS NULL;

COMMENT ON COLUMN proforma_requests.client_response_status IS 'Client response: pending, accepted, negotiating, rejected';
COMMENT ON COLUMN proforma_requests.negotiation_history IS 'JSON array of negotiation rounds with dates and notes';

-- Extend matters table
ALTER TABLE matters
ADD COLUMN IF NOT EXISTS is_urgent BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS urgency_reason TEXT,
ADD COLUMN IF NOT EXISTS pro_forma_waived BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS estimated_total DECIMAL(12,2),
ADD COLUMN IF NOT EXISTS actual_total DECIMAL(12,2),
ADD COLUMN IF NOT EXISTS completion_status TEXT DEFAULT 'in_progress' CHECK (completion_status IN ('in_progress', 'review', 'ready_to_bill', 'billed', 'completed')),
ADD COLUMN IF NOT EXISTS billing_review_notes TEXT,
ADD COLUMN IF NOT EXISTS billing_ready_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS partner_approved_by UUID REFERENCES advocates(id),
ADD COLUMN IF NOT EXISTS partner_approved_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS partner_approval_notes TEXT,
ADD COLUMN IF NOT EXISTS engagement_agreement_id UUID REFERENCES engagement_agreements(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_matters_urgent ON matters(is_urgent) WHERE deleted_at IS NULL AND is_urgent = TRUE;
CREATE INDEX IF NOT EXISTS idx_matters_completion_status ON matters(completion_status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_matters_billing_ready ON matters(billing_ready_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_matters_engagement ON matters(engagement_agreement_id) WHERE deleted_at IS NULL;

COMMENT ON COLUMN matters.is_urgent IS 'Urgent matter that bypassed pro forma process';
COMMENT ON COLUMN matters.completion_status IS 'Matter status: in_progress, review, ready_to_bill, billed, completed';
COMMENT ON COLUMN matters.estimated_total IS 'Original estimate from pro forma or initial assessment';
COMMENT ON COLUMN matters.actual_total IS 'Actual costs accumulated (computed from time entries + expenses)';

-- Extend invoices table
ALTER TABLE invoices
ADD COLUMN IF NOT EXISTS invoice_type TEXT DEFAULT 'final' CHECK (invoice_type IN ('interim', 'milestone', 'final', 'pro_forma')),
ADD COLUMN IF NOT EXISTS billing_period_start DATE,
ADD COLUMN IF NOT EXISTS billing_period_end DATE,
ADD COLUMN IF NOT EXISTS milestone_description TEXT,
ADD COLUMN IF NOT EXISTS payment_status TEXT DEFAULT 'pending' CHECK (payment_status IN ('pending', 'partial', 'paid', 'disputed', 'written_off', 'cancelled')),
ADD COLUMN IF NOT EXISTS amount_paid DECIMAL(12,2) DEFAULT 0,
ADD COLUMN IF NOT EXISTS balance_due DECIMAL(12,2) GENERATED ALWAYS AS (total_amount - COALESCE(amount_paid, 0)) STORED,
ADD COLUMN IF NOT EXISTS written_off_amount DECIMAL(12,2),
ADD COLUMN IF NOT EXISTS written_off_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS written_off_by UUID REFERENCES advocates(id),
ADD COLUMN IF NOT EXISTS written_off_reason TEXT,
ADD COLUMN IF NOT EXISTS partner_approved_by UUID REFERENCES advocates(id),
ADD COLUMN IF NOT EXISTS partner_approved_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_invoices_type ON invoices(invoice_type) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_invoices_payment_status ON invoices(payment_status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_invoices_billing_period ON invoices(billing_period_start, billing_period_end) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_invoices_balance_due ON invoices(balance_due) WHERE deleted_at IS NULL AND balance_due > 0;

COMMENT ON COLUMN invoices.invoice_type IS 'Type: interim (monthly), milestone (event-based), final (completion), pro_forma';
COMMENT ON COLUMN invoices.payment_status IS 'Status: pending, partial, paid, disputed, written_off, cancelled';
COMMENT ON COLUMN invoices.balance_due IS 'Computed: total_amount - amount_paid';

-- Function to compute actual_total for matters
CREATE OR REPLACE FUNCTION compute_matter_actual_total(matter_uuid UUID)
RETURNS DECIMAL(12,2) AS $$
DECLARE
    time_total DECIMAL(12,2);
    expense_total DECIMAL(12,2);
    total DECIMAL(12,2);
BEGIN
    SELECT COALESCE(SUM(hours * hourly_rate), 0)
    INTO time_total
    FROM time_entries
    WHERE matter_id = matter_uuid AND deleted_at IS NULL;
    
    SELECT COALESCE(SUM(amount), 0)
    INTO expense_total
    FROM expenses
    WHERE matter_id = matter_uuid AND deleted_at IS NULL;
    
    total := time_total + expense_total;
    
    RETURN total;
END;
$$ LANGUAGE plpgsql;

-- Trigger to update actual_total when time entries or expenses change
CREATE OR REPLACE FUNCTION update_matter_actual_total()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE matters
        SET actual_total = compute_matter_actual_total(OLD.matter_id),
            updated_at = NOW()
        WHERE id = OLD.matter_id;
        RETURN OLD;
    ELSE
        UPDATE matters
        SET actual_total = compute_matter_actual_total(NEW.matter_id),
            updated_at = NOW()
        WHERE id = NEW.matter_id;
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_matter_actual_total_on_time_entry ON time_entries;
CREATE TRIGGER update_matter_actual_total_on_time_entry
    AFTER INSERT OR UPDATE OR DELETE ON time_entries
    FOR EACH ROW
    EXECUTE FUNCTION update_matter_actual_total();

DROP TRIGGER IF EXISTS update_matter_actual_total_on_expense ON expenses;
CREATE TRIGGER update_matter_actual_total_on_expense
    AFTER INSERT OR UPDATE OR DELETE ON expenses
    FOR EACH ROW
    EXECUTE FUNCTION update_matter_actual_total();

-- Function to check cost variance and create alert
CREATE OR REPLACE FUNCTION check_cost_variance()
RETURNS TRIGGER AS $$
DECLARE
    variance_percentage DECIMAL(5,2);
    threshold DECIMAL(5,2) := 15.0; -- 15% variance threshold
BEGIN
    IF NEW.estimated_total IS NOT NULL AND NEW.estimated_total > 0 THEN
        variance_percentage := ((NEW.actual_total - NEW.estimated_total) / NEW.estimated_total) * 100;
        
        IF variance_percentage > threshold THEN
            INSERT INTO scope_amendments (
                matter_id,
                advocate_id,
                amendment_type,
                reason,
                original_estimate,
                new_estimate,
                status
            ) VALUES (
                NEW.id,
                NEW.advocate_id,
                'scope_increase',
                'Actual costs exceeded estimate by ' || ROUND(variance_percentage, 2) || '%',
                NEW.estimated_total,
                NEW.actual_total,
                'pending'
            )
            ON CONFLICT DO NOTHING;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS check_matter_cost_variance ON matters;
CREATE TRIGGER check_matter_cost_variance
    AFTER UPDATE OF actual_total ON matters
    FOR EACH ROW
    WHEN (NEW.actual_total IS DISTINCT FROM OLD.actual_total)
    EXECUTE FUNCTION check_cost_variance();
