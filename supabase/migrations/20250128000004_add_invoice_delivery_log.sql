-- Migration: Invoice Delivery Logging
-- Requirements: 8.5, 8.6
-- Purpose: Track invoice delivery methods and status

-- 1. Create invoice_delivery_log table
CREATE TABLE IF NOT EXISTS invoice_delivery_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  delivered_to TEXT NOT NULL, -- Email address or user_id
  delivery_method TEXT NOT NULL, -- 'email', 'portal', 'download'
  delivered_at TIMESTAMPTZ DEFAULT NOW(),
  delivery_status TEXT NOT NULL, -- 'sent', 'failed', 'opened', 'downloaded'
  error_message TEXT,
  metadata JSONB, -- Additional delivery details
  
  CONSTRAINT valid_delivery_method CHECK (delivery_method IN ('email', 'portal', 'download', 'manual'))
);

ALTER TABLE attorneys
ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;

-- 2. Create indexes
CREATE INDEX IF NOT EXISTS idx_invoice_delivery_invoice ON invoice_delivery_log(invoice_id);
CREATE INDEX IF NOT EXISTS idx_invoice_delivery_delivered_to ON invoice_delivery_log(delivered_to);
CREATE INDEX IF NOT EXISTS idx_invoice_delivery_method ON invoice_delivery_log(delivery_method);
CREATE INDEX IF NOT EXISTS idx_invoice_delivery_status ON invoice_delivery_log(delivery_status);
CREATE INDEX IF NOT EXISTS idx_invoice_delivery_date ON invoice_delivery_log(delivered_at DESC);

-- 3. Create view for latest delivery status per invoice
CREATE OR REPLACE VIEW invoice_latest_delivery AS
SELECT DISTINCT ON (invoice_id)
  invoice_id,
  delivered_to,
  delivery_method,
  delivered_at,
  delivery_status,
  error_message
FROM invoice_delivery_log
ORDER BY invoice_id, delivered_at DESC;

-- 4. Create RLS policies
ALTER TABLE invoice_delivery_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS invoice_delivery_advocate_read ON invoice_delivery_log;
DROP POLICY IF EXISTS invoice_delivery_advocate_create ON invoice_delivery_log;
DROP POLICY IF EXISTS invoice_delivery_attorney_read ON invoice_delivery_log;

-- Advocates can see delivery logs for their own invoices
CREATE POLICY invoice_delivery_advocate_read ON invoice_delivery_log
  FOR SELECT
  USING (
    invoice_id IN (
      SELECT i.id 
      FROM invoices i 
      WHERE i.advocate_id = auth.uid()
    )
  );

-- Advocates can create delivery logs for their own invoices
CREATE POLICY invoice_delivery_advocate_create ON invoice_delivery_log
  FOR INSERT
  WITH CHECK (
    invoice_id IN (
      SELECT i.id 
      FROM invoices i 
      WHERE i.advocate_id = auth.uid()
    )
  );

-- Attorneys can see delivery logs for invoices they received
CREATE POLICY invoice_delivery_attorney_read ON invoice_delivery_log
  FOR SELECT
  USING (
    delivered_to IN (
      SELECT email 
      FROM attorneys 
      WHERE user_id = auth.uid()
    )
  );

-- 5. Grant permissions
GRANT SELECT ON invoice_latest_delivery TO authenticated;

COMMENT ON TABLE invoice_delivery_log IS 'Tracks invoice delivery via email, portal, or download';
COMMENT ON VIEW invoice_latest_delivery IS 'Shows the most recent delivery attempt for each invoice';
