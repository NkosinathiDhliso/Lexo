-- Add missing DELETE policy for matters table
-- This allows users to delete their own matters, which is needed for reverse conversion

DROP POLICY IF EXISTS "matters_delete_policy" ON matters;

CREATE POLICY "matters_delete_policy" ON matters
  FOR DELETE USING (auth.uid() = advocate_id);

-- Grant DELETE permission to authenticated users for matters table
GRANT DELETE ON matters TO authenticated;