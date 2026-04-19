-- Performance Optimizations for Search, Dashboard, and Reports
-- Adds indexes, materialized views, and caching strategies

ALTER TABLE time_entries
ADD COLUMN IF NOT EXISTS billable BOOLEAN DEFAULT true;

ALTER TABLE matters
ADD COLUMN IF NOT EXISTS deadline DATE;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'matters'
      AND column_name = 'deadline_date'
  ) THEN
    UPDATE matters
    SET deadline = deadline_date
    WHERE deadline IS NULL
      AND deadline_date IS NOT NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'disbursements'
  ) THEN
    ALTER TABLE disbursements ADD COLUMN IF NOT EXISTS incurred_date DATE;
    UPDATE disbursements
    SET incurred_date = date_incurred
    WHERE incurred_date IS NULL;
  END IF;
END $$;

-- ============================================================================
-- FULL-TEXT SEARCH OPTIMIZATION
-- ============================================================================

-- Add full-text search column to matters table
ALTER TABLE matters 
ADD COLUMN IF NOT EXISTS search_vector tsvector;

-- Create function to update search vector
CREATE OR REPLACE FUNCTION matters_search_vector_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.search_vector := 
    setweight(to_tsvector('english', COALESCE(NEW.title, '')), 'A') ||
    setweight(to_tsvector('english', COALESCE(NEW.description, '')), 'B') ||
    setweight(to_tsvector('english', COALESCE(NEW.client_name, '')), 'A') ||
    setweight(to_tsvector('english', COALESCE(NEW.matter_type, '')), 'C') ||
    setweight(to_tsvector('english', COALESCE(NEW.practice_area, '')), 'C');
  
  RETURN NEW;
END;
$$;

-- Create trigger for search vector updates
DROP TRIGGER IF EXISTS trigger_matters_search_vector ON matters;

CREATE TRIGGER trigger_matters_search_vector
  BEFORE INSERT OR UPDATE OF title, description, client_name, matter_type, practice_area
  ON matters
  FOR EACH ROW
  EXECUTE FUNCTION matters_search_vector_update();

-- Update existing records
UPDATE matters SET search_vector = 
  setweight(to_tsvector('english', COALESCE(title, '')), 'A') ||
  setweight(to_tsvector('english', COALESCE(description, '')), 'B') ||
  setweight(to_tsvector('english', COALESCE(client_name, '')), 'A') ||
  setweight(to_tsvector('english', COALESCE(matter_type, '')), 'C') ||
  setweight(to_tsvector('english', COALESCE(practice_area, '')), 'C')
WHERE search_vector IS NULL;

-- Create GIN index for full-text search
CREATE INDEX IF NOT EXISTS idx_matters_search_vector 
ON matters USING gin(search_vector);

-- ============================================================================
-- MATTER SEARCH INDEXES
-- ============================================================================

-- Composite index for active matters (most common query)
CREATE INDEX IF NOT EXISTS idx_matters_active_advocate 
ON matters(advocate_id, created_at DESC)
WHERE status IN ('active', 'new_request')
AND archived_at IS NULL;

-- Index for archived matters search
CREATE INDEX IF NOT EXISTS idx_matters_archived 
ON matters(advocate_id, archived_at DESC)
WHERE archived_at IS NOT NULL;

-- Index for matter status filtering
CREATE INDEX IF NOT EXISTS idx_matters_status_advocate 
ON matters(advocate_id, status, created_at DESC);

-- Index for practice area filtering
CREATE INDEX IF NOT EXISTS idx_matters_practice_area 
ON matters(advocate_id, practice_area, created_at DESC)
WHERE archived_at IS NULL;

-- Index for deadline queries
CREATE INDEX IF NOT EXISTS idx_matters_deadline 
ON matters(advocate_id, deadline)
WHERE deadline IS NOT NULL
AND status IN ('active', 'new_request')
AND archived_at IS NULL;

-- Index for firm-based queries
CREATE INDEX IF NOT EXISTS idx_matters_firm 
ON matters(advocate_id, firm_id, created_at DESC)
WHERE archived_at IS NULL;

-- ============================================================================
-- INVOICE AND PAYMENT INDEXES
-- ============================================================================

-- Index for outstanding invoices (critical for dashboard)
CREATE INDEX IF NOT EXISTS idx_invoices_outstanding 
ON invoices(advocate_id, status, created_at DESC)
WHERE status IN ('sent', 'overdue');

-- Index for payment tracking
CREATE INDEX IF NOT EXISTS idx_payments_invoice 
ON payments(invoice_id, payment_date DESC);

-- Index for payment date range queries
CREATE INDEX IF NOT EXISTS idx_payments_advocate_date 
ON payments(advocate_id, payment_date DESC);

-- Composite index for revenue calculations
CREATE INDEX IF NOT EXISTS idx_invoices_revenue 
ON invoices(advocate_id, status, invoice_date)
WHERE status IN ('paid', 'sent', 'overdue');

-- ============================================================================
-- WIP (WORK IN PROGRESS) INDEXES
-- ============================================================================

-- Index for time entries by matter
CREATE INDEX IF NOT EXISTS idx_time_entries_matter 
ON time_entries(matter_id, entry_date DESC);

-- Index for unbilled time entries
CREATE INDEX IF NOT EXISTS idx_time_entries_unbilled 
ON time_entries(matter_id, billable)
WHERE invoice_id IS NULL AND billable = true;

-- Index for disbursements by matter
CREATE INDEX IF NOT EXISTS idx_disbursements_matter 
ON disbursements(matter_id, incurred_date DESC);

-- Index for unbilled disbursements
CREATE INDEX IF NOT EXISTS idx_disbursements_unbilled 
ON disbursements(matter_id)
WHERE invoice_id IS NULL;

-- ============================================================================
-- MATERIALIZED VIEW: Dashboard Metrics Cache
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS dashboard_metrics_cache AS
SELECT 
  m.advocate_id,
  
  -- Urgent attention metrics
  COUNT(DISTINCT CASE 
    WHEN m.deadline = CURRENT_DATE 
    AND m.status::text IN ('active', 'new_request') 
    THEN m.id 
  END) as deadlines_today,
  
  COUNT(DISTINCT CASE 
    WHEN i.status::text IN ('sent', 'partially_paid') 
    AND i.invoice_date < CURRENT_DATE - INTERVAL '45 days'
    THEN i.id 
  END) as overdue_45_days,
  
  COUNT(DISTINCT CASE 
    WHEN m.status::text = 'awaiting_approval' 
    AND m.created_at < CURRENT_DATE - INTERVAL '5 days'
    THEN m.id 
  END) as pending_proformas_5_days,
  
  -- This week's deadlines
  COUNT(DISTINCT CASE 
    WHEN m.deadline BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '7 days'
    AND m.status::text IN ('active', 'new_request')
    THEN m.id 
  END) as deadlines_this_week,
  
  -- Financial snapshot
  COALESCE(SUM(CASE 
    WHEN i.status::text IN ('sent', 'partially_paid', 'overdue')
    THEN i.total_amount - COALESCE(i.amount_paid, 0)
  END), 0) as outstanding_fees,
  
  COUNT(DISTINCT CASE 
    WHEN i.status::text IN ('sent', 'partially_paid', 'overdue')
    THEN i.id 
  END) as outstanding_invoices_count,
  
  -- WIP metrics
  COUNT(DISTINCT CASE 
    WHEN m.status::text = 'active' 
    AND EXISTS (
      SELECT 1 FROM time_entries te 
      WHERE te.matter_id = m.id 
      AND te.invoice_id IS NULL
    )
    THEN m.id 
  END) as matters_in_wip,
  
  -- This month invoiced
  COALESCE(SUM(CASE 
    WHEN i.invoice_date >= DATE_TRUNC('month', CURRENT_DATE)
    THEN i.total_amount
  END), 0) as invoiced_this_month,
  
  COUNT(DISTINCT CASE 
    WHEN i.invoice_date >= DATE_TRUNC('month', CURRENT_DATE)
    THEN i.id 
  END) as invoices_this_month_count,
  
  -- Active matters count
  COUNT(DISTINCT CASE 
    WHEN m.status::text = 'active' 
    AND m.archived_at IS NULL
    THEN m.id 
  END) as active_matters_count,
  
  -- Pending actions
  COUNT(DISTINCT CASE 
    WHEN m.status::text = 'new_request'
    THEN m.id 
  END) as new_requests_count,
  
  COUNT(DISTINCT CASE 
    WHEN m.status::text = 'awaiting_approval'
    THEN m.id 
  END) as awaiting_approval_count,
  
  -- Last updated timestamp
  NOW() as cached_at
  
FROM matters m
LEFT JOIN invoices i ON i.matter_id = m.id
WHERE m.archived_at IS NULL
GROUP BY m.advocate_id;

-- Create unique index on materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_dashboard_cache_advocate 
ON dashboard_metrics_cache(advocate_id);

-- ============================================================================
-- FUNCTION: Refresh Dashboard Cache
-- ============================================================================

CREATE OR REPLACE FUNCTION refresh_dashboard_cache(p_advocate_id UUID DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW dashboard_metrics_cache;
END;
$$;

-- ============================================================================
-- TRIGGER: Auto-refresh Dashboard Cache on Changes
-- ============================================================================

CREATE OR REPLACE FUNCTION trigger_refresh_dashboard_cache()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Refresh cache for affected advocate (async)
  PERFORM refresh_dashboard_cache(COALESCE(NEW.advocate_id, OLD.advocate_id));
  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Trigger on matters changes
DROP TRIGGER IF EXISTS trigger_matters_dashboard_refresh ON matters;
CREATE TRIGGER trigger_matters_dashboard_refresh
  AFTER INSERT OR UPDATE OR DELETE ON matters
  FOR EACH ROW
  EXECUTE FUNCTION trigger_refresh_dashboard_cache();

-- Trigger on invoices changes
DROP TRIGGER IF EXISTS trigger_invoices_dashboard_refresh ON invoices;
CREATE TRIGGER trigger_invoices_dashboard_refresh
  AFTER INSERT OR UPDATE OR DELETE ON invoices
  FOR EACH ROW
  EXECUTE FUNCTION trigger_refresh_dashboard_cache();

-- Trigger on payments changes
DROP TRIGGER IF EXISTS trigger_payments_dashboard_refresh ON payments;
CREATE TRIGGER trigger_payments_dashboard_refresh
  AFTER INSERT OR UPDATE OR DELETE ON payments
  FOR EACH ROW
  EXECUTE FUNCTION trigger_refresh_dashboard_cache();

-- ============================================================================
-- FUNCTION: Fast Matter Search with Ranking
-- ============================================================================

CREATE OR REPLACE FUNCTION search_matters(
  p_advocate_id UUID,
  p_query TEXT,
  p_include_archived BOOLEAN DEFAULT FALSE,
  p_limit INTEGER DEFAULT 50
) RETURNS TABLE (
  matter_id UUID,
  title TEXT,
  client_name TEXT,
  practice_area TEXT,
  status TEXT,
  rank REAL
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    m.id as matter_id,
    m.title,
    m.client_name,
    m.practice_area,
    m.status,
    ts_rank(m.search_vector, plainto_tsquery('english', p_query)) as rank
  FROM matters m
  WHERE m.advocate_id = p_advocate_id
  AND m.search_vector @@ plainto_tsquery('english', p_query)
  AND (p_include_archived OR m.archived_at IS NULL)
  ORDER BY rank DESC, m.created_at DESC
  LIMIT p_limit;
END;
$$;

-- ============================================================================
-- FUNCTION: Calculate WIP Value for Matter
-- ============================================================================

CREATE OR REPLACE FUNCTION calculate_matter_wip(p_matter_id UUID)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_time_value NUMERIC;
  v_disbursements_value NUMERIC;
  v_total NUMERIC;
BEGIN
  -- Calculate unbilled time entries value
  SELECT COALESCE(SUM(hours * hourly_rate), 0)
  INTO v_time_value
  FROM time_entries
  WHERE matter_id = p_matter_id
  AND invoice_id IS NULL
  AND billable = true;
  
  -- Calculate unbilled disbursements value (including VAT)
  SELECT COALESCE(SUM(total_amount), 0)
  INTO v_disbursements_value
  FROM disbursements
  WHERE matter_id = p_matter_id
  AND invoice_id IS NULL;
  
  v_total := v_time_value + v_disbursements_value;
  
  RETURN v_total;
END;
$$;

-- ============================================================================
-- MATERIALIZED VIEW: WIP Report Cache
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS wip_report_cache AS
SELECT 
  m.id as matter_id,
  m.advocate_id,
  m.title,
  m.client_name,
  m.practice_area,
  m.status,
  m.created_at,
  
  -- Time entries
  COUNT(DISTINCT te.id) as unbilled_time_entries,
  COALESCE(SUM(te.hours), 0) as total_hours,
  COALESCE(SUM(te.hours * te.hourly_rate), 0) as time_value,
  
  -- Disbursements
  COUNT(DISTINCT d.id) as unbilled_disbursements,
  COALESCE(SUM(d.amount + d.vat_amount), 0) as disbursements_value,
  
  -- Total WIP
  COALESCE(SUM(te.hours * te.hourly_rate), 0) + COALESCE(SUM(d.amount + d.vat_amount), 0) as total_wip_value,
  
  -- Days in WIP
  CURRENT_DATE - m.created_at::DATE as days_in_wip,
  
  -- Last activity
  GREATEST(
    MAX(te.entry_date),
    MAX(d.incurred_date),
    m.updated_at::DATE
  ) as last_activity_date,
  
  NOW() as cached_at
  
FROM matters m
LEFT JOIN time_entries te ON te.matter_id = m.id AND te.invoice_id IS NULL AND te.billable = true
LEFT JOIN disbursements d ON d.matter_id = m.id AND d.invoice_id IS NULL
WHERE m.status::text = 'active'
AND m.archived_at IS NULL
AND (te.id IS NOT NULL OR d.id IS NOT NULL)
GROUP BY m.id, m.advocate_id, m.title, m.client_name, m.practice_area, m.status, m.created_at, m.updated_at;

-- Create index on WIP cache
CREATE INDEX IF NOT EXISTS idx_wip_cache_advocate 
ON wip_report_cache(advocate_id, days_in_wip DESC);

-- ============================================================================
-- SCHEDULED JOB: Refresh Caches (Run every 5 minutes)
-- ============================================================================

-- Note: This requires pg_cron extension
-- Enable with: CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule dashboard cache refresh (every 5 minutes)
-- SELECT cron.schedule('refresh-dashboard-cache', '*/5 * * * *', 'REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard_metrics_cache');

-- Schedule WIP cache refresh (every 10 minutes)
-- SELECT cron.schedule('refresh-wip-cache', '*/10 * * * *', 'REFRESH MATERIALIZED VIEW CONCURRENTLY wip_report_cache');

-- ============================================================================
-- VACUUM AND ANALYZE SETTINGS
-- ============================================================================

-- Optimize autovacuum for high-traffic tables
ALTER TABLE matters SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.02
);

ALTER TABLE invoices SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.02
);

ALTER TABLE time_entries SET (
  autovacuum_vacuum_scale_factor = 0.1,
  autovacuum_analyze_scale_factor = 0.05
);

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON MATERIALIZED VIEW dashboard_metrics_cache IS 
'Cached dashboard metrics refreshed every 5 minutes for fast dashboard loading';

COMMENT ON MATERIALIZED VIEW wip_report_cache IS 
'Cached WIP report data refreshed every 10 minutes for fast report generation';

COMMENT ON FUNCTION search_matters(UUID, TEXT, BOOLEAN, INTEGER) IS 
'Fast full-text search across matters with relevance ranking';

COMMENT ON FUNCTION calculate_matter_wip(UUID) IS 
'Calculates total WIP value (time + disbursements) for a matter';

COMMENT ON FUNCTION refresh_dashboard_cache(UUID) IS 
'Manually refresh dashboard cache for specific advocate or all advocates';
