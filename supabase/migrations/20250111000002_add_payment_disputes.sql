-- Payment Disputes Table
CREATE TABLE IF NOT EXISTS payment_disputes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
    
    dispute_reason TEXT NOT NULL,
    dispute_type TEXT NOT NULL CHECK (dispute_type IN ('amount_incorrect', 'work_not_done', 'quality_issue', 'billing_error', 'other')),
    
    disputed_amount DECIMAL(12,2),
    evidence_urls TEXT[],
    client_notes TEXT,
    
    resolution TEXT,
    resolution_type TEXT CHECK (resolution_type IN ('credit_note', 'write_off', 'payment_plan', 'settled', 'withdrawn')),
    resolved_amount DECIMAL(12,2),
    
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'investigating', 'resolved', 'escalated', 'closed')),
    
    opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,
    resolved_by UUID REFERENCES advocates(id),
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

ALTER TABLE payment_disputes
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_payment_disputes_invoice ON payment_disputes(invoice_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_payment_disputes_advocate ON payment_disputes(advocate_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_payment_disputes_status ON payment_disputes(status) WHERE deleted_at IS NULL;

COMMENT ON TABLE payment_disputes IS 'Track payment disputes and their resolutions';
COMMENT ON COLUMN payment_disputes.dispute_type IS 'Type: amount_incorrect, work_not_done, quality_issue, billing_error, other';
COMMENT ON COLUMN payment_disputes.resolution_type IS 'Resolution: credit_note, write_off, payment_plan, settled, withdrawn';

-- Credit Notes Table
CREATE TABLE IF NOT EXISTS credit_notes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    dispute_id UUID REFERENCES payment_disputes(id) ON DELETE SET NULL,
    advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
    
    credit_note_number TEXT NOT NULL UNIQUE,
    
    amount DECIMAL(12,2) NOT NULL CHECK (amount > 0),
    reason TEXT NOT NULL,
    reason_category TEXT CHECK (reason_category IN ('dispute_resolution', 'billing_error', 'goodwill', 'discount', 'other')),
    
    document_url TEXT,
    
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'issued', 'applied', 'cancelled')),
    
    issued_at TIMESTAMPTZ,
    applied_at TIMESTAMPTZ,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

ALTER TABLE credit_notes
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_credit_notes_invoice ON credit_notes(invoice_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_credit_notes_dispute ON credit_notes(dispute_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_credit_notes_advocate ON credit_notes(advocate_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_credit_notes_number ON credit_notes(credit_note_number) WHERE deleted_at IS NULL;

COMMENT ON TABLE credit_notes IS 'Credit notes issued for invoice adjustments';

-- Payments Table (detailed tracking)
CREATE TABLE IF NOT EXISTS payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
    
    amount DECIMAL(12,2) NOT NULL CHECK (amount > 0),
    payment_date DATE NOT NULL,
    payment_method TEXT NOT NULL,
    reference TEXT,
    
    is_partial BOOLEAN DEFAULT FALSE,
    
    notes TEXT,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

ALTER TABLE payments
    ADD COLUMN IF NOT EXISTS invoice_id UUID,
    ADD COLUMN IF NOT EXISTS advocate_id UUID,
    ADD COLUMN IF NOT EXISTS payment_date DATE,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_payments_invoice ON payments(invoice_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_payments_advocate ON payments(advocate_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_payments_date ON payments(payment_date) WHERE deleted_at IS NULL;

COMMENT ON TABLE payments IS 'Detailed payment tracking for invoices';

-- RLS Policies for all tables
ALTER TABLE payment_disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Advocates can view their own payment disputes" ON payment_disputes;
DROP POLICY IF EXISTS "Advocates can create payment disputes" ON payment_disputes;
DROP POLICY IF EXISTS "Advocates can update their own payment disputes" ON payment_disputes;
DROP POLICY IF EXISTS "Advocates can view their own credit notes" ON credit_notes;
DROP POLICY IF EXISTS "Advocates can create credit notes" ON credit_notes;
DROP POLICY IF EXISTS "Advocates can update their own credit notes" ON credit_notes;
DROP POLICY IF EXISTS "Advocates can view their own payments" ON payments;
DROP POLICY IF EXISTS "Advocates can create payments" ON payments;
DROP POLICY IF EXISTS "Advocates can update their own payments" ON payments;

CREATE POLICY "Advocates can view their own payment disputes"
    ON payment_disputes FOR SELECT
    USING (advocate_id = auth.uid());

CREATE POLICY "Advocates can create payment disputes"
    ON payment_disputes FOR INSERT
    WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "Advocates can update their own payment disputes"
    ON payment_disputes FOR UPDATE
    USING (advocate_id = auth.uid());

CREATE POLICY "Advocates can view their own credit notes"
    ON credit_notes FOR SELECT
    USING (advocate_id = auth.uid());

CREATE POLICY "Advocates can create credit notes"
    ON credit_notes FOR INSERT
    WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "Advocates can update their own credit notes"
    ON credit_notes FOR UPDATE
    USING (advocate_id = auth.uid());

CREATE POLICY "Advocates can view their own payments"
    ON payments FOR SELECT
    USING (advocate_id = auth.uid());

CREATE POLICY "Advocates can create payments"
    ON payments FOR INSERT
    WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "Advocates can update their own payments"
    ON payments FOR UPDATE
    USING (advocate_id = auth.uid());

-- Triggers
DROP TRIGGER IF EXISTS update_payment_disputes_updated_at ON payment_disputes;
CREATE TRIGGER update_payment_disputes_updated_at
    BEFORE UPDATE ON payment_disputes
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_credit_notes_updated_at ON credit_notes;
CREATE TRIGGER update_credit_notes_updated_at
    BEFORE UPDATE ON credit_notes
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_payments_updated_at ON payments;
CREATE TRIGGER update_payments_updated_at
    BEFORE UPDATE ON payments
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Function to generate credit note numbers
CREATE OR REPLACE FUNCTION generate_credit_note_number()
RETURNS TEXT AS $$
DECLARE
    year TEXT;
    month TEXT;
    sequence INTEGER;
    new_number TEXT;
BEGIN
    year := TO_CHAR(NOW(), 'YYYY');
    month := TO_CHAR(NOW(), 'MM');
    
    SELECT COALESCE(MAX(
        CAST(SUBSTRING(credit_note_number FROM 'CN-\d{6}-(\d{4})') AS INTEGER)
    ), 0) + 1
    INTO sequence
    FROM credit_notes
    WHERE credit_note_number LIKE 'CN-' || year || month || '-%';
    
    new_number := 'CN-' || year || month || '-' || LPAD(sequence::TEXT, 4, '0');
    
    RETURN new_number;
END;
$$ LANGUAGE plpgsql;

-- Trigger to auto-generate credit note numbers
CREATE OR REPLACE FUNCTION set_credit_note_number()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.credit_note_number IS NULL THEN
        NEW.credit_note_number := generate_credit_note_number();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_credit_note_number_trigger ON credit_notes;
CREATE TRIGGER set_credit_note_number_trigger
    BEFORE INSERT ON credit_notes
    FOR EACH ROW
    EXECUTE FUNCTION set_credit_note_number();
