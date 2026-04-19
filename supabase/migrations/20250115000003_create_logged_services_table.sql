-- Create logged_services table for universal logging system
-- This table stores all service-based work (fixed-price items) for both Pro Forma estimates and WIP actuals

CREATE TABLE IF NOT EXISTS logged_services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  matter_id UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
  advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
  service_date DATE NOT NULL,
  description TEXT NOT NULL CHECK (length(description) >= 5),
  service_type TEXT NOT NULL CHECK (service_type IN ('consultation', 'drafting', 'research', 'court_appearance', 'negotiation', 'review', 'other')),
  estimated_hours NUMERIC(10,2),
  rate_card_id UUID REFERENCES rate_cards(id) ON DELETE SET NULL,
  unit_rate NUMERIC(10,2) NOT NULL CHECK (unit_rate > 0),
  quantity NUMERIC(10,2) DEFAULT 1 CHECK (quantity > 0),
  amount NUMERIC(15,2) NOT NULL CHECK (amount >= 0),
  is_estimate BOOLEAN DEFAULT false,
  pro_forma_id UUID REFERENCES proforma_requests(id) ON DELETE SET NULL,
  invoice_id UUID REFERENCES invoices(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_logged_services_matter ON logged_services(matter_id);
CREATE INDEX IF NOT EXISTS idx_logged_services_advocate ON logged_services(advocate_id);
CREATE INDEX IF NOT EXISTS idx_logged_services_pro_forma ON logged_services(pro_forma_id);
CREATE INDEX IF NOT EXISTS idx_logged_services_invoice ON logged_services(invoice_id);
CREATE INDEX IF NOT EXISTS idx_logged_services_date ON logged_services(service_date);
CREATE INDEX IF NOT EXISTS idx_logged_services_is_estimate ON logged_services(is_estimate);
CREATE INDEX IF NOT EXISTS idx_logged_services_service_type ON logged_services(service_type);

-- Add updated_at trigger
CREATE OR REPLACE FUNCTION update_logged_services_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS logged_services_updated_at ON logged_services;
CREATE TRIGGER logged_services_updated_at
  BEFORE UPDATE ON logged_services
  FOR EACH ROW
  EXECUTE FUNCTION update_logged_services_updated_at();

-- Add trigger to calculate amount automatically
CREATE OR REPLACE FUNCTION calculate_logged_service_amount()
RETURNS TRIGGER AS $$
BEGIN
  NEW.amount = NEW.unit_rate * NEW.quantity;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS logged_services_calculate_amount ON logged_services;
CREATE TRIGGER logged_services_calculate_amount
  BEFORE INSERT OR UPDATE ON logged_services
  FOR EACH ROW
  EXECUTE FUNCTION calculate_logged_service_amount();

-- Enable Row Level Security
ALTER TABLE logged_services ENABLE ROW LEVEL SECURITY;

-- RLS Policies for logged_services
-- Advocates can view their own logged services
DROP POLICY IF EXISTS "Advocates can view own logged services" ON logged_services;
DROP POLICY IF EXISTS "Advocates can insert own logged services" ON logged_services;
DROP POLICY IF EXISTS "Advocates can update own uninvoiced logged services" ON logged_services;
DROP POLICY IF EXISTS "Advocates can delete own uninvoiced logged services" ON logged_services;

CREATE POLICY "Advocates can view own logged services"
  ON logged_services
  FOR SELECT
  TO authenticated
  USING (advocate_id = auth.uid());

-- Advocates can insert their own logged services
CREATE POLICY "Advocates can insert own logged services"
  ON logged_services
  FOR INSERT
  TO authenticated
  WITH CHECK (advocate_id = auth.uid());

-- Advocates can update their own logged services (if not invoiced)
CREATE POLICY "Advocates can update own uninvoiced logged services"
  ON logged_services
  FOR UPDATE
  TO authenticated
  USING (advocate_id = auth.uid() AND invoice_id IS NULL)
  WITH CHECK (advocate_id = auth.uid() AND invoice_id IS NULL);

-- Advocates can delete their own logged services (if not invoiced)
CREATE POLICY "Advocates can delete own uninvoiced logged services"
  ON logged_services
  FOR DELETE
  TO authenticated
  USING (advocate_id = auth.uid() AND invoice_id IS NULL);

-- Add comments for documentation
COMMENT ON TABLE logged_services IS 'Stores service-based work items for both Pro Forma estimates (is_estimate=true) and WIP actuals (is_estimate=false)';
COMMENT ON COLUMN logged_services.service_date IS 'Date the service was performed or estimated';
COMMENT ON COLUMN logged_services.service_type IS 'Type of legal service performed';
COMMENT ON COLUMN logged_services.estimated_hours IS 'Estimated hours for the service (optional)';
COMMENT ON COLUMN logged_services.unit_rate IS 'Rate per unit of service';
COMMENT ON COLUMN logged_services.quantity IS 'Number of units (default 1)';
COMMENT ON COLUMN logged_services.amount IS 'Calculated amount (unit_rate × quantity)';
COMMENT ON COLUMN logged_services.is_estimate IS 'true for Pro Forma estimates, false for WIP actuals';
COMMENT ON COLUMN logged_services.pro_forma_id IS 'Link to Pro Forma if this is an estimate';
COMMENT ON COLUMN logged_services.invoice_id IS 'Link to invoice if this has been billed';
