-- Fix matter search system after rollback
-- This restores essential functionality that was removed but is still needed by the application

-- Add the is_archived column and related fields
ALTER TABLE matters ADD COLUMN IF NOT EXISTS is_archived BOOLEAN DEFAULT false;
ALTER TABLE matters ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;
ALTER TABLE matters ADD COLUMN IF NOT EXISTS archived_by UUID REFERENCES user_profiles(user_id) ON DELETE SET NULL;

ALTER TABLE matters
ADD COLUMN IF NOT EXISTS court_case_number TEXT,
ADD COLUMN IF NOT EXISTS client_email TEXT,
ADD COLUMN IF NOT EXISTS client_phone TEXT,
ADD COLUMN IF NOT EXISTS client_address TEXT,
ADD COLUMN IF NOT EXISTS client_type TEXT,
ADD COLUMN IF NOT EXISTS instructing_attorney TEXT,
ADD COLUMN IF NOT EXISTS instructing_attorney_email TEXT,
ADD COLUMN IF NOT EXISTS instructing_attorney_phone TEXT,
ADD COLUMN IF NOT EXISTS instructing_firm TEXT,
ADD COLUMN IF NOT EXISTS instructing_firm_ref TEXT,
ADD COLUMN IF NOT EXISTS fee_type TEXT,
ADD COLUMN IF NOT EXISTS estimated_fee DECIMAL,
ADD COLUMN IF NOT EXISTS fee_cap DECIMAL,
ADD COLUMN IF NOT EXISTS risk_level TEXT,
ADD COLUMN IF NOT EXISTS settlement_probability INTEGER,
ADD COLUMN IF NOT EXISTS expected_completion_date DATE,
ADD COLUMN IF NOT EXISTS wip_value DECIMAL,
ADD COLUMN IF NOT EXISTS source_proforma_id UUID,
ADD COLUMN IF NOT EXISTS is_prepopulated BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS tags TEXT[];

-- Add indexes for performance
CREATE INDEX IF NOT EXISTS idx_matters_archived ON matters(is_archived);
CREATE INDEX IF NOT EXISTS idx_matters_archived_at ON matters(archived_at DESC);

-- Update existing matters to not be archived by default
UPDATE matters SET is_archived = false WHERE is_archived IS NULL;

-- Create comprehensive matter search function
DROP FUNCTION IF EXISTS search_matters(
  UUID,
  TEXT,
  BOOLEAN,
  TEXT,
  TEXT,
  TEXT[],
  DATE,
  DATE,
  TEXT,
  DECIMAL,
  DECIMAL,
  TEXT,
  TEXT,
  INTEGER,
  INTEGER
);

CREATE OR REPLACE FUNCTION search_matters(
  p_advocate_id UUID,
  p_search_query TEXT DEFAULT NULL,
  p_include_archived BOOLEAN DEFAULT FALSE,
  p_practice_area TEXT DEFAULT NULL,
  p_matter_type TEXT DEFAULT NULL,
  p_status TEXT[] DEFAULT NULL,
  p_date_from DATE DEFAULT NULL,
  p_date_to DATE DEFAULT NULL,
  p_attorney_firm TEXT DEFAULT NULL,
  p_fee_min DECIMAL DEFAULT NULL,
  p_fee_max DECIMAL DEFAULT NULL,
  p_sort_by TEXT DEFAULT 'created_at',
  p_sort_order TEXT DEFAULT 'desc',
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  id UUID,
  reference_number TEXT,
  title TEXT,
  description TEXT,
  matter_type TEXT,
  court_case_number TEXT,
  client_name TEXT,
  client_email TEXT,
  client_phone TEXT,
  client_address TEXT,
  client_type TEXT,
  instructing_attorney TEXT,
  instructing_attorney_email TEXT,
  instructing_attorney_phone TEXT,
  instructing_firm TEXT,
  instructing_firm_ref TEXT,
  fee_type TEXT,
  estimated_fee DECIMAL,
  fee_cap DECIMAL,
  risk_level TEXT,
  settlement_probability INTEGER,
  expected_completion_date DATE,
  status TEXT,
  wip_value DECIMAL,
  advocate_id UUID,
  source_proforma_id UUID,
  is_prepopulated BOOLEAN,
  tags TEXT[],
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  is_archived BOOLEAN,
  archived_at TIMESTAMPTZ,
  archived_by UUID
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    m.id,
    m.reference_number,
    m.title,
    m.description,
    m.matter_type,
    m.court_case_number,
    m.client_name,
    m.client_email,
    m.client_phone,
    m.client_address,
    m.client_type::TEXT,
    m.instructing_attorney,
    m.instructing_attorney_email,
    m.instructing_attorney_phone,
    m.instructing_firm,
    m.instructing_firm_ref,
    m.fee_type::TEXT,
    m.estimated_fee,
    m.fee_cap,
    m.risk_level::TEXT,
    m.settlement_probability,
    m.expected_completion_date,
    m.status::TEXT,
    m.wip_value,
    m.advocate_id,
    m.source_proforma_id,
    m.is_prepopulated,
    m.tags,
    m.created_at,
    m.updated_at,
    m.is_archived,
    m.archived_at,
    m.archived_by
  FROM matters m
  WHERE m.advocate_id = p_advocate_id
    AND (p_include_archived OR m.is_archived = false)
    AND (p_search_query IS NULL OR (
      m.title ILIKE '%' || p_search_query || '%' OR
      m.client_name ILIKE '%' || p_search_query || '%' OR
      m.instructing_attorney ILIKE '%' || p_search_query || '%' OR
      m.instructing_firm ILIKE '%' || p_search_query || '%' OR
      m.reference_number ILIKE '%' || p_search_query || '%'
    ))
    AND (p_practice_area IS NULL OR m.matter_type = p_practice_area)
    AND (p_matter_type IS NULL OR m.matter_type = p_matter_type)
    AND (p_status IS NULL OR m.status::TEXT = ANY(p_status))
    AND (p_date_from IS NULL OR m.created_at::DATE >= p_date_from)
    AND (p_date_to IS NULL OR m.created_at::DATE <= p_date_to)
    AND (p_attorney_firm IS NULL OR m.instructing_firm ILIKE '%' || p_attorney_firm || '%')
    AND (p_fee_min IS NULL OR m.estimated_fee >= p_fee_min)
    AND (p_fee_max IS NULL OR m.estimated_fee <= p_fee_max)
  ORDER BY 
    CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'asc' THEN m.created_at END ASC,
    CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'desc' THEN m.created_at END DESC,
    CASE WHEN p_sort_by = 'title' AND p_sort_order = 'asc' THEN m.title END ASC,
    CASE WHEN p_sort_by = 'title' AND p_sort_order = 'desc' THEN m.title END DESC,
    CASE WHEN p_sort_by = 'total_fee' AND p_sort_order = 'asc' THEN m.estimated_fee END ASC,
    CASE WHEN p_sort_by = 'total_fee' AND p_sort_order = 'desc' THEN m.estimated_fee END DESC,
    m.created_at DESC
  LIMIT p_limit
  OFFSET p_offset;
END;
$$;

-- Create function to count search results
CREATE OR REPLACE FUNCTION count_search_matters(
  p_advocate_id UUID,
  p_search_query TEXT DEFAULT NULL,
  p_include_archived BOOLEAN DEFAULT FALSE,
  p_practice_area TEXT DEFAULT NULL,
  p_matter_type TEXT DEFAULT NULL,
  p_status TEXT[] DEFAULT NULL,
  p_date_from DATE DEFAULT NULL,
  p_date_to DATE DEFAULT NULL,
  p_attorney_firm TEXT DEFAULT NULL,
  p_fee_min DECIMAL DEFAULT NULL,
  p_fee_max DECIMAL DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  result_count INTEGER;
BEGIN
  SELECT COUNT(*)
  INTO result_count
  FROM matters m
  WHERE m.advocate_id = p_advocate_id
    AND (p_include_archived OR m.is_archived = false)
    AND (p_search_query IS NULL OR (
      m.title ILIKE '%' || p_search_query || '%' OR
      m.client_name ILIKE '%' || p_search_query || '%' OR
      m.instructing_attorney ILIKE '%' || p_search_query || '%' OR
      m.instructing_firm ILIKE '%' || p_search_query || '%' OR
      m.reference_number ILIKE '%' || p_search_query || '%'
    ))
    AND (p_practice_area IS NULL OR m.matter_type = p_practice_area)
    AND (p_matter_type IS NULL OR m.matter_type = p_matter_type)
    AND (p_status IS NULL OR m.status::TEXT = ANY(p_status))
    AND (p_date_from IS NULL OR m.created_at::DATE >= p_date_from)
    AND (p_date_to IS NULL OR m.created_at::DATE <= p_date_to)
    AND (p_attorney_firm IS NULL OR m.instructing_firm ILIKE '%' || p_attorney_firm || '%')
    AND (p_fee_min IS NULL OR m.estimated_fee >= p_fee_min)
    AND (p_fee_max IS NULL OR m.estimated_fee <= p_fee_max);
    
  RETURN result_count;
END;
$$;

-- Create archive matter function
CREATE OR REPLACE FUNCTION archive_matter(
  p_matter_id UUID,
  p_advocate_id UUID,
  p_reason TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE matters
  SET 
    is_archived = true,
    archived_at = NOW(),
    archived_by = p_advocate_id,
    updated_at = NOW()
  WHERE id = p_matter_id
    AND advocate_id = p_advocate_id
    AND is_archived = false;
  
  RETURN FOUND;
END;
$$;

-- Create unarchive matter function
CREATE OR REPLACE FUNCTION unarchive_matter(
  p_matter_id UUID,
  p_advocate_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE matters
  SET 
    is_archived = false,
    archived_at = NULL,
    archived_by = NULL,
    updated_at = NOW()
  WHERE id = p_matter_id
    AND advocate_id = p_advocate_id
    AND is_archived = true;
  
  RETURN FOUND;
END;
$$;

-- Create function to get archived matters
DROP FUNCTION IF EXISTS get_archived_matters(UUID, INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION get_archived_matters(
  p_advocate_id UUID,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  id TEXT,
  reference_number TEXT,
  title TEXT,
  client_name TEXT,
  instructing_firm TEXT,
  matter_type TEXT,
  status TEXT,
  archived_at TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    m.id::TEXT,
    m.reference_number,
    m.title,
    m.client_name,
    m.instructing_firm,
    m.matter_type,
    m.status::TEXT,
    m.archived_at::TEXT
  FROM matters m
  WHERE m.advocate_id = p_advocate_id
    AND m.is_archived = true
  ORDER BY m.archived_at DESC
  LIMIT p_limit
  OFFSET p_offset;
END;
$$;

-- Add comments for documentation
COMMENT ON COLUMN matters.is_archived IS 'Whether the matter is archived (soft delete)';
COMMENT ON COLUMN matters.archived_at IS 'Timestamp when matter was archived';
COMMENT ON COLUMN matters.archived_by IS 'User who archived the matter';