-- =============================================================================
-- HSK BONE CARE — HOSPITAL MANAGEMENT SYSTEM
-- Layer 4: Triggers (PostgreSQL)
-- Author  : Muhammad Arham (23-CSE-13)
-- Course  : Database Management System — 6th Semester, DUET
-- Teacher : Engr. Motia Rani
-- Run AFTER: hsk_layer1_schema.sql, hsk_layer2_indexes.sql, hsk_layer3_procedures.sql
-- =============================================================================

SET search_path TO hsk;

-- =============================================================================
-- HOW TRIGGERS WORK IN POSTGRESQL
--
-- A trigger is a function that fires automatically when a specific event
-- (INSERT, UPDATE, DELETE) happens on a table. You cannot forget to call it.
-- It fires at the DB level regardless of which application touches the data.
--
-- Two parts to every trigger:
--   1. TRIGGER FUNCTION  — the logic (written in PL/pgSQL, returns TRIGGER)
--   2. TRIGGER BINDING   — attaches the function to a table + event + timing
--
-- Timings:
--   BEFORE — fires before the row is written; can modify NEW or cancel the op
--   AFTER  — fires after the row is written; used for side effects (audit, etc.)
--
-- Special variables inside trigger functions:
--   NEW  — the new row (available on INSERT and UPDATE)
--   OLD  — the old row (available on UPDATE and DELETE)
--   TG_OP — the operation string: 'INSERT', 'UPDATE', 'DELETE'
-- =============================================================================


-- =============================================================================
-- TRIGGER 1 — trg_room_on_admission
-- WHEN : AFTER INSERT on admissions
-- DOES : Marks the room as unavailable the moment a patient is admitted.
--
-- Why a trigger and not just the procedure?
-- The stored procedure already does this — but what if someone inserts directly
-- into admissions via SQL, a migration script, or a future API route?
-- The trigger guarantees the room is always marked regardless of how the
-- admission row gets created.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_room_on_admission()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Only act when status is 'admitted' (not on discharge updates)
    IF NEW.status = 'admitted' THEN
        UPDATE rooms
        SET is_available = FALSE
        WHERE room_id = NEW.room_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_room_on_admission
    AFTER INSERT ON admissions
    FOR EACH ROW
    EXECUTE FUNCTION fn_room_on_admission();

COMMENT ON FUNCTION fn_room_on_admission IS
'Marks a room as unavailable whenever a new admission row is inserted.';


-- =============================================================================
-- TRIGGER 2 — trg_room_on_discharge
-- WHEN : AFTER UPDATE on admissions
-- DOES : Frees the room automatically when admission status changes to
--        'discharged'. Also sets discharge_date if left null.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_room_on_discharge()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Only act when status transitions from admitted → discharged
    IF OLD.status = 'admitted' AND NEW.status = 'discharged' THEN

        -- Free the room
        UPDATE rooms
        SET is_available = TRUE
        WHERE room_id = NEW.room_id;

        -- Auto-set discharge_date if caller forgot to set it
        IF NEW.discharge_date IS NULL THEN
            NEW.discharge_date := NOW();
        END IF;

    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_room_on_discharge
    BEFORE UPDATE ON admissions
    FOR EACH ROW
    EXECUTE FUNCTION fn_room_on_discharge();

COMMENT ON FUNCTION fn_room_on_discharge IS
'Frees a room and sets discharge_date automatically when an admission is updated to discharged.';


-- =============================================================================
-- TRIGGER 3 — trg_invoice_total_on_item_change
-- WHEN : AFTER INSERT, UPDATE, DELETE on invoice_items
-- DOES : Recalculates invoices.total_amount by summing all line items.
--        Also recalculates invoice status (unpaid / partial / paid).
--
-- This is the most important billing trigger — it means total_amount on the
-- invoice is ALWAYS accurate. No application code needed to maintain it.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_invoice_total_on_item_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_invoice_id    INT;
    v_new_total     NUMERIC;
    v_paid_amount   NUMERIC;
    v_new_status    invoice_status;
BEGIN
    -- Determine which invoice is affected
    -- On DELETE, OLD has the data; on INSERT/UPDATE, NEW has it
    IF TG_OP = 'DELETE' THEN
        v_invoice_id := OLD.invoice_id;
    ELSE
        v_invoice_id := NEW.invoice_id;
    END IF;

    -- Recalculate total from all remaining line items
    SELECT COALESCE(SUM(total_price), 0.00)
    INTO v_new_total
    FROM invoice_items
    WHERE invoice_id = v_invoice_id;

    -- Get current paid amount to recalculate status
    SELECT paid_amount INTO v_paid_amount
    FROM invoices
    WHERE invoice_id = v_invoice_id;

    -- Determine new status
    IF v_new_total = 0 OR v_paid_amount = 0 THEN
        v_new_status := 'unpaid';
    ELSIF v_paid_amount >= v_new_total THEN
        v_new_status := 'paid';
    ELSE
        v_new_status := 'partial';
    END IF;

    -- Update the invoice
    UPDATE invoices
    SET
        total_amount = v_new_total,
        status       = v_new_status
    WHERE invoice_id = v_invoice_id;

    -- Return appropriate row
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

CREATE OR REPLACE TRIGGER trg_invoice_total_on_item_change
    AFTER INSERT OR UPDATE OR DELETE ON invoice_items
    FOR EACH ROW
    EXECUTE FUNCTION fn_invoice_total_on_item_change();

COMMENT ON FUNCTION fn_invoice_total_on_item_change IS
'Keeps invoices.total_amount and status in sync whenever a line item is inserted, updated, or deleted.';


-- =============================================================================
-- TRIGGER 4 — trg_invoice_status_on_payment
-- WHEN : AFTER INSERT on payments
-- DOES : Updates invoices.paid_amount by summing all payments for that invoice.
--        Recalculates status: unpaid → partial → paid.
--
-- Complements Trigger 3: items drive total_amount, payments drive paid_amount.
-- Together they keep the invoice always consistent.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_invoice_status_on_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_amount  NUMERIC;
    v_new_paid      NUMERIC;
    v_new_status    invoice_status;
BEGIN
    -- Sum all payments for this invoice
    SELECT COALESCE(SUM(amount), 0.00)
    INTO v_new_paid
    FROM payments
    WHERE invoice_id = NEW.invoice_id;

    -- Get invoice total
    SELECT total_amount INTO v_total_amount
    FROM invoices
    WHERE invoice_id = NEW.invoice_id;

    -- Determine status
    IF v_new_paid <= 0 THEN
        v_new_status := 'unpaid';
    ELSIF v_new_paid >= v_total_amount THEN
        v_new_status := 'paid';
    ELSE
        v_new_status := 'partial';
    END IF;

    -- Update invoice
    UPDATE invoices
    SET
        paid_amount = v_new_paid,
        status      = v_new_status
    WHERE invoice_id = NEW.invoice_id;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_invoice_status_on_payment
    AFTER INSERT ON payments
    FOR EACH ROW
    EXECUTE FUNCTION fn_invoice_status_on_payment();

COMMENT ON FUNCTION fn_invoice_status_on_payment IS
'Recalculates invoice paid_amount and status (unpaid/partial/paid) after every new payment row.';


-- =============================================================================
-- TRIGGER 5 — trg_prevent_paid_invoice_edit
-- WHEN : BEFORE UPDATE on invoices
-- DOES : Blocks any manual edit to a fully paid invoice.
--        Financial records must be immutable once settled.
--        Corrections must be done via new line items or reversal payments.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_prevent_paid_invoice_edit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Allow status transitions driven by our own triggers (total_amount changes)
    -- Block any external attempt to manually change amount fields on a paid invoice
    IF OLD.status = 'paid'
       AND (OLD.total_amount != NEW.total_amount OR OLD.paid_amount != NEW.paid_amount)
       AND NEW.status != 'paid' THEN
        RAISE EXCEPTION
            'IMMUTABLE_RECORD: Invoice % is fully paid and cannot be modified. Create a new invoice or reversal entry.',
            OLD.invoice_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_prevent_paid_invoice_edit
    BEFORE UPDATE ON invoices
    FOR EACH ROW
    EXECUTE FUNCTION fn_prevent_paid_invoice_edit();

COMMENT ON FUNCTION fn_prevent_paid_invoice_edit IS
'Prevents manual edits to amount fields on fully paid invoices. Enforces financial immutability.';


-- =============================================================================
-- TRIGGER 6 — trg_audit_patients
-- WHEN : AFTER UPDATE or DELETE on patients
-- DOES : Writes a complete before/after snapshot to audit_log automatically.
--        Captures who changed what and when, without any application code.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_audit_patients()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO audit_log (
        user_id, action, target_table, target_id,
        old_data, new_data
    )
    VALUES (
        NULLIF(current_setting('app.current_user_id', TRUE), '')::INT,
        TG_OP || '_PATIENT',
        'patients',
        COALESCE(OLD.patient_id, NEW.patient_id),
        CASE WHEN TG_OP != 'INSERT' THEN row_to_json(OLD)::JSONB ELSE NULL END,
        CASE WHEN TG_OP != 'DELETE' THEN row_to_json(NEW)::JSONB ELSE NULL END
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

CREATE OR REPLACE TRIGGER trg_audit_patients
    AFTER INSERT OR UPDATE OR DELETE ON patients
    FOR EACH ROW
    EXECUTE FUNCTION fn_audit_patients();

COMMENT ON FUNCTION fn_audit_patients IS
'Auto-logs every INSERT, UPDATE, DELETE on patients table with full before/after JSON snapshots.';


-- =============================================================================
-- TRIGGER 7 — trg_audit_admissions
-- WHEN : AFTER INSERT, UPDATE, DELETE on admissions
-- DOES : Same as above — full snapshot audit trail for admission records.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_audit_admissions()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO audit_log (
        user_id, action, target_table, target_id,
        old_data, new_data
    )
    VALUES (
        NULLIF(current_setting('app.current_user_id', TRUE), '')::INT,
        TG_OP || '_ADMISSION',
        'admissions',
        COALESCE(OLD.admission_id, NEW.admission_id),
        CASE WHEN TG_OP != 'INSERT' THEN row_to_json(OLD)::JSONB ELSE NULL END,
        CASE WHEN TG_OP != 'DELETE' THEN row_to_json(NEW)::JSONB ELSE NULL END
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

CREATE OR REPLACE TRIGGER trg_audit_admissions
    AFTER INSERT OR UPDATE OR DELETE ON admissions
    FOR EACH ROW
    EXECUTE FUNCTION fn_audit_admissions();

COMMENT ON FUNCTION fn_audit_admissions IS
'Auto-logs every INSERT, UPDATE, DELETE on admissions table with full JSON snapshots.';


-- =============================================================================
-- TRIGGER 8 — trg_audit_invoices
-- WHEN : AFTER INSERT, UPDATE, DELETE on invoices
-- DOES : Audit trail for all invoice changes — critical for financial compliance.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_audit_invoices()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO audit_log (
        user_id, action, target_table, target_id,
        old_data, new_data
    )
    VALUES (
        NULLIF(current_setting('app.current_user_id', TRUE), '')::INT,
        TG_OP || '_INVOICE',
        'invoices',
        COALESCE(OLD.invoice_id, NEW.invoice_id),
        CASE WHEN TG_OP != 'INSERT' THEN row_to_json(OLD)::JSONB ELSE NULL END,
        CASE WHEN TG_OP != 'DELETE' THEN row_to_json(NEW)::JSONB ELSE NULL END
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

CREATE OR REPLACE TRIGGER trg_audit_invoices
    AFTER INSERT OR UPDATE OR DELETE ON invoices
    FOR EACH ROW
    EXECUTE FUNCTION fn_audit_invoices();

COMMENT ON FUNCTION fn_audit_invoices IS
'Auto-logs every INSERT, UPDATE, DELETE on invoices table with full JSON snapshots.';


-- =============================================================================
-- TRIGGER 9 — trg_audit_users
-- WHEN : AFTER INSERT, UPDATE, DELETE on users
-- DOES : Audit trail for all user account changes — security compliance.
--        Captures role changes, password resets, account creation/deletion.
-- Note : password_hash is scrubbed from snapshots — never log credentials.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_audit_users()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_scrubbed JSONB;
    v_new_scrubbed JSONB;
BEGIN
    -- Scrub password_hash from both snapshots before logging
    IF TG_OP != 'INSERT' THEN
        v_old_scrubbed := (row_to_json(OLD)::JSONB) - 'password_hash';
    END IF;

    IF TG_OP != 'DELETE' THEN
        v_new_scrubbed := (row_to_json(NEW)::JSONB) - 'password_hash';
    END IF;

    INSERT INTO audit_log (
        user_id, action, target_table, target_id,
        old_data, new_data
    )
    VALUES (
        NULLIF(current_setting('app.current_user_id', TRUE), '')::INT,
        TG_OP || '_USER',
        'users',
        COALESCE(OLD.user_id, NEW.user_id),
        v_old_scrubbed,
        v_new_scrubbed
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

CREATE OR REPLACE TRIGGER trg_audit_users
    AFTER INSERT OR UPDATE OR DELETE ON users
    FOR EACH ROW
    EXECUTE FUNCTION fn_audit_users();

COMMENT ON FUNCTION fn_audit_users IS
'Audits all user account changes. Scrubs password_hash from snapshots before logging.';


-- =============================================================================
-- TRIGGER 10 — trg_soft_delete_guard
-- WHEN : BEFORE DELETE on patients, doctors
-- DOES : Blocks hard DELETE on patients and doctors entirely.
--        Forces callers to use soft delete (is_deleted = TRUE) instead.
--        Hospital records must never be permanently erased — legal compliance.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_soft_delete_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'HARD_DELETE_BLOCKED: Direct DELETE on table "%" is not allowed. '
        'Set is_deleted = TRUE or is_active = FALSE instead. '
        'Record ID: %.',
        TG_TABLE_NAME,
        OLD.patient_id;
    RETURN NULL;
END;
$$;

-- Apply to patients
CREATE OR REPLACE TRIGGER trg_soft_delete_guard_patients
    BEFORE DELETE ON patients
    FOR EACH ROW
    EXECUTE FUNCTION fn_soft_delete_guard();

-- Separate guard for doctors (different PK column name)
CREATE OR REPLACE FUNCTION fn_soft_delete_guard_doctors()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'HARD_DELETE_BLOCKED: Direct DELETE on "doctors" is not allowed. '
        'Set is_active = FALSE instead. Doctor ID: %.',
        OLD.doctor_id;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER trg_soft_delete_guard_doctors
    BEFORE DELETE ON doctors
    FOR EACH ROW
    EXECUTE FUNCTION fn_soft_delete_guard_doctors();

COMMENT ON FUNCTION fn_soft_delete_guard IS
'Blocks hard DELETE on patients — enforces soft delete for legal data retention compliance.';

COMMENT ON FUNCTION fn_soft_delete_guard_doctors IS
'Blocks hard DELETE on doctors — enforces soft delete for legal data retention compliance.';


-- =============================================================================
-- TRIGGER 11 — trg_appointment_status_guard
-- WHEN : BEFORE UPDATE on appointments
-- DOES : Enforces valid status transition rules.
--        A completed or cancelled appointment cannot be re-opened.
--        Prevents receptionists from accidentally or maliciously rolling back
--        a completed appointment to pending.
--
-- Valid transitions:
--   pending    → confirmed, cancelled
--   confirmed  → completed, cancelled
--   completed  → (no transitions allowed)
--   cancelled  → (no transitions allowed)
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_appointment_status_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Only run if status is actually changing
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    -- Block any transition out of terminal states
    IF OLD.status IN ('completed', 'cancelled') THEN
        RAISE EXCEPTION
            'STATUS_TRANSITION_BLOCKED: Appointment % is already "%" and cannot be changed.',
            OLD.appointment_id, OLD.status;
    END IF;

    -- Block invalid forward transitions
    IF OLD.status = 'pending' AND NEW.status = 'completed' THEN
        RAISE EXCEPTION
            'STATUS_TRANSITION_BLOCKED: Appointment % cannot jump from "pending" to "completed". Confirm it first.',
            OLD.appointment_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_appointment_status_guard
    BEFORE UPDATE ON appointments
    FOR EACH ROW
    EXECUTE FUNCTION fn_appointment_status_guard();

COMMENT ON FUNCTION fn_appointment_status_guard IS
'Enforces valid appointment status transitions. Blocks re-opening completed or cancelled appointments.';


-- =============================================================================
-- HOW TO SET THE CURRENT USER FOR AUDIT TRIGGERS
-- The audit triggers read app.current_user_id from the session config.
-- Set this at the start of every DB session from your Node.js app:
--
--   await client.query("SET app.current_user_id = $1", [userId]);
--
-- This propagates through all trigger calls in the session automatically.
-- =============================================================================


-- =============================================================================
-- VERIFICATION — List all triggers in the hsk schema
-- =============================================================================

SELECT
    trigger_name,
    event_manipulation  AS event,
    event_object_table  AS table_name,
    action_timing       AS timing,
    action_orientation  AS per
FROM information_schema.triggers
WHERE trigger_schema = 'hsk'
ORDER BY event_object_table, action_timing, trigger_name;
