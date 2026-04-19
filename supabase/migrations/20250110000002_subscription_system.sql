-- Subscription System Migration
-- Creates tables for subscription management and payment tracking

-- Create subscription_tiers enum
CREATE TYPE subscription_tier AS ENUM ('admission', 'advocate', 'senior_counsel');
CREATE TYPE subscription_status AS ENUM ('active', 'cancelled', 'past_due', 'trialing', 'expired');
CREATE TYPE payment_gateway AS ENUM ('paystack', 'payfast');
CREATE TYPE payment_status AS ENUM ('pending', 'completed', 'failed', 'refunded');

-- Subscriptions table
CREATE TABLE IF NOT EXISTS subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tier subscription_tier NOT NULL DEFAULT 'admission',
  status subscription_status NOT NULL DEFAULT 'active',
  current_period_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  current_period_end TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '30 days',
  cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE,
  payment_gateway payment_gateway,
  gateway_subscription_id TEXT,
  gateway_customer_id TEXT,
  additional_users INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id)
);

-- Payment transactions table
CREATE TABLE IF NOT EXISTS payment_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id UUID NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
  amount INTEGER NOT NULL, -- in cents
  currency TEXT NOT NULL DEFAULT 'ZAR',
  status payment_status NOT NULL DEFAULT 'pending',
  payment_gateway payment_gateway NOT NULL,
  gateway_transaction_id TEXT,
  gateway_reference TEXT UNIQUE,
  metadata JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Subscription history table (for auditing)
CREATE TABLE IF NOT EXISTS subscription_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id UUID NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
  tier subscription_tier NOT NULL,
  status subscription_status NOT NULL,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  changed_by UUID REFERENCES auth.users(id),
  reason TEXT
);

-- Create indexes
CREATE INDEX idx_subscriptions_user_id ON subscriptions(user_id);
CREATE INDEX idx_subscriptions_status ON subscriptions(status);
CREATE INDEX idx_subscriptions_tier ON subscriptions(tier);
CREATE INDEX idx_payment_transactions_subscription_id ON payment_transactions(subscription_id);
CREATE INDEX idx_payment_transactions_status ON payment_transactions(status);
CREATE INDEX idx_payment_transactions_gateway_reference ON payment_transactions(gateway_reference);
CREATE INDEX idx_subscription_history_subscription_id ON subscription_history(subscription_id);

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers for updated_at
CREATE TRIGGER update_subscriptions_updated_at
  BEFORE UPDATE ON subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_payment_transactions_updated_at
  BEFORE UPDATE ON payment_transactions
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- Function to log subscription changes
CREATE OR REPLACE FUNCTION log_subscription_change()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'UPDATE' AND (OLD.tier != NEW.tier OR OLD.status != NEW.status)) THEN
    INSERT INTO subscription_history (subscription_id, tier, status, changed_by, reason)
    VALUES (NEW.id, NEW.tier, NEW.status, NEW.user_id, 'Subscription updated');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for subscription history
CREATE TRIGGER log_subscription_changes
  AFTER UPDATE ON subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION log_subscription_change();

-- Function to check subscription limits
CREATE OR REPLACE FUNCTION check_subscription_limits(
  p_user_id UUID,
  p_action TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
  v_subscription subscriptions%ROWTYPE;
  v_active_matters_count INTEGER;
  v_max_matters INTEGER;
BEGIN
  -- Get user's subscription
  SELECT * INTO v_subscription
  FROM subscriptions
  WHERE user_id = p_user_id AND status = 'active';

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  -- Check matter limits
  IF p_action = 'create_matter' THEN
    -- Get max matters for tier
    v_max_matters := CASE v_subscription.tier
      WHEN 'admission' THEN 10
      WHEN 'advocate' THEN 50
      WHEN 'senior_counsel' THEN NULL -- unlimited
    END;

    IF v_max_matters IS NOT NULL THEN
      SELECT COUNT(*) INTO v_active_matters_count
      FROM matters
      WHERE user_id = p_user_id AND status = 'active';

      IF v_active_matters_count >= v_max_matters THEN
        RETURN FALSE;
      END IF;
    END IF;
  END IF;

  RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- RLS Policies
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_history ENABLE ROW LEVEL SECURITY;

-- Subscriptions policies
CREATE POLICY "Users can view their own subscription"
  ON subscriptions FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own subscription"
  ON subscriptions FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own subscription"
  ON subscriptions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Payment transactions policies
CREATE POLICY "Users can view their own payment transactions"
  ON payment_transactions FOR SELECT
  USING (
    subscription_id IN (
      SELECT id FROM subscriptions WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Users can insert their own payment transactions"
  ON payment_transactions FOR INSERT
  WITH CHECK (
    subscription_id IN (
      SELECT id FROM subscriptions WHERE user_id = auth.uid()
    )
  );

-- Subscription history policies
CREATE POLICY "Users can view their own subscription history"
  ON subscription_history FOR SELECT
  USING (
    subscription_id IN (
      SELECT id FROM subscriptions WHERE user_id = auth.uid()
    )
  );

-- Grant permissions
GRANT ALL ON subscriptions TO authenticated;
GRANT ALL ON payment_transactions TO authenticated;
GRANT ALL ON subscription_history TO authenticated;

-- Create default admission subscription for existing users
INSERT INTO subscriptions (user_id, tier, status)
SELECT id, 'admission', 'active'
FROM auth.users
WHERE id NOT IN (SELECT user_id FROM subscriptions)
ON CONFLICT (user_id) DO NOTHING;

COMMENT ON TABLE subscriptions IS 'Stores user subscription information';
COMMENT ON TABLE payment_transactions IS 'Tracks all payment transactions';
COMMENT ON TABLE subscription_history IS 'Audit log for subscription changes';
