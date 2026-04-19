-- Migration: Remove Document Upload System
-- Date: January 27, 2025
-- Purpose: Remove document upload functionality to maintain privacy-first approach
-- Note: This removes tables that stored actual document uploads on our server
--       The document_references table (for cloud storage links) is kept intact

-- ================================================================================
-- DROP UPLOAD-RELATED TABLES
-- ================================================================================

-- Drop dependent tables first (due to foreign keys)
DROP TABLE IF EXISTS document_extracted_data CASCADE;
DROP TABLE IF EXISTS document_cloud_storage CASCADE;
DROP TABLE IF EXISTS document_uploads CASCADE;

-- ================================================================================
-- REMOVE STORAGE BUCKET POLICIES (if any)
-- ================================================================================

-- Note: Supabase storage bucket 'documents' should be manually deleted via dashboard
-- The bucket cannot be dropped via SQL migration

-- ================================================================================
-- CLEANUP REFERENCES IN OTHER TABLES
-- ================================================================================

-- Check if matters table has a reference to document_uploads
-- If there's a local_document_id column, set it to null or drop it
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 
        FROM information_schema.columns 
        WHERE table_name='matters' AND column_name='local_document_id'
    ) THEN
        ALTER TABLE matters DROP COLUMN IF EXISTS local_document_id CASCADE;
        RAISE NOTICE 'Dropped local_document_id column from matters table';
    END IF;
END $$;

-- Check if proforma_requests table has references to document_uploads
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 
        FROM information_schema.columns 
        WHERE table_name='proforma_requests' AND column_name='document_upload_id'
    ) THEN
        ALTER TABLE proforma_requests DROP COLUMN IF EXISTS document_upload_id CASCADE;
        RAISE NOTICE 'Dropped document_upload_id column from proforma_requests table';
    END IF;
END $$;

-- ================================================================================
-- VERIFICATION
-- ================================================================================

-- Verify tables are dropped
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='document_uploads') THEN
        RAISE NOTICE '✓ document_uploads table successfully dropped';
    ELSE
        RAISE WARNING '⚠ document_uploads table still exists';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='document_extracted_data') THEN
        RAISE NOTICE '✓ document_extracted_data table successfully dropped';
    ELSE
        RAISE WARNING '⚠ document_extracted_data table still exists';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='document_cloud_storage') THEN
        RAISE NOTICE '✓ document_cloud_storage table successfully dropped';
    ELSE
        RAISE WARNING '⚠ document_cloud_storage table still exists';
    END IF;
END $$;

-- ================================================================================
-- IMPORTANT NOTES
-- ================================================================================

-- What this migration REMOVES:
-- 1. document_uploads - Table that stored uploaded file metadata and file URLs
-- 2. document_extracted_data - Table that stored AI-extracted data from uploads
-- 3. document_cloud_storage - Table that synced uploaded files to cloud storage

-- What this migration KEEPS:
-- 1. document_references - Table for linking to files in user's own cloud storage
-- 2. cloud_storage_connections - Table for OAuth connections to Google Drive, etc.
-- 3. cloud_storage_sync_log - Table for tracking sync operations

-- Privacy Protection:
-- This migration enforces the privacy-first approach where:
-- - Users' documents stay in their own cloud storage (Google Drive, OneDrive, etc.)
-- - Only metadata and references are stored in our database
-- - No actual document content is stored on our servers

COMMENT ON SCHEMA public IS 'Document upload system removed - use document_references for cloud storage links only';
