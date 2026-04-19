-- ============================================================================
-- CONSOLIDATED SERVICES & RATE CARDS
-- Replaces: 20250107000004, 20250107000005, 20251007194200, 20251007200000
-- ============================================================================

-- ============================================================================
-- SERVICE CATEGORIES & SERVICES TABLES
-- ============================================================================

CREATE TABLE IF NOT EXISTS service_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id UUID NOT NULL REFERENCES service_categories(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS matter_services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  matter_id UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
  service_id UUID NOT NULL REFERENCES services(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(matter_id, service_id)
);

-- ============================================================================
-- RATE CARDS ENUMS & TABLES
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE rate_card_category AS ENUM (
    'consultation',
    'research',
    'drafting',
    'court_appearance',
    'negotiation',
    'document_review',
    'correspondence',
    'filing',
    'travel',
    'other'
  );
EXCEPTION
  WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE pricing_type AS ENUM (
    'hourly',
    'fixed',
    'per_item',
    'percentage'
  );
EXCEPTION
  WHEN duplicate_object THEN null;
END $$;

CREATE TABLE IF NOT EXISTS rate_cards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
  
  service_name TEXT NOT NULL,
  service_description TEXT,
  service_category rate_card_category NOT NULL,
  matter_type TEXT,
  
  pricing_type pricing_type NOT NULL DEFAULT 'hourly',
  hourly_rate DECIMAL(10,2),
  fixed_fee DECIMAL(10,2),
  minimum_fee DECIMAL(10,2),
  maximum_fee DECIMAL(10,2),
  
  estimated_hours_min DECIMAL(5,2),
  estimated_hours_max DECIMAL(5,2),
  
  is_default BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  requires_approval BOOLEAN DEFAULT false,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  CONSTRAINT valid_pricing CHECK (
    (pricing_type = 'hourly' AND hourly_rate IS NOT NULL) OR
    (pricing_type = 'fixed' AND fixed_fee IS NOT NULL) OR
    (pricing_type IN ('per_item', 'percentage'))
  )
);

ALTER TABLE rate_cards
ADD COLUMN IF NOT EXISTS service_name TEXT,
ADD COLUMN IF NOT EXISTS service_description TEXT,
ADD COLUMN IF NOT EXISTS service_category rate_card_category,
ADD COLUMN IF NOT EXISTS matter_type TEXT,
ADD COLUMN IF NOT EXISTS pricing_type pricing_type DEFAULT 'hourly',
ADD COLUMN IF NOT EXISTS hourly_rate DECIMAL(10,2),
ADD COLUMN IF NOT EXISTS fixed_fee DECIMAL(10,2),
ADD COLUMN IF NOT EXISTS minimum_fee DECIMAL(10,2),
ADD COLUMN IF NOT EXISTS maximum_fee DECIMAL(10,2),
ADD COLUMN IF NOT EXISTS estimated_hours_min DECIMAL(5,2),
ADD COLUMN IF NOT EXISTS estimated_hours_max DECIMAL(5,2),
ADD COLUMN IF NOT EXISTS is_default BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT true,
ADD COLUMN IF NOT EXISTS requires_approval BOOLEAN DEFAULT false;

UPDATE rate_cards
SET
  service_name = COALESCE(service_name, name),
  service_description = COALESCE(service_description, description)
WHERE service_name IS NULL
   OR service_description IS NULL;

CREATE TABLE IF NOT EXISTS standard_service_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  template_name TEXT NOT NULL,
  template_description TEXT,
  service_category rate_card_category NOT NULL,
  matter_types TEXT[],
  
  default_hourly_rate DECIMAL(10,2),
  default_fixed_fee DECIMAL(10,2),
  estimated_hours DECIMAL(5,2),
  
  is_system_template BOOLEAN DEFAULT true,
  bar_association bar_association,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- INDEXES
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_services_category ON services(category_id);
CREATE INDEX IF NOT EXISTS idx_matter_services_matter ON matter_services(matter_id);
CREATE INDEX IF NOT EXISTS idx_matter_services_service ON matter_services(service_id);
CREATE INDEX IF NOT EXISTS idx_rate_cards_advocate ON rate_cards(advocate_id);
CREATE INDEX IF NOT EXISTS idx_rate_cards_category ON rate_cards(service_category);
CREATE INDEX IF NOT EXISTS idx_rate_cards_active ON rate_cards(is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_rate_cards_default ON rate_cards(is_default) WHERE is_default = true;
CREATE INDEX IF NOT EXISTS idx_standard_templates_category ON standard_service_templates(service_category);
CREATE INDEX IF NOT EXISTS idx_standard_templates_bar ON standard_service_templates(bar_association);

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE service_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE services ENABLE ROW LEVEL SECURITY;
ALTER TABLE matter_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE standard_service_templates ENABLE ROW LEVEL SECURITY;

-- Drop existing policies
DROP POLICY IF EXISTS "Anyone can view service categories" ON service_categories;
DROP POLICY IF EXISTS "service_categories_select_policy" ON service_categories;
DROP POLICY IF EXISTS "Anyone can view services" ON services;
DROP POLICY IF EXISTS "services_select_policy" ON services;
DROP POLICY IF EXISTS "services_insert_policy" ON services;
DROP POLICY IF EXISTS "services_update_policy" ON services;
DROP POLICY IF EXISTS "services_delete_policy" ON services;
DROP POLICY IF EXISTS "Users can view matter services for their own matters" ON matter_services;
DROP POLICY IF EXISTS "Users can add services to their own matters" ON matter_services;
DROP POLICY IF EXISTS "Users can remove services from their own matters" ON matter_services;
DROP POLICY IF EXISTS "matter_services_select_policy" ON matter_services;
DROP POLICY IF EXISTS "matter_services_insert_policy" ON matter_services;
DROP POLICY IF EXISTS "matter_services_update_policy" ON matter_services;
DROP POLICY IF EXISTS "matter_services_delete_policy" ON matter_services;
DROP POLICY IF EXISTS "Users can view their own rate cards" ON rate_cards;
DROP POLICY IF EXISTS "Users can create their own rate cards" ON rate_cards;
DROP POLICY IF EXISTS "Users can update their own rate cards" ON rate_cards;
DROP POLICY IF EXISTS "Users can delete their own rate cards" ON rate_cards;
DROP POLICY IF EXISTS "rate_cards_select_policy" ON rate_cards;
DROP POLICY IF EXISTS "rate_cards_insert_policy" ON rate_cards;
DROP POLICY IF EXISTS "rate_cards_update_policy" ON rate_cards;
DROP POLICY IF EXISTS "rate_cards_delete_policy" ON rate_cards;
DROP POLICY IF EXISTS "Anyone can view standard service templates" ON standard_service_templates;
DROP POLICY IF EXISTS "standard_templates_select_policy" ON standard_service_templates;

-- Service Categories: Public read access
CREATE POLICY "service_categories_select_policy"
  ON service_categories FOR SELECT
  TO authenticated
  USING (true);

-- Services: Public read access, authenticated write
CREATE POLICY "services_select_policy"
  ON services FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "services_insert_policy"
  ON services FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "services_update_policy"
  ON services FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "services_delete_policy"
  ON services FOR DELETE
  TO authenticated
  USING (true);

-- Matter Services: Users can manage services for their own matters
CREATE POLICY "matter_services_select_policy"
  ON matter_services FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM matters 
      WHERE matters.id = matter_services.matter_id 
      AND matters.advocate_id = auth.uid()
    )
  );

CREATE POLICY "matter_services_insert_policy"
  ON matter_services FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM matters 
      WHERE matters.id = matter_services.matter_id 
      AND matters.advocate_id = auth.uid()
    )
  );

CREATE POLICY "matter_services_update_policy"
  ON matter_services FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM matters 
      WHERE matters.id = matter_services.matter_id 
      AND matters.advocate_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM matters 
      WHERE matters.id = matter_services.matter_id 
      AND matters.advocate_id = auth.uid()
    )
  );

CREATE POLICY "matter_services_delete_policy"
  ON matter_services FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM matters 
      WHERE matters.id = matter_services.matter_id 
      AND matters.advocate_id = auth.uid()
    )
  );

-- Rate Cards: Users can manage their own rate cards
CREATE POLICY "rate_cards_select_policy"
  ON rate_cards FOR SELECT
  TO authenticated
  USING (advocate_id = auth.uid());

CREATE POLICY "rate_cards_insert_policy"
  ON rate_cards FOR INSERT
  TO authenticated
  WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "rate_cards_update_policy"
  ON rate_cards FOR UPDATE
  TO authenticated
  USING (advocate_id = auth.uid())
  WITH CHECK (advocate_id = auth.uid());

CREATE POLICY "rate_cards_delete_policy"
  ON rate_cards FOR DELETE
  TO authenticated
  USING (advocate_id = auth.uid());

-- Standard Templates: Public read access
CREATE POLICY "standard_templates_select_policy"
  ON standard_service_templates FOR SELECT
  TO authenticated
  USING (true);

-- ============================================================================
-- GRANTS
-- ============================================================================

GRANT SELECT ON service_categories TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON services TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON matter_services TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON rate_cards TO authenticated;
GRANT SELECT ON standard_service_templates TO authenticated;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

CREATE OR REPLACE FUNCTION update_rate_card_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS rate_cards_updated_at ON rate_cards;
CREATE TRIGGER rate_cards_updated_at
  BEFORE UPDATE ON rate_cards
  FOR EACH ROW
  EXECUTE FUNCTION update_rate_card_timestamp();

DROP TRIGGER IF EXISTS standard_templates_updated_at ON standard_service_templates;
CREATE TRIGGER standard_templates_updated_at
  BEFORE UPDATE ON standard_service_templates
  FOR EACH ROW
  EXECUTE FUNCTION update_rate_card_timestamp();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE service_categories IS 'Categories for legal services offered by advocates';
COMMENT ON TABLE services IS 'Specific legal services that can be associated with matters';
COMMENT ON TABLE matter_services IS 'Junction table linking matters to their associated services';
COMMENT ON TABLE rate_cards IS 'Custom pricing cards for advocate services';
COMMENT ON TABLE standard_service_templates IS 'Standard service templates with default pricing';
