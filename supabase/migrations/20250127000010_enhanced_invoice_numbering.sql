-- Enhanced Invoice Numbering System with Concurrency Handling
-- Ensures SARS compliance and prevents race conditions

CREATE TABLE IF NOT EXISTS invoice_settings (
  advocate_id UUID PRIMARY KEY REFERENCES advocates(id) ON DELETE CASCADE,
  invoice_number_format TEXT NOT NULL DEFAULT 'INV-YYYY-NNN',
  credit_note_format TEXT NOT NULL DEFAULT 'CN-YYYY-NNN',
  current_sequence INTEGER NOT NULL DEFAULT 0 CHECK (current_sequence >= 0),
  credit_note_sequence INTEGER NOT NULL DEFAULT 0 CHECK (credit_note_sequence >= 0),
  last_sequence_year INTEGER NOT NULL DEFAULT CAST(EXTRACT(YEAR FROM CURRENT_DATE) AS INTEGER),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS invoice_numbering_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  advocate_id UUID NOT NULL REFERENCES advocates(id) ON DELETE CASCADE,
  number_issued TEXT NOT NULL,
  number_type TEXT NOT NULL DEFAULT 'invoice' CHECK (number_type IN ('invoice', 'credit_note')),
  issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sequence_number INTEGER,
  year INTEGER,
  voided_at TIMESTAMPTZ,
  void_reason TEXT,
  related_credit_note TEXT
);

-- Ensure one settings row per advocate
INSERT INTO invoice_settings (advocate_id)
SELECT id FROM advocates
ON CONFLICT (advocate_id) DO NOTHING;

-- ============================================================================
-- FUNCTION: Get Next Invoice Number (Atomic & Concurrent-Safe)
-- ============================================================================

CREATE OR REPLACE FUNCTION get_next_invoice_number(
  p_advocate_id UUID,
  p_invoice_type TEXT DEFAULT 'invoice'
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_sequence INTEGER;
  v_year INTEGER;
  v_format TEXT;
  v_number TEXT;
  v_max_retries INTEGER := 5;
  v_retry_count INTEGER := 0;
  v_credit_note_format TEXT;
BEGIN
  -- Get current year
  v_year := EXTRACT(YEAR FROM CURRENT_DATE);

  -- Ensure settings row exists for this advocate
  INSERT INTO invoice_settings (advocate_id)
  VALUES (p_advocate_id)
  ON CONFLICT (advocate_id) DO NOTHING;
  
  -- Get format from settings
  SELECT 
    invoice_number_format,
    credit_note_format
  INTO v_format, v_credit_note_format
  FROM invoice_settings
  WHERE advocate_id = p_advocate_id;
  
  -- If no settings found, use defaults
  IF v_format IS NULL THEN
    v_format := 'INV-YYYY-NNN';
    v_credit_note_format := 'CN-YYYY-NNN';
  END IF;
  
  -- Use appropriate format based on type
  IF p_invoice_type = 'credit_note' THEN
    v_format := v_credit_note_format;
  END IF;
  
  -- Retry loop for concurrency handling
  LOOP
    BEGIN
      -- Get and increment sequence atomically with row-level lock
      UPDATE invoice_settings
      SET 
        current_sequence = CASE 
          WHEN p_invoice_type = 'credit_note' THEN credit_note_sequence + 1
          ELSE current_sequence + 1
        END,
        credit_note_sequence = CASE
          WHEN p_invoice_type = 'credit_note' THEN credit_note_sequence + 1
          ELSE credit_note_sequence
        END,
        last_sequence_year = v_year,
        updated_at = NOW()
      WHERE advocate_id = p_advocate_id
      RETURNING 
        CASE 
          WHEN p_invoice_type = 'credit_note' THEN credit_note_sequence
          ELSE current_sequence
        END
      INTO v_sequence;
      
      -- Check if year changed and reset sequence if needed
      IF v_year > (SELECT last_sequence_year FROM invoice_settings WHERE advocate_id = p_advocate_id) THEN
        UPDATE invoice_settings
        SET 
          current_sequence = 1,
          credit_note_sequence = 1,
          last_sequence_year = v_year
        WHERE advocate_id = p_advocate_id
        RETURNING 1 INTO v_sequence;
      END IF;
      
      -- Format the number
      v_number := format_invoice_number(v_format, v_year, v_sequence);
      
      -- Verify uniqueness (double-check)
      IF NOT EXISTS (
        SELECT 1 FROM invoices 
        WHERE advocate_id = p_advocate_id 
        AND invoice_number = v_number
      ) AND NOT EXISTS (
        SELECT 1 FROM credit_notes
        WHERE advocate_id = p_advocate_id
        AND credit_note_number = v_number
      ) THEN
        -- Log to audit trail
        INSERT INTO invoice_numbering_audit (
          advocate_id,
          number_issued,
          number_type,
          issued_at,
          sequence_number,
          year
        ) VALUES (
          p_advocate_id,
          v_number,
          p_invoice_type,
          NOW(),
          v_sequence,
          v_year
        );
        
        RETURN v_number;
      END IF;
      
      -- If we get here, number already exists (rare race condition)
      -- Increment and try again
      v_retry_count := v_retry_count + 1;
      
      IF v_retry_count >= v_max_retries THEN
        RAISE EXCEPTION 'Failed to generate unique invoice number after % retries. Please contact support.', v_max_retries;
      END IF;
      
      -- Small delay before retry (exponential backoff)
      PERFORM pg_sleep(0.1 * v_retry_count);
      
    EXCEPTION 
      WHEN serialization_failure OR deadlock_detected THEN
        v_retry_count := v_retry_count + 1;
        IF v_retry_count >= v_max_retries THEN
          RAISE EXCEPTION 'Database concurrency error after % retries. Please try again.', v_max_retries;
        END IF;
        PERFORM pg_sleep(0.1 * v_retry_count);
    END;
  END LOOP;
END;
$$;

-- ============================================================================
-- FUNCTION: Format Invoice Number
-- ============================================================================

CREATE OR REPLACE FUNCTION format_invoice_number(
  p_format TEXT,
  p_year INTEGER,
  p_sequence INTEGER
) RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_result TEXT;
  v_year_short TEXT;
  v_sequence_padded TEXT;
BEGIN
  -- Pad sequence to 3 digits
  v_sequence_padded := LPAD(p_sequence::TEXT, 3, '0');
  
  -- Get short year (last 2 digits)
  v_year_short := RIGHT(p_year::TEXT, 2);
  
  -- Replace placeholders
  v_result := p_format;
  v_result := REPLACE(v_result, 'YYYY', p_year::TEXT);
  v_result := REPLACE(v_result, 'YY', v_year_short);
  v_result := REPLACE(v_result, 'NNN', v_sequence_padded);
  
  RETURN v_result;
END;
$$;

-- ============================================================================
-- FUNCTION: Validate Invoice Number Sequence
-- ============================================================================

CREATE OR REPLACE FUNCTION validate_invoice_sequence(
  p_advocate_id UUID
) RETURNS TABLE (
  is_valid BOOLEAN,
  issues TEXT[],
  last_invoice_number TEXT,
  expected_next_number TEXT,
  gaps INTEGER[],
  duplicates TEXT[]
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_issues TEXT[] := ARRAY[]::TEXT[];
  v_gaps INTEGER[] := ARRAY[]::INTEGER[];
  v_duplicates TEXT[] := ARRAY[]::TEXT[];
  v_last_number TEXT;
  v_expected_next TEXT;
  v_current_year INTEGER;
  v_format TEXT;
BEGIN
  v_current_year := EXTRACT(YEAR FROM CURRENT_DATE);
  
  -- Get format
  SELECT invoice_number_format INTO v_format
  FROM invoice_settings
  WHERE advocate_id = p_advocate_id;
  
  -- Check for gaps in sequence
  WITH numbered_invoices AS (
    SELECT 
      invoice_number,
      sequence_number,
      year,
      ROW_NUMBER() OVER (PARTITION BY year ORDER BY sequence_number) as expected_seq
    FROM invoice_numbering_audit
    WHERE advocate_id = p_advocate_id
    AND number_type = 'invoice'
    AND year = v_current_year
  )
  SELECT ARRAY_AGG(sequence_number)
  INTO v_gaps
  FROM numbered_invoices
  WHERE sequence_number != expected_seq;
  
  IF ARRAY_LENGTH(v_gaps, 1) > 0 THEN
    v_issues := ARRAY_APPEND(v_issues, 'Gaps found in sequence: ' || ARRAY_TO_STRING(v_gaps, ', '));
  END IF;
  
  -- Check for duplicates
  SELECT ARRAY_AGG(number_issued)
  INTO v_duplicates
  FROM (
    SELECT number_issued, COUNT(*) as cnt
    FROM invoice_numbering_audit
    WHERE advocate_id = p_advocate_id
    AND year = v_current_year
    GROUP BY number_issued
    HAVING COUNT(*) > 1
  ) dups;
  
  IF ARRAY_LENGTH(v_duplicates, 1) > 0 THEN
    v_issues := ARRAY_APPEND(v_issues, 'Duplicate numbers found: ' || ARRAY_TO_STRING(v_duplicates, ', '));
  END IF;
  
  -- Get last number and expected next
  SELECT number_issued
  INTO v_last_number
  FROM invoice_numbering_audit
  WHERE advocate_id = p_advocate_id
  AND number_type = 'invoice'
  AND year = v_current_year
  ORDER BY sequence_number DESC
  LIMIT 1;
  
  -- Calculate expected next
  SELECT current_sequence + 1
  INTO v_expected_next
  FROM invoice_settings
  WHERE advocate_id = p_advocate_id;
  
  v_expected_next := format_invoice_number(v_format, v_current_year, v_expected_next::INTEGER);
  
  -- Return results
  RETURN QUERY SELECT 
    (ARRAY_LENGTH(v_issues, 1) IS NULL OR ARRAY_LENGTH(v_issues, 1) = 0) as is_valid,
    COALESCE(v_issues, ARRAY[]::TEXT[]) as issues,
    v_last_number as last_invoice_number,
    v_expected_next as expected_next_number,
    COALESCE(v_gaps, ARRAY[]::INTEGER[]) as gaps,
    COALESCE(v_duplicates, ARRAY[]::TEXT[]) as duplicates;
END;
$$;

-- ============================================================================
-- TABLE: Invoice Numbering Audit (Enhanced)
-- ============================================================================

-- Add additional columns if not exists
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'invoice_numbering_audit' 
                 AND column_name = 'voided_at') THEN
    ALTER TABLE invoice_numbering_audit
    ADD COLUMN voided_at TIMESTAMPTZ,
    ADD COLUMN void_reason TEXT,
    ADD COLUMN related_credit_note TEXT;
  END IF;
END $$;

-- ============================================================================
-- FUNCTION: Mark Invoice as Voided
-- ============================================================================

CREATE OR REPLACE FUNCTION mark_invoice_voided(
  p_invoice_number TEXT,
  p_advocate_id UUID,
  p_void_reason TEXT,
  p_credit_note_number TEXT
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE invoice_numbering_audit
  SET 
    voided_at = NOW(),
    void_reason = p_void_reason,
    related_credit_note = p_credit_note_number
  WHERE number_issued = p_invoice_number
  AND advocate_id = p_advocate_id;
  
  -- Log the void action
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    INSERT INTO audit_log (
      advocate_id,
      action,
      entity_type,
      entity_id,
      details,
      created_at
    ) VALUES (
      p_advocate_id,
      'invoice_voided',
      'invoice',
      p_invoice_number,
      jsonb_build_object(
        'invoice_number', p_invoice_number,
        'void_reason', p_void_reason,
        'credit_note', p_credit_note_number
      ),
      NOW()
    );
  END IF;
END;
$$;

-- ============================================================================
-- TRIGGER: Auto-assign Invoice Number on Insert
-- ============================================================================

CREATE OR REPLACE FUNCTION auto_assign_invoice_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Only assign if invoice_number is NULL
  IF NEW.invoice_number IS NULL THEN
    NEW.invoice_number := get_next_invoice_number(NEW.advocate_id, 'invoice');
  END IF;
  
  RETURN NEW;
END;
$$;

-- Drop existing trigger if exists
DROP TRIGGER IF EXISTS trigger_auto_assign_invoice_number ON invoices;

-- Create trigger
CREATE TRIGGER trigger_auto_assign_invoice_number
  BEFORE INSERT ON invoices
  FOR EACH ROW
  EXECUTE FUNCTION auto_assign_invoice_number();

-- ============================================================================
-- TRIGGER: Auto-assign Credit Note Number on Insert
-- ============================================================================

CREATE OR REPLACE FUNCTION auto_assign_credit_note_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Only assign if credit_note_number is NULL
  IF NEW.credit_note_number IS NULL THEN
    NEW.credit_note_number := get_next_invoice_number(NEW.advocate_id, 'credit_note');
  END IF;
  
  RETURN NEW;
END;
$$;

-- Drop existing trigger if exists
DROP TRIGGER IF EXISTS trigger_auto_assign_credit_note_number ON credit_notes;

-- Create trigger
CREATE TRIGGER trigger_auto_assign_credit_note_number
  BEFORE INSERT ON credit_notes
  FOR EACH ROW
  EXECUTE FUNCTION auto_assign_credit_note_number();

-- ============================================================================
-- INDEXES for Performance
-- ============================================================================

-- Index on invoice_numbering_audit for fast lookups
CREATE INDEX IF NOT EXISTS idx_invoice_audit_advocate_year 
ON invoice_numbering_audit(advocate_id, year, sequence_number DESC);

CREATE INDEX IF NOT EXISTS idx_invoice_audit_number 
ON invoice_numbering_audit(advocate_id, number_issued);

-- Index on invoices for number uniqueness checks
CREATE UNIQUE INDEX IF NOT EXISTS idx_invoices_number_unique 
ON invoices(advocate_id, invoice_number);

-- Index on credit_notes for number uniqueness checks
CREATE UNIQUE INDEX IF NOT EXISTS idx_credit_notes_number_unique 
ON credit_notes(advocate_id, credit_note_number);

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON FUNCTION get_next_invoice_number IS 
'Atomically generates next sequential invoice or credit note number with concurrency handling and automatic year reset';

COMMENT ON FUNCTION format_invoice_number IS 
'Formats invoice number according to configured format (e.g., INV-2025-001)';

COMMENT ON FUNCTION validate_invoice_sequence IS 
'Validates invoice numbering sequence for SARS compliance, checking for gaps and duplicates';

COMMENT ON FUNCTION mark_invoice_voided IS 
'Marks an invoice as voided in the audit trail with reason and related credit note';
