-- ============================================
-- Migration: Add pro_forma status to invoice_status enum
-- PART 2: Update existing data
-- Version: 2.0.0
-- Date: 2025-01-13
-- IMPORTANT: Run this AFTER Part 1 is committed
-- ============================================

BEGIN;

-- Update existing pro forma invoices identified by internal_notes
DO $$
DECLARE
  rows_updated INTEGER;
BEGIN
  UPDATE invoices 
  SET 
    is_pro_forma = true,
    status = 'pro_forma'
  WHERE internal_notes ILIKE '%pro_forma%' 
    AND status = 'draft';
  
  GET DIAGNOSTICS rows_updated = ROW_COUNT;
  
  RAISE NOTICE '========================================';
  RAISE NOTICE '✓ Updated % existing pro forma invoices', rows_updated;
  RAISE NOTICE '========================================';
END $$;

-- Verify the update
DO $$
DECLARE
  pro_forma_count INTEGER;
  draft_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO pro_forma_count
  FROM invoices
  WHERE is_pro_forma = true;
  
  SELECT COUNT(*) INTO draft_count
  FROM invoices
  WHERE status = 'draft' AND is_pro_forma = false;
  
  RAISE NOTICE 'Pro forma invoices: %', pro_forma_count;
  RAISE NOTICE 'Draft invoices (non-pro forma): %', draft_count;
  
  RAISE NOTICE '========================================';
  RAISE NOTICE '✓ PART 2 COMPLETE: Data updated';
  RAISE NOTICE '========================================';
END $$;

COMMIT;
