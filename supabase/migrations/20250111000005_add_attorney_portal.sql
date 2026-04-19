-- Attorney Portal Database Schema

-- Attorney Users Table
CREATE TABLE IF NOT EXISTS attorney_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    
    firm_name TEXT NOT NULL,
    attorney_name TEXT NOT NULL,
    practice_number TEXT,
    
    phone_number TEXT,
    notification_preferences JSONB DEFAULT '{
        "email": true,
        "sms": true,
        "in_app": true,
        "proforma_requests": true,
        "invoice_issued": true,
        "invoice_overdue": true,
        "payment_received": true
    }'::jsonb,
    
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deleted')),
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_login_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_attorney_users_email ON attorney_users(email) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_attorney_users_status ON attorney_users(status) WHERE deleted_at IS NULL;

COMMENT ON TABLE attorney_users IS 'Instructing attorneys who access the attorney portal';

-- Attorney Matter Access Table
CREATE TABLE IF NOT EXISTS attorney_matter_access (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    attorney_user_id UUID NOT NULL REFERENCES attorney_users(id) ON DELETE CASCADE,
    matter_id UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    
    access_level TEXT NOT NULL DEFAULT 'view' CHECK (access_level IN ('view', 'approve', 'admin')),
    
    granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    granted_by UUID REFERENCES advocates(id),
    
    revoked_at TIMESTAMPTZ,
    revoked_by UUID REFERENCES advocates(id),
    revoked_reason TEXT,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE(attorney_user_id, matter_id)
);

CREATE INDEX IF NOT EXISTS idx_attorney_matter_access_attorney ON attorney_matter_access(attorney_user_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_attorney_matter_access_matter ON attorney_matter_access(matter_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_attorney_matter_access_level ON attorney_matter_access(access_level) WHERE revoked_at IS NULL;

COMMENT ON TABLE attorney_matter_access IS 'Controls which attorneys can access which matters';
COMMENT ON COLUMN attorney_matter_access.access_level IS 'Access level: view (read-only), approve (can approve pro formas), admin (full access)';

-- Notifications Table
CREATE TABLE IF NOT EXISTS notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    recipient_type TEXT NOT NULL CHECK (recipient_type IN ('advocate', 'attorney')),
    recipient_id UUID NOT NULL,
    
    notification_type TEXT NOT NULL CHECK (notification_type IN (
        'proforma_request',
        'proforma_approved',
        'proforma_rejected',
        'proforma_negotiation',
        'invoice_issued',
        'invoice_overdue',
        'invoice_overdue_final',
        'payment_received',
        'payment_partial',
        'matter_status_change',
        'scope_amendment',
        'retainer_low_balance',
        'retainer_depleted'
    )),
    
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    
    related_matter_id UUID REFERENCES matters(id) ON DELETE SET NULL,
    related_invoice_id UUID REFERENCES invoices(id) ON DELETE SET NULL,
    related_proforma_id UUID REFERENCES proforma_requests(id) ON DELETE SET NULL,
    
    channels JSONB DEFAULT '["in_app"]'::jsonb,
    
    sent_at TIMESTAMPTZ,
    read_at TIMESTAMPTZ,
    
    email_sent BOOLEAN DEFAULT FALSE,
    email_sent_at TIMESTAMPTZ,
    
    sms_sent BOOLEAN DEFAULT FALSE,
    sms_sent_at TIMESTAMPTZ,
    
    metadata JSONB,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_recipient ON notifications(recipient_type, recipient_id);
CREATE INDEX IF NOT EXISTS idx_notifications_type ON notifications(notification_type);
CREATE INDEX IF NOT EXISTS idx_notifications_unread ON notifications(recipient_id) WHERE read_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_notifications_created ON notifications(created_at DESC);

COMMENT ON TABLE notifications IS 'System notifications for advocates and attorneys';

-- Audit Log Table
CREATE TABLE IF NOT EXISTS audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    user_type TEXT NOT NULL CHECK (user_type IN ('advocate', 'attorney', 'system')),
    user_id UUID NOT NULL,
    user_email TEXT,
    
    action TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL,
    
    changes JSONB,
    metadata JSONB,
    
    ip_address TEXT,
    user_agent TEXT,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_user ON audit_log(user_type, user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_entity ON audit_log(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_action ON audit_log(action);
CREATE INDEX IF NOT EXISTS idx_audit_log_created ON audit_log(created_at DESC);

COMMENT ON TABLE audit_log IS 'Complete audit trail of all user actions';

-- Extend matters table
ALTER TABLE matters
ADD COLUMN IF NOT EXISTS instructing_attorney_user_id UUID REFERENCES attorney_users(id) ON DELETE SET NULL;

ALTER TABLE proforma_requests
ADD COLUMN IF NOT EXISTS matter_id UUID REFERENCES matters(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_matters_attorney_user ON matters(instructing_attorney_user_id) WHERE deleted_at IS NULL;

COMMENT ON COLUMN matters.instructing_attorney_user_id IS 'Link to attorney portal user for this matter';

-- Extend retainer_agreements table
ALTER TABLE retainer_agreements
ADD COLUMN IF NOT EXISTS client_id UUID REFERENCES attorney_users(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS can_fund_multiple_matters BOOLEAN DEFAULT TRUE;

CREATE INDEX IF NOT EXISTS idx_retainer_agreements_client ON retainer_agreements(client_id) WHERE deleted_at IS NULL;

COMMENT ON COLUMN retainer_agreements.client_id IS 'Client/attorney who owns this retainer';
COMMENT ON COLUMN retainer_agreements.can_fund_multiple_matters IS 'Whether this retainer can fund multiple matters';

-- RLS Policies for Attorney Portal

-- Attorney Users
ALTER TABLE attorney_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Attorneys can view their own profile" ON attorney_users;
DROP POLICY IF EXISTS "Attorneys can update their own profile" ON attorney_users;

CREATE POLICY "Attorneys can view their own profile"
    ON attorney_users FOR SELECT
    USING (id = auth.uid());

CREATE POLICY "Attorneys can update their own profile"
    ON attorney_users FOR UPDATE
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid());

-- Attorney Matter Access
ALTER TABLE attorney_matter_access ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Attorneys can view their own access" ON attorney_matter_access;
DROP POLICY IF EXISTS "Advocates can manage attorney access" ON attorney_matter_access;

CREATE POLICY "Attorneys can view their own access"
    ON attorney_matter_access FOR SELECT
    USING (attorney_user_id = auth.uid());

CREATE POLICY "Advocates can manage attorney access"
    ON attorney_matter_access FOR ALL
    USING (
        granted_by = auth.uid() OR
        matter_id IN (
            SELECT id FROM matters WHERE advocate_id = auth.uid()
        )
    );

-- Matters (Attorney Access)
DROP POLICY IF EXISTS "Attorneys can view matters they have access to" ON matters;
CREATE POLICY "Attorneys can view matters they have access to"
    ON matters FOR SELECT
    USING (
        id IN (
            SELECT matter_id 
            FROM attorney_matter_access 
            WHERE attorney_user_id = auth.uid()
            AND revoked_at IS NULL
        )
    );

-- Invoices (Attorney Access)
DROP POLICY IF EXISTS "Attorneys can view invoices for their matters" ON invoices;
CREATE POLICY "Attorneys can view invoices for their matters"
    ON invoices FOR SELECT
    USING (
        matter_id IN (
            SELECT matter_id 
            FROM attorney_matter_access 
            WHERE attorney_user_id = auth.uid()
            AND revoked_at IS NULL
        )
    );

-- Pro Forma Requests (Attorney Access)
DROP POLICY IF EXISTS "Attorneys can view pro formas for their matters" ON proforma_requests;
CREATE POLICY "Attorneys can view pro formas for their matters"
    ON proforma_requests FOR SELECT
    USING (
        id IN (
            SELECT pr.id
            FROM proforma_requests pr
            JOIN attorney_matter_access ama ON ama.matter_id = pr.matter_id
            WHERE ama.attorney_user_id = auth.uid()
            AND ama.revoked_at IS NULL
        )
    );

DROP POLICY IF EXISTS "Attorneys can respond to pro formas" ON proforma_requests;
CREATE POLICY "Attorneys can respond to pro formas"
    ON proforma_requests FOR UPDATE
    USING (
        id IN (
            SELECT pr.id
            FROM proforma_requests pr
            JOIN attorney_matter_access ama ON ama.matter_id = pr.matter_id
            WHERE ama.attorney_user_id = auth.uid()
            AND ama.access_level IN ('approve', 'admin')
            AND ama.revoked_at IS NULL
        )
    );

-- Notifications
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own notifications" ON notifications;
DROP POLICY IF EXISTS "Users can update their own notifications" ON notifications;
DROP POLICY IF EXISTS "System can create notifications" ON notifications;

CREATE POLICY "Users can view their own notifications"
    ON notifications FOR SELECT
    USING (
        (recipient_type = 'advocate' AND recipient_id = auth.uid()) OR
        (recipient_type = 'attorney' AND recipient_id = auth.uid())
    );

CREATE POLICY "Users can update their own notifications"
    ON notifications FOR UPDATE
    USING (
        (recipient_type = 'advocate' AND recipient_id = auth.uid()) OR
        (recipient_type = 'attorney' AND recipient_id = auth.uid())
    );

CREATE POLICY "System can create notifications"
    ON notifications FOR INSERT
    WITH CHECK (true);

-- Audit Log
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own audit log" ON audit_log;
DROP POLICY IF EXISTS "System can create audit log entries" ON audit_log;

CREATE POLICY "Users can view their own audit log"
    ON audit_log FOR SELECT
    USING (
        (user_type = 'advocate' AND user_id = auth.uid()) OR
        (user_type = 'attorney' AND user_id = auth.uid())
    );

CREATE POLICY "System can create audit log entries"
    ON audit_log FOR INSERT
    WITH CHECK (true);

-- Triggers
DROP TRIGGER IF EXISTS update_attorney_users_updated_at ON attorney_users;
CREATE TRIGGER update_attorney_users_updated_at
    BEFORE UPDATE ON attorney_users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_attorney_matter_access_updated_at ON attorney_matter_access;
CREATE TRIGGER update_attorney_matter_access_updated_at
    BEFORE UPDATE ON attorney_matter_access
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Function to automatically grant attorney access when matter is created
CREATE OR REPLACE FUNCTION grant_attorney_access_on_matter_create()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.instructing_attorney_user_id IS NOT NULL THEN
        INSERT INTO attorney_matter_access (
            attorney_user_id,
            matter_id,
            access_level,
            granted_by
        ) VALUES (
            NEW.instructing_attorney_user_id,
            NEW.id,
            'approve',
            NEW.advocate_id
        )
        ON CONFLICT (attorney_user_id, matter_id) DO NOTHING;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS grant_attorney_access_trigger ON matters;
CREATE TRIGGER grant_attorney_access_trigger
    AFTER INSERT ON matters
    FOR EACH ROW
    WHEN (NEW.instructing_attorney_user_id IS NOT NULL)
    EXECUTE FUNCTION grant_attorney_access_on_matter_create();

-- Function to create notification when pro forma is sent
CREATE OR REPLACE FUNCTION notify_attorney_on_proforma_request()
RETURNS TRIGGER AS $$
DECLARE
    attorney_id UUID;
    matter_title TEXT;
BEGIN
    IF NEW.status = 'sent' AND OLD.status != 'sent' THEN
        SELECT instructing_attorney_user_id, title
        INTO attorney_id, matter_title
        FROM matters
        WHERE id = NEW.matter_id;
        
        IF attorney_id IS NOT NULL THEN
            INSERT INTO notifications (
                recipient_type,
                recipient_id,
                notification_type,
                title,
                message,
                related_matter_id,
                related_proforma_id,
                channels
            ) VALUES (
                'attorney',
                attorney_id,
                'proforma_request',
                'New Pro Forma Request',
                'A new fee estimate for "' || matter_title || '" requires your review.',
                NEW.matter_id,
                NEW.id,
                '["email", "in_app"]'::jsonb
            );
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS notify_attorney_on_proforma_request_trigger ON proforma_requests;
CREATE TRIGGER notify_attorney_on_proforma_request_trigger
    AFTER UPDATE ON proforma_requests
    FOR EACH ROW
    EXECUTE FUNCTION notify_attorney_on_proforma_request();

-- Function to create notification when invoice is issued
CREATE OR REPLACE FUNCTION notify_attorney_on_invoice_issued()
RETURNS TRIGGER AS $$
DECLARE
    attorney_id UUID;
    matter_title TEXT;
BEGIN
    IF NEW.status = 'sent' AND (OLD.status IS NULL OR OLD.status != 'sent') THEN
        SELECT instructing_attorney_user_id, title
        INTO attorney_id, matter_title
        FROM matters
        WHERE id = NEW.matter_id;
        
        IF attorney_id IS NOT NULL THEN
            INSERT INTO notifications (
                recipient_type,
                recipient_id,
                notification_type,
                title,
                message,
                related_matter_id,
                related_invoice_id,
                channels
            ) VALUES (
                'attorney',
                attorney_id,
                'invoice_issued',
                'New Invoice Issued',
                'Invoice ' || NEW.invoice_number || ' for "' || matter_title || '" has been issued.',
                NEW.matter_id,
                NEW.id,
                '["email", "sms", "in_app"]'::jsonb
            );
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS notify_attorney_on_invoice_issued_trigger ON invoices;
CREATE TRIGGER notify_attorney_on_invoice_issued_trigger
    AFTER UPDATE ON invoices
    FOR EACH ROW
    WHEN (NEW.matter_id IS NOT NULL)
    EXECUTE FUNCTION notify_attorney_on_invoice_issued();
