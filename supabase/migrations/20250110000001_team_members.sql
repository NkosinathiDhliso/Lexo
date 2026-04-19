-- Team Members Migration
-- Creates tables for team member management

-- Create team member roles enum
CREATE TYPE team_member_role AS ENUM ('admin', 'advocate', 'secretary');
CREATE TYPE team_member_status AS ENUM ('active', 'pending', 'inactive');

-- Team members table
CREATE TABLE IF NOT EXISTS team_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  email TEXT NOT NULL,
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  role team_member_role NOT NULL DEFAULT 'secretary',
  status team_member_status NOT NULL DEFAULT 'pending',
  invited_by UUID NOT NULL REFERENCES auth.users(id),
  invited_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  accepted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(organization_id, email)
);

-- User profiles table (if not exists)
CREATE TABLE IF NOT EXISTS user_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  first_name TEXT,
  last_name TEXT,
  phone TEXT,
  practice_name TEXT,
  practice_number TEXT,
  address TEXT,
  city TEXT,
  province TEXT,
  postal_code TEXT,
  avatar_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Create indexes
CREATE INDEX idx_team_members_organization_id ON team_members(organization_id);
CREATE INDEX idx_team_members_user_id ON team_members(user_id);
CREATE INDEX idx_team_members_email ON team_members(email);
CREATE INDEX idx_team_members_status ON team_members(status);
CREATE INDEX idx_user_profiles_user_id ON user_profiles(user_id);

-- Trigger for updated_at
CREATE TRIGGER update_team_members_updated_at
  BEFORE UPDATE ON team_members
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_user_profiles_updated_at
  BEFORE UPDATE ON user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- RLS Policies
ALTER TABLE team_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;

-- Team members policies
CREATE POLICY "Users can view team members in their organization"
  ON team_members FOR SELECT
  USING (
    organization_id = auth.uid() OR 
    user_id = auth.uid()
  );

CREATE POLICY "Organization owners can insert team members"
  ON team_members FOR INSERT
  WITH CHECK (organization_id = auth.uid());

CREATE POLICY "Organization owners can update team members"
  ON team_members FOR UPDATE
  USING (organization_id = auth.uid());

CREATE POLICY "Organization owners can delete team members"
  ON team_members FOR DELETE
  USING (organization_id = auth.uid());

-- User profiles policies
CREATE POLICY "Users can view their own profile"
  ON user_profiles FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "Users can insert their own profile"
  ON user_profiles FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update their own profile"
  ON user_profiles FOR UPDATE
  USING (user_id = auth.uid());

-- Grant permissions
GRANT ALL ON team_members TO authenticated;
GRANT ALL ON user_profiles TO authenticated;

-- Function to check team member limits
CREATE OR REPLACE FUNCTION check_team_member_limit()
RETURNS TRIGGER AS $$
DECLARE
  v_subscription subscriptions%ROWTYPE;
  v_current_members INTEGER;
  v_max_members INTEGER;
BEGIN
  -- Get organization's subscription
  SELECT * INTO v_subscription
  FROM subscriptions
  WHERE user_id = NEW.organization_id AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active subscription found';
  END IF;

  -- Get current member count
  SELECT COUNT(*) INTO v_current_members
  FROM team_members
  WHERE organization_id = NEW.organization_id AND status IN ('active', 'pending');

  -- Calculate max members based on tier
  v_max_members := CASE v_subscription.tier
    WHEN 'admission' THEN 1
    WHEN 'advocate' THEN 1 + v_subscription.additional_users
    WHEN 'senior_counsel' THEN 5 + v_subscription.additional_users
  END;

  IF v_current_members >= v_max_members THEN
    RAISE EXCEPTION 'Team member limit reached for current subscription tier';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to enforce team member limits
CREATE TRIGGER enforce_team_member_limit
  BEFORE INSERT ON team_members
  FOR EACH ROW
  EXECUTE FUNCTION check_team_member_limit();

COMMENT ON TABLE team_members IS 'Stores team member invitations and memberships';
COMMENT ON TABLE user_profiles IS 'Stores extended user profile information';
