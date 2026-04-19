-- =====================================================
-- Phase 2: Trust Account System Enhancement
-- Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8
-- =====================================================

-- 7.1: Trust Accounts Table (Requirement 4.1)
-- One trust account per advocate with bank details and balance
CREATE TABLE IF NOT EXISTS trust_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    advocate_id UUID NOT NULL UNIQUE REFERENCES advocates(id) ON DELETE CASCADE,
    
    -- Bank details
    bank_name TEXT NOT NULL,
    account_holder_name TEXT NOT NULL,
    account_number TEXT NOT NULL,
    branch_code TEXT,
    account_type TEXT DEFAULT 'trust' CHECK (account_type IN ('trust', 'business')),
    
    -- Balance tracking
    current_balance DECIMAL(12,2) NOT NULL DEFAULT 0 CHECK (current_balance >= 0),
    
    -- Compliance and settings
    lpc_compliant BOOLEAN DEFAULT TRUE,
    reconciliation_day_of_month INTEGER DEFAULT 1 CHECK (reconciliation_day_of_month BETWEEN 1 AND 31),
    low_balance_threshold DECIMAL(12,2) DEFAULT 5000.00,
    negative_balance_alert_sent BOOLEAN DEFAULT FALSE,
    
    -- Audit trail
    last_reconciliation_date DATE,
    last_reconciliation_balance DECIMAL(12,2),
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_trust_accounts_advocate ON trust_accounts(advocate_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_trust_accounts_balance ON trust_accounts(current_balance) WHERE deleted_at IS NULL;

COMMENT ON TABLE trust_accounts IS 'Trust account details for each advocate (LPC compliance)';
COMMENT ON COLUMN trust_accounts.current_balance IS 'Current balance - must never be negative per LPC rules';
COMMENT ON COLUMN trust_accounts.lpc_compliant IS 'Indicates if account meets Legal Practice Council requirements';

ALTER TABLE advocates
ADD COLUMN IF NOT EXISTS full_name TEXT;

-- 7.3: Trust Transfers Table (Requirement 4.5)
-- For transfers between trust and business accounts
CREATE TABLE IF NOT EXISTS trust_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trust_account_id UUID NOT NULL REFERENCES trust_accounts(id) ON DELETE CASCADE,
    advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
    matter_id UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    
    -- Transfer details
    transfer_type TEXT NOT NULL CHECK (transfer_type IN ('trust_to_business', 'business_to_trust')),
    amount DECIMAL(12,2) NOT NULL CHECK (amount > 0),
    
    -- Balances before/after for audit
    trust_balance_before DECIMAL(12,2) NOT NULL,
    trust_balance_after DECIMAL(12,2) NOT NULL,
    business_balance_before DECIMAL(12,2),
    business_balance_after DECIMAL(12,2),
    
    -- Justification and compliance
    reason TEXT NOT NULL,
    authorization_type TEXT NOT NULL CHECK (authorization_type IN ('invoice_payment', 'fee_earned', 'cost_reimbursement', 'refund', 'correction')),
    
    -- Linked records
    invoice_id UUID REFERENCES invoices(id) ON DELETE SET NULL,
    trust_transaction_id UUID REFERENCES trust_transactions(id) ON DELETE SET NULL,
    
    -- Audit and compliance
    approved_by UUID REFERENCES advocates(id) ON DELETE SET NULL,
    approved_at TIMESTAMPTZ,
    transfer_date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_trust_transfers_trust_account ON trust_transfers(trust_account_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_trust_transfers_advocate ON trust_transfers(advocate_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_trust_transfers_matter ON trust_transfers(matter_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_trust_transfers_date ON trust_transfers(transfer_date) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_trust_transfers_type ON trust_transfers(transfer_type) WHERE deleted_at IS NULL;

COMMENT ON TABLE trust_transfers IS 'Audit trail for transfers between trust and business accounts';
COMMENT ON COLUMN trust_transfers.authorization_type IS 'Legal basis for the transfer';

-- 7.4: Extend trust_transactions for better tracking (Requirement 4.2, 4.5)
-- Add receipt number and payment method fields
ALTER TABLE trust_transactions
ADD COLUMN IF NOT EXISTS receipt_number TEXT,
ADD COLUMN IF NOT EXISTS payment_method TEXT CHECK (payment_method IN ('eft', 'cash', 'cheque', 'card', 'debit_order')),
ADD COLUMN IF NOT EXISTS trust_account_id UUID REFERENCES trust_accounts(id) ON DELETE CASCADE,
ADD COLUMN IF NOT EXISTS is_reconciled BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS reconciliation_date DATE;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
            AND table_name = 'clients'
    ) THEN
        EXECUTE 'ALTER TABLE trust_transactions ADD COLUMN IF NOT EXISTS client_id UUID REFERENCES clients(id) ON DELETE SET NULL';
    ELSE
        EXECUTE 'ALTER TABLE trust_transactions ADD COLUMN IF NOT EXISTS client_id UUID';
    END IF;
END $$;

-- Create index for receipt lookup
CREATE INDEX IF NOT EXISTS idx_trust_transactions_receipt ON trust_transactions(receipt_number) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_trust_transactions_client ON trust_transactions(client_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_trust_transactions_reconciled ON trust_transactions(is_reconciled, reconciliation_date) WHERE deleted_at IS NULL;

COMMENT ON COLUMN trust_transactions.receipt_number IS 'Unique receipt number for LPC compliance (Req 4.4)';
COMMENT ON COLUMN trust_transactions.is_reconciled IS 'Marked true after bank reconciliation';

-- =====================================================
-- Functions and Triggers
-- =====================================================

-- Function: Auto-generate trust account for new advocates
CREATE OR REPLACE FUNCTION create_default_trust_account()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO trust_accounts (
        advocate_id,
        bank_name,
        account_holder_name,
        account_number,
        account_type,
        current_balance
    ) VALUES (
        NEW.id,
        'To be configured',
        COALESCE(NEW.full_name, 'Advocate') || ' Trust Account',
        'PENDING',
        'trust',
        0.00
    )
    ON CONFLICT (advocate_id) DO NOTHING;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS create_trust_account_on_advocate_signup ON advocates;
CREATE TRIGGER create_trust_account_on_advocate_signup
    AFTER INSERT ON advocates
    FOR EACH ROW
    EXECUTE FUNCTION create_default_trust_account();

-- Function: Generate unique receipt number (Requirement 4.4)
CREATE OR REPLACE FUNCTION generate_trust_receipt_number()
RETURNS TRIGGER AS $$
DECLARE
    current_year INTEGER;
    sequence_num INTEGER;
    receipt_num TEXT;
BEGIN
    IF NEW.transaction_type = 'deposit' THEN
        current_year := EXTRACT(YEAR FROM CURRENT_DATE);
        
        -- Get the next sequence number for this advocate this year
        SELECT COALESCE(MAX(
            CAST(
                SUBSTRING(receipt_number FROM 'TR-' || current_year::TEXT || '-([0-9]+)') 
                AS INTEGER
            )
        ), 0) + 1
        INTO sequence_num
        FROM trust_transactions
        WHERE advocate_id = NEW.advocate_id
        AND receipt_number LIKE 'TR-' || current_year::TEXT || '-%';
        
        -- Format: TR-YYYY-NNNN
        receipt_num := 'TR-' || current_year::TEXT || '-' || LPAD(sequence_num::TEXT, 4, '0');
        NEW.receipt_number := receipt_num;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS generate_receipt_number_trigger ON trust_transactions;
CREATE TRIGGER generate_receipt_number_trigger
    BEFORE INSERT ON trust_transactions
    FOR EACH ROW
    WHEN (NEW.transaction_type = 'deposit')
    EXECUTE FUNCTION generate_trust_receipt_number();

-- Function: Update trust account balance on transaction (Requirement 4.2, 4.7)
CREATE OR REPLACE FUNCTION update_trust_account_balance()
RETURNS TRIGGER AS $$
DECLARE
    account_balance DECIMAL(12,2);
BEGIN
    -- Only process if trust_account_id is set
    IF NEW.trust_account_id IS NULL THEN
        RETURN NEW;
    END IF;
    
    -- Get current balance
    SELECT current_balance INTO account_balance
    FROM trust_accounts
    WHERE id = NEW.trust_account_id;
    
    -- Update based on transaction type
    IF NEW.transaction_type = 'deposit' THEN
        UPDATE trust_accounts
        SET current_balance = current_balance + NEW.amount,
            updated_at = NOW()
        WHERE id = NEW.trust_account_id;
        
    ELSIF NEW.transaction_type IN ('drawdown', 'refund', 'transfer') THEN
        -- Check for negative balance (LPC violation)
        IF (account_balance - NEW.amount) < 0 THEN
            RAISE EXCEPTION 'Trust account balance cannot be negative (LPC Requirement 4.7). Current: %, Requested: %', 
                account_balance, NEW.amount;
        END IF;
        
        UPDATE trust_accounts
        SET current_balance = current_balance - NEW.amount,
            updated_at = NOW()
        WHERE id = NEW.trust_account_id;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_trust_account_balance_trigger ON trust_transactions;
CREATE TRIGGER update_trust_account_balance_trigger
    AFTER INSERT ON trust_transactions
    FOR EACH ROW
    WHEN (NEW.trust_account_id IS NOT NULL)
    EXECUTE FUNCTION update_trust_account_balance();

-- Function: Check for negative balance and alert (Requirement 4.7)
CREATE OR REPLACE FUNCTION check_trust_account_negative_balance()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_balance < 0 AND NOT NEW.negative_balance_alert_sent THEN
        NEW.negative_balance_alert_sent := TRUE;
        
        -- Log critical compliance violation
        IF to_regclass('public.system_notifications') IS NOT NULL THEN
            EXECUTE '
                INSERT INTO system_notifications (
                    user_id,
                    notification_type,
                    title,
                    message,
                    severity,
                    is_read
                ) VALUES ($1, $2, $3, $4, $5, $6)
            '
            USING
                NEW.advocate_id,
                'trust_account_violation',
                'CRITICAL: Trust Account Negative Balance',
                'Your trust account has a negative balance of R' || ABS(NEW.current_balance)::TEXT || '. This violates LPC rules. Immediate action required.',
                'critical',
                FALSE;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS check_negative_balance_trigger ON trust_accounts;
CREATE TRIGGER check_negative_balance_trigger
    BEFORE UPDATE OF current_balance ON trust_accounts
    FOR EACH ROW
    WHEN (NEW.current_balance < OLD.current_balance)
    EXECUTE FUNCTION check_trust_account_negative_balance();

-- Function: Record trust transfer with full audit (Requirement 4.5)
CREATE OR REPLACE FUNCTION record_trust_transfer()
RETURNS TRIGGER AS $$
BEGIN
    -- Create corresponding trust transaction
    INSERT INTO trust_transactions (
        trust_account_id,
        retainer_id,
        matter_id,
        advocate_id,
        transaction_type,
        amount,
        balance_before,
        balance_after,
        description,
        transaction_date
    ) VALUES (
        NEW.trust_account_id,
        (SELECT id FROM retainer_agreements WHERE matter_id = NEW.matter_id LIMIT 1),
        NEW.matter_id,
        NEW.advocate_id,
        'transfer',
        NEW.amount,
        NEW.trust_balance_before,
        NEW.trust_balance_after,
        'Transfer to business account: ' || NEW.reason,
        NEW.transfer_date
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS record_trust_transfer_trigger ON trust_transfers;
CREATE TRIGGER record_trust_transfer_trigger
    AFTER INSERT ON trust_transfers
    FOR EACH ROW
    WHEN (NEW.transfer_type = 'trust_to_business')
    EXECUTE FUNCTION record_trust_transfer();

-- =====================================================
-- Row-Level Security (RLS)
-- =====================================================

ALTER TABLE trust_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE trust_transfers ENABLE ROW LEVEL SECURITY;

-- Trust Accounts RLS
DROP POLICY IF EXISTS "Advocates can view their own trust account" ON trust_accounts;
CREATE POLICY "Advocates can view their own trust account"
    ON trust_accounts FOR SELECT
    USING (advocate_id = auth.uid());

DROP POLICY IF EXISTS "Advocates can update their own trust account" ON trust_accounts;
CREATE POLICY "Advocates can update their own trust account"
    ON trust_accounts FOR UPDATE
    USING (advocate_id = auth.uid());

DROP POLICY IF EXISTS "System can create trust accounts" ON trust_accounts;
CREATE POLICY "System can create trust accounts"
    ON trust_accounts FOR INSERT
    WITH CHECK (true); -- Trigger handles this

-- Trust Transfers RLS
DROP POLICY IF EXISTS "Advocates can view their own trust transfers" ON trust_transfers;
CREATE POLICY "Advocates can view their own trust transfers"
    ON trust_transfers FOR SELECT
    USING (advocate_id = auth.uid());

DROP POLICY IF EXISTS "Advocates can create trust transfers" ON trust_transfers;
CREATE POLICY "Advocates can create trust transfers"
    ON trust_transfers FOR INSERT
    WITH CHECK (advocate_id = auth.uid());

-- Update RLS for trust_transactions to include trust_account_id
DROP POLICY IF EXISTS "Advocates can view their own trust transactions" ON trust_transactions;
CREATE POLICY "Advocates can view their own trust transactions"
    ON trust_transactions FOR SELECT
    USING (
        advocate_id = auth.uid() OR
        trust_account_id IN (SELECT id FROM trust_accounts WHERE advocate_id = auth.uid())
    );

-- =====================================================
-- Triggers for updated_at
-- =====================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_trust_accounts_updated_at ON trust_accounts;
CREATE TRIGGER update_trust_accounts_updated_at
    BEFORE UPDATE ON trust_accounts
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_trust_transfers_updated_at ON trust_transfers;
CREATE TRIGGER update_trust_transfers_updated_at
    BEFORE UPDATE ON trust_transfers
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- =====================================================
-- Default data and setup
-- =====================================================

-- Create trust accounts for existing advocates
INSERT INTO trust_accounts (
    advocate_id,
    bank_name,
    account_holder_name,
    account_number,
    account_type,
    current_balance
)
SELECT 
    id,
    'To be configured',
    COALESCE(full_name, 'Advocate') || ' Trust Account',
    'PENDING',
    'trust',
    0.00
FROM advocates
WHERE id NOT IN (SELECT advocate_id FROM trust_accounts)
ON CONFLICT (advocate_id) DO NOTHING;

-- Backfill trust_account_id for existing trust_transactions
UPDATE trust_transactions tt
SET trust_account_id = ta.id
FROM trust_accounts ta
WHERE tt.advocate_id = ta.advocate_id
AND tt.trust_account_id IS NULL;
