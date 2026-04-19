-- Fix scope_amendments table permissions
-- The consolidated RLS policies migration missed granting permissions to scope_amendments table

-- Grant permissions to authenticated users for scope_amendments
GRANT SELECT, INSERT, UPDATE ON scope_amendments TO authenticated;

-- Also grant permissions for retainer_agreements and trust_transactions
GRANT SELECT, INSERT, UPDATE ON retainer_agreements TO authenticated;
GRANT SELECT, INSERT, UPDATE ON trust_transactions TO authenticated;

-- Ensure RLS is enabled (should already be enabled from original migrations)
ALTER TABLE scope_amendments ENABLE ROW LEVEL SECURITY;
ALTER TABLE retainer_agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE trust_transactions ENABLE ROW LEVEL SECURITY;