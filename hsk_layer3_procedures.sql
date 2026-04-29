-- =============================================================================
-- HSK BONE CARE — HOSPITAL MANAGEMENT SYSTEM
-- Layer 3: Stored Procedures (PostgreSQL)
-- Author  : Muhammad Arham (23-CSE-13)
-- Course  : Database Management System — 6th Semester, DUET
-- Teacher : Engr. Motia Rani
-- Run AFTER: hsk_layer1_schema.sql, hsk_layer2_indexes.sql
-- =============================================================================

SET search_path TO hsk;

-- =============================================================================
-- WHAT ARE STORED PROCEDURES?
-- A stored procedure is a named, reusable block of SQL logic saved inside the
-- database itself. Instead of sending 5 separate queries from Node.js (where
-- any one could fail leaving the DB in a broken state), you call one procedure
-- and the DB handles the entire workflow atomically inside a transaction.
--
-- All procedures below use:
--   BEGIN / EXCEPTION / END    — transaction with automatic rollback on error
--   RAISE EXCEPTION            — custom error messages sent back to the caller
--   RAISE NOTICE               — informational log messages
--   OUT parameters             — return values back to the caller
-- =============================================================================


-- =============================================================================
-- PROCEDURE 1 — sp_admit_patient
-- Admits a patient into a room under a doctor's care.
--
-- Steps (all atomic):
--   1. Validate patient exists and is not deleted
--   2. Validate doctor is active
--   3. Validate room exists, is available, and matches type requested
--   4. Check patient has no current active admission
--   5. Create the admission record
--   6. Mark the room as unavailable
--   7. Create a blank invoice for the admission
--   8. Write to audit_log
--
-- Returns: admission_id, invoice_id (via OUT parameters)
-- =============================================================================

CREATE OR REPLACE PROCEDURE sp_admit_patient(
    IN  p_patient_id    INT,
    IN  p_doctor_id     INT,
    IN  p_room_id       INT,
    IN  p_diagnosis     TEXT,
    IN  p_created_by    INT,
    OUT o_admission_id  INT,
    OUT o_invoice_id    INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_patient_name  VARCHAR;
    v_doctor_name   VARCHAR;
    v_room_number   VARCHAR;
    v_room_type     room_type;
    v_active_count  INT;
BEGIN
    -- ── Step 1: Validate patient ──────────────────────────────────────────────
    SELECT full_name INTO v_patient_name
    FROM patients
    WHERE patient_id = p_patient_id AND is_deleted = FALSE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ADMIT_FAILED: Patient ID % does not exist or has been deleted.', p_patient_id;
    END IF;

    -- ── Step 2: Validate doctor ───────────────────────────────────────────────
    SELECT full_name INTO v_doctor_name
    FROM doctors
    WHERE doctor_id = p_doctor_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ADMIT_FAILED: Doctor ID % does not exist or is inactive.', p_doctor_id;
    END IF;

    -- ── Step 3: Validate room ─────────────────────────────────────────────────
    SELECT room_number, room_type INTO v_room_number, v_room_type
    FROM rooms
    WHERE room_id = p_room_id AND is_available = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ADMIT_FAILED: Room ID % does not exist or is not available.', p_room_id;
    END IF;

    -- ── Step 4: Ensure no duplicate active admission ──────────────────────────
    SELECT COUNT(*) INTO v_active_count
    FROM admissions
    WHERE patient_id = p_patient_id AND status = 'admitted';

    IF v_active_count > 0 THEN
        RAISE EXCEPTION 'ADMIT_FAILED: Patient "%" is already admitted. Discharge first.', v_patient_name;
    END IF;

    -- ── Step 5: Create admission record ───────────────────────────────────────
    INSERT INTO admissions (
        patient_id, doctor_id, room_id,
        diagnosis, status, created_by
    )
    VALUES (
        p_patient_id, p_doctor_id, p_room_id,
        p_diagnosis, 'admitted', p_created_by
    )
    RETURNING admission_id INTO o_admission_id;

    -- ── Step 6: Mark room as occupied ─────────────────────────────────────────
    UPDATE rooms
    SET is_available = FALSE
    WHERE room_id = p_room_id;

    -- ── Step 7: Create blank invoice for this admission ───────────────────────
    INSERT INTO invoices (
        patient_id, admission_id,
        total_amount, paid_amount, status,
        generated_by
    )
    VALUES (
        p_patient_id, o_admission_id,
        0.00, 0.00, 'unpaid',
        p_created_by
    )
    RETURNING invoice_id INTO o_invoice_id;

    -- ── Step 8: Audit log ─────────────────────────────────────────────────────
    INSERT INTO audit_log (user_id, action, target_table, target_id, new_data)
    VALUES (
        p_created_by,
        'PATIENT_ADMITTED',
        'admissions',
        o_admission_id,
        jsonb_build_object(
            'patient_id',   p_patient_id,
            'patient_name', v_patient_name,
            'doctor_id',    p_doctor_id,
            'doctor_name',  v_doctor_name,
            'room_id',      p_room_id,
            'room_number',  v_room_number,
            'invoice_id',   o_invoice_id
        )
    );

    RAISE NOTICE 'SUCCESS: Patient "%" admitted to Room % under Dr. %. Admission ID: %, Invoice ID: %',
        v_patient_name, v_room_number, v_doctor_name, o_admission_id, o_invoice_id;

EXCEPTION
    WHEN OTHERS THEN
        -- Any error above rolls back ALL changes automatically
        RAISE EXCEPTION '%', SQLERRM;
END;
$$;

COMMENT ON PROCEDURE sp_admit_patient IS
'Atomically admits a patient: validates all parties, creates admission, marks room occupied, opens a blank invoice, and logs the action.';


-- =============================================================================
-- PROCEDURE 2 — sp_discharge_patient
-- Discharges a currently admitted patient.
--
-- Steps (all atomic):
--   1. Validate the admission exists and is currently active
--   2. Calculate total room charges (days × daily_rate)
--   3. Add room charges as an invoice line item
--   4. Update invoice total
--   5. Mark admission as discharged with current timestamp
--   6. Free the room
--   7. Write to audit_log
--
-- Returns: admission_id, invoice_id, total_room_charge (via OUT parameters)
-- =============================================================================

CREATE OR REPLACE PROCEDURE sp_discharge_patient(
    IN  p_admission_id      INT,
    IN  p_discharged_by     INT,
    OUT o_invoice_id        INT,
    OUT o_total_room_charge NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_patient_id    INT;
    v_patient_name  VARCHAR;
    v_room_id       INT;
    v_room_number   VARCHAR;
    v_daily_rate    NUMERIC;
    v_admit_date    TIMESTAMPTZ;
    v_days_stayed   INT;
    v_current_total NUMERIC;
BEGIN
    -- ── Step 1: Validate active admission ─────────────────────────────────────
    SELECT
        a.patient_id, p.full_name,
        a.room_id, r.room_number, r.daily_rate,
        a.admission_date
    INTO
        v_patient_id, v_patient_name,
        v_room_id, v_room_number, v_daily_rate,
        v_admit_date
    FROM admissions a
    JOIN patients p ON p.patient_id = a.patient_id
    JOIN rooms    r ON r.room_id    = a.room_id
    WHERE a.admission_id = p_admission_id
      AND a.status = 'admitted';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DISCHARGE_FAILED: Admission ID % not found or patient already discharged.', p_admission_id;
    END IF;

    -- ── Step 2: Calculate room charges ────────────────────────────────────────
    -- Minimum 1 day charge even for same-day discharge
    v_days_stayed       := GREATEST(1, DATE_PART('day', NOW() - v_admit_date)::INT);
    o_total_room_charge := v_days_stayed * v_daily_rate;

    -- ── Step 3: Get the invoice for this admission ────────────────────────────
    SELECT invoice_id, total_amount INTO o_invoice_id, v_current_total
    FROM invoices
    WHERE admission_id = p_admission_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DISCHARGE_FAILED: No invoice found for Admission ID %.', p_admission_id;
    END IF;

    -- ── Step 4: Add room charge as a line item ────────────────────────────────
    INSERT INTO invoice_items (invoice_id, description, quantity, unit_price)
    VALUES (
        o_invoice_id,
        FORMAT('Room charge — %s (%s day(s) × PKR %s/day)',
               v_room_number, v_days_stayed, v_daily_rate),
        v_days_stayed,
        v_daily_rate
    );

    -- ── Step 5: Update invoice total ──────────────────────────────────────────
    UPDATE invoices
    SET total_amount = v_current_total + o_total_room_charge
    WHERE invoice_id = o_invoice_id;

    -- ── Step 6: Mark admission as discharged ──────────────────────────────────
    UPDATE admissions
    SET
        status         = 'discharged',
        discharge_date = NOW()
    WHERE admission_id = p_admission_id;

    -- ── Step 7: Free the room ─────────────────────────────────────────────────
    UPDATE rooms
    SET is_available = TRUE
    WHERE room_id = v_room_id;

    -- ── Step 8: Audit log ─────────────────────────────────────────────────────
    INSERT INTO audit_log (user_id, action, target_table, target_id, new_data)
    VALUES (
        p_discharged_by,
        'PATIENT_DISCHARGED',
        'admissions',
        p_admission_id,
        jsonb_build_object(
            'patient_id',        v_patient_id,
            'patient_name',      v_patient_name,
            'room_id',           v_room_id,
            'room_number',       v_room_number,
            'days_stayed',       v_days_stayed,
            'room_charge',       o_total_room_charge,
            'invoice_id',        o_invoice_id,
            'discharge_time',    NOW()
        )
    );

    RAISE NOTICE 'SUCCESS: Patient "%" discharged from Room %. Days: %. Room charge: PKR %. Invoice ID: %.',
        v_patient_name, v_room_number, v_days_stayed, o_total_room_charge, o_invoice_id;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION '%', SQLERRM;
END;
$$;

COMMENT ON PROCEDURE sp_discharge_patient IS
'Atomically discharges a patient: calculates room charges, adds line item to invoice, updates totals, marks room available, and logs the action.';


-- =============================================================================
-- PROCEDURE 3 — sp_record_payment
-- Records a payment against an invoice.
--
-- Steps (all atomic):
--   1. Validate invoice exists and is not fully paid
--   2. Validate payment does not exceed outstanding balance
--   3. Insert payment record
--   4. Update invoice paid_amount
--   5. Update invoice status (unpaid → partial → paid)
--   6. Write to audit_log
--
-- Returns: payment_id, new_paid_amount, new_status (via OUT parameters)
-- =============================================================================

CREATE OR REPLACE PROCEDURE sp_record_payment(
    IN  p_invoice_id        INT,
    IN  p_amount            NUMERIC,
    IN  p_payment_method    pay_method,
    IN  p_received_by       INT,
    IN  p_notes             TEXT,
    OUT o_payment_id        INT,
    OUT o_new_paid_amount   NUMERIC,
    OUT o_new_status        invoice_status
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_patient_id        INT;
    v_total_amount      NUMERIC;
    v_current_paid      NUMERIC;
    v_outstanding       NUMERIC;
    v_patient_name      VARCHAR;
BEGIN
    -- ── Step 1: Validate invoice and check it is not already paid ─────────────
    SELECT
        i.patient_id, i.total_amount, i.paid_amount, p.full_name
    INTO
        v_patient_id, v_total_amount, v_current_paid, v_patient_name
    FROM invoices i
    JOIN patients p ON p.patient_id = i.patient_id
    WHERE i.invoice_id = p_invoice_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_FAILED: Invoice ID % does not exist.', p_invoice_id;
    END IF;

    IF v_current_paid >= v_total_amount THEN
        RAISE EXCEPTION 'PAYMENT_FAILED: Invoice ID % is already fully paid.', p_invoice_id;
    END IF;

    -- ── Step 2: Validate amount does not exceed outstanding balance ───────────
    v_outstanding := v_total_amount - v_current_paid;

    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'PAYMENT_FAILED: Payment amount must be greater than zero.';
    END IF;

    IF p_amount > v_outstanding THEN
        RAISE EXCEPTION 'PAYMENT_FAILED: Payment PKR % exceeds outstanding balance of PKR % on Invoice %.', 
            p_amount, v_outstanding, p_invoice_id;
    END IF;

    -- ── Step 3: Insert payment record ─────────────────────────────────────────
    INSERT INTO payments (invoice_id, amount, payment_method, received_by, notes)
    VALUES (p_invoice_id, p_amount, p_payment_method, p_received_by, p_notes)
    RETURNING payment_id INTO o_payment_id;

    -- ── Step 4: Update invoice paid_amount ────────────────────────────────────
    o_new_paid_amount := v_current_paid + p_amount;

    -- ── Step 5: Calculate and update new status ───────────────────────────────
    IF o_new_paid_amount >= v_total_amount THEN
        o_new_status := 'paid';
    ELSIF o_new_paid_amount > 0 THEN
        o_new_status := 'partial';
    ELSE
        o_new_status := 'unpaid';
    END IF;

    UPDATE invoices
    SET
        paid_amount = o_new_paid_amount,
        status      = o_new_status
    WHERE invoice_id = p_invoice_id;

    -- ── Step 6: Audit log ─────────────────────────────────────────────────────
    INSERT INTO audit_log (user_id, action, target_table, target_id, new_data)
    VALUES (
        p_received_by,
        'PAYMENT_RECEIVED',
        'payments',
        o_payment_id,
        jsonb_build_object(
            'invoice_id',       p_invoice_id,
            'patient_id',       v_patient_id,
            'patient_name',     v_patient_name,
            'amount_paid',      p_amount,
            'payment_method',   p_payment_method,
            'new_paid_total',   o_new_paid_amount,
            'new_status',       o_new_status,
            'outstanding_left', v_total_amount - o_new_paid_amount
        )
    );

    RAISE NOTICE 'SUCCESS: Payment of PKR % recorded for Invoice % (Patient: %). Status: %. Outstanding: PKR %.',
        p_amount, p_invoice_id, v_patient_name, o_new_status,
        (v_total_amount - o_new_paid_amount);

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION '%', SQLERRM;
END;
$$;

COMMENT ON PROCEDURE sp_record_payment IS
'Atomically records a payment: validates invoice and amount, inserts payment, updates invoice paid_amount and status, and logs the action.';


-- =============================================================================
-- PROCEDURE 4 — sp_book_appointment
-- Books an OPD appointment after checking slot availability.
--
-- Steps (all atomic):
--   1. Validate patient exists
--   2. Validate doctor is active
--   3. Check the time slot is free for that doctor
--   4. Validate appointment date is not in the past
--   5. Insert appointment
--   6. Create OPD invoice with consultation fee from services_catalog
--   7. Write to audit_log
--
-- Returns: appointment_id, invoice_id (via OUT parameters)
-- =============================================================================

CREATE OR REPLACE PROCEDURE sp_book_appointment(
    IN  p_patient_id        INT,
    IN  p_doctor_id         INT,
    IN  p_appointment_date  DATE,
    IN  p_appointment_time  TIME,
    IN  p_notes             TEXT,
    IN  p_created_by        INT,
    OUT o_appointment_id    INT,
    OUT o_invoice_id        INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_patient_name      VARCHAR;
    v_doctor_name       VARCHAR;
    v_slot_taken        INT;
    v_consult_fee       NUMERIC := 0.00;
    v_service_id        INT;
BEGIN
    -- ── Step 1: Validate patient ──────────────────────────────────────────────
    SELECT full_name INTO v_patient_name
    FROM patients
    WHERE patient_id = p_patient_id AND is_deleted = FALSE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'BOOKING_FAILED: Patient ID % not found or deleted.', p_patient_id;
    END IF;

    -- ── Step 2: Validate doctor ───────────────────────────────────────────────
    SELECT full_name INTO v_doctor_name
    FROM doctors
    WHERE doctor_id = p_doctor_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'BOOKING_FAILED: Doctor ID % not found or inactive.', p_doctor_id;
    END IF;

    -- ── Step 3: Check slot availability ───────────────────────────────────────
    SELECT COUNT(*) INTO v_slot_taken
    FROM appointments
    WHERE doctor_id        = p_doctor_id
      AND appointment_date = p_appointment_date
      AND appointment_time = p_appointment_time
      AND status NOT IN ('cancelled');

    IF v_slot_taken > 0 THEN
        RAISE EXCEPTION 'BOOKING_FAILED: Dr. % already has an appointment at % on %. Please choose another slot.',
            v_doctor_name, p_appointment_time, p_appointment_date;
    END IF;

    -- ── Step 4: Validate date is not in the past ──────────────────────────────
    IF p_appointment_date < CURRENT_DATE THEN
        RAISE EXCEPTION 'BOOKING_FAILED: Cannot book an appointment in the past (%).', p_appointment_date;
    END IF;

    -- ── Step 5: Insert appointment ────────────────────────────────────────────
    INSERT INTO appointments (
        patient_id, doctor_id,
        appointment_date, appointment_time,
        status, notes, created_by
    )
    VALUES (
        p_patient_id, p_doctor_id,
        p_appointment_date, p_appointment_time,
        'pending', p_notes, p_created_by
    )
    RETURNING appointment_id INTO o_appointment_id;

    -- ── Step 6: Create OPD invoice ────────────────────────────────────────────
    -- Look up standard consultation fee from services catalog if it exists
    SELECT service_id, standard_price
    INTO v_service_id, v_consult_fee
    FROM services_catalog
    WHERE service_name ILIKE '%consultation%'
      AND is_active = TRUE
    LIMIT 1;

    INSERT INTO invoices (
        patient_id, appointment_id,
        total_amount, paid_amount, status,
        generated_by
    )
    VALUES (
        p_patient_id, o_appointment_id,
        v_consult_fee, 0.00, 'unpaid',
        p_created_by
    )
    RETURNING invoice_id INTO o_invoice_id;

    -- If we found a consult fee, add it as a line item too
    IF v_consult_fee > 0 THEN
        INSERT INTO invoice_items (invoice_id, description, quantity, unit_price)
        VALUES (o_invoice_id, 'OPD Consultation Fee', 1, v_consult_fee);
    END IF;

    -- ── Step 7: Audit log ─────────────────────────────────────────────────────
    INSERT INTO audit_log (user_id, action, target_table, target_id, new_data)
    VALUES (
        p_created_by,
        'APPOINTMENT_BOOKED',
        'appointments',
        o_appointment_id,
        jsonb_build_object(
            'patient_id',   p_patient_id,
            'patient_name', v_patient_name,
            'doctor_id',    p_doctor_id,
            'doctor_name',  v_doctor_name,
            'date',         p_appointment_date,
            'time',         p_appointment_time,
            'invoice_id',   o_invoice_id,
            'consult_fee',  v_consult_fee
        )
    );

    RAISE NOTICE 'SUCCESS: Appointment booked for "%" with Dr. % on % at %. Appointment ID: %, Invoice ID: %.',
        v_patient_name, v_doctor_name,
        p_appointment_date, p_appointment_time,
        o_appointment_id, o_invoice_id;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION '%', SQLERRM;
END;
$$;

COMMENT ON PROCEDURE sp_book_appointment IS
'Atomically books an OPD appointment: validates patient and doctor, checks slot, creates appointment, generates OPD invoice with consultation fee, and logs the action.';


-- =============================================================================
-- PROCEDURE 5 — sp_add_invoice_item
-- Adds a billable service item to an existing open invoice.
--
-- Steps (all atomic):
--   1. Validate invoice exists and is not fully paid
--   2. Insert the line item
--   3. Update invoice total_amount
--   4. Recalculate invoice status
--   5. Write to audit_log
--
-- Returns: item_id, new_invoice_total (via OUT parameters)
-- =============================================================================

CREATE OR REPLACE PROCEDURE sp_add_invoice_item(
    IN  p_invoice_id        INT,
    IN  p_description       VARCHAR,
    IN  p_quantity          INT,
    IN  p_unit_price        NUMERIC,
    IN  p_added_by          INT,
    OUT o_item_id           INT,
    OUT o_new_invoice_total NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_total NUMERIC;
    v_paid_amount   NUMERIC;
    v_item_total    NUMERIC;
    v_new_status    invoice_status;
BEGIN
    -- ── Step 1: Validate invoice is open ──────────────────────────────────────
    SELECT total_amount, paid_amount INTO v_current_total, v_paid_amount
    FROM invoices
    WHERE invoice_id = p_invoice_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ADD_ITEM_FAILED: Invoice ID % does not exist.', p_invoice_id;
    END IF;

    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'ADD_ITEM_FAILED: Quantity must be greater than zero.';
    END IF;

    IF p_unit_price < 0 THEN
        RAISE EXCEPTION 'ADD_ITEM_FAILED: Unit price cannot be negative.';
    END IF;

    -- ── Step 2: Insert line item ──────────────────────────────────────────────
    INSERT INTO invoice_items (invoice_id, description, quantity, unit_price)
    VALUES (p_invoice_id, p_description, p_quantity, p_unit_price)
    RETURNING item_id INTO o_item_id;

    -- ── Step 3: Update invoice total ──────────────────────────────────────────
    v_item_total          := p_quantity * p_unit_price;
    o_new_invoice_total   := v_current_total + v_item_total;

    -- ── Step 4: Recalculate status ────────────────────────────────────────────
    IF v_paid_amount >= o_new_invoice_total THEN
        v_new_status := 'paid';
    ELSIF v_paid_amount > 0 THEN
        v_new_status := 'partial';
    ELSE
        v_new_status := 'unpaid';
    END IF;

    UPDATE invoices
    SET total_amount = o_new_invoice_total,
        status       = v_new_status
    WHERE invoice_id = p_invoice_id;

    -- ── Step 5: Audit log ─────────────────────────────────────────────────────
    INSERT INTO audit_log (user_id, action, target_table, target_id, new_data)
    VALUES (
        p_added_by,
        'INVOICE_ITEM_ADDED',
        'invoice_items',
        o_item_id,
        jsonb_build_object(
            'invoice_id',       p_invoice_id,
            'description',      p_description,
            'quantity',         p_quantity,
            'unit_price',       p_unit_price,
            'item_total',       v_item_total,
            'new_invoice_total', o_new_invoice_total
        )
    );

    RAISE NOTICE 'SUCCESS: Added "%" (qty: %, PKR % each) to Invoice %. New total: PKR %.',
        p_description, p_quantity, p_unit_price, p_invoice_id, o_new_invoice_total;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION '%', SQLERRM;
END;
$$;

COMMENT ON PROCEDURE sp_add_invoice_item IS
'Atomically adds a billable line item to an invoice and recalculates the invoice total and status.';


-- =============================================================================
-- PROCEDURE 6 — sp_register_patient
-- Registers a new patient with auto-generated patient_code.
--
-- Steps (all atomic):
--   1. Validate required fields
--   2. Auto-generate patient_code (IN-xxx or OPD-xxx)
--   3. Insert patient record
--   4. Write to audit_log
--
-- Returns: patient_id, patient_code (via OUT parameters)
-- =============================================================================

CREATE OR REPLACE PROCEDURE sp_register_patient(
    IN  p_full_name                 VARCHAR,
    IN  p_dob                       DATE,
    IN  p_gender                    gender_type,
    IN  p_blood_group               blood_group,
    IN  p_phone                     VARCHAR,
    IN  p_address                   TEXT,
    IN  p_emergency_contact_name    VARCHAR,
    IN  p_emergency_contact_phone   VARCHAR,
    IN  p_patient_type              VARCHAR,   -- 'IN' or 'OPD'
    IN  p_created_by                INT,
    OUT o_patient_id                INT,
    OUT o_patient_code              VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_next_seq  INT;
BEGIN
    -- ── Step 1: Validate required fields ──────────────────────────────────────
    IF p_full_name IS NULL OR char_length(TRIM(p_full_name)) < 2 THEN
        RAISE EXCEPTION 'REGISTER_FAILED: Patient full name is required (min 2 characters).';
    END IF;

    IF p_patient_type NOT IN ('IN', 'OPD') THEN
        RAISE EXCEPTION 'REGISTER_FAILED: patient_type must be "IN" (indoor) or "OPD" (outpatient).';
    END IF;

    -- ── Step 2: Auto-generate patient_code ────────────────────────────────────
    -- Count existing codes of this type to get next sequence number
    SELECT COUNT(*) + 1 INTO v_next_seq
    FROM patients
    WHERE patient_code LIKE p_patient_type || '-%';

    o_patient_code := FORMAT('%s-%s', p_patient_type, LPAD(v_next_seq::TEXT, 4, '0'));

    -- Ensure uniqueness (edge case: if code already exists, increment)
    WHILE EXISTS (SELECT 1 FROM patients WHERE patient_code = o_patient_code) LOOP
        v_next_seq     := v_next_seq + 1;
        o_patient_code := FORMAT('%s-%s', p_patient_type, LPAD(v_next_seq::TEXT, 4, '0'));
    END LOOP;

    -- ── Step 3: Insert patient ─────────────────────────────────────────────────
    INSERT INTO patients (
        patient_code, full_name, dob, gender, blood_group,
        phone, address,
        emergency_contact_name, emergency_contact_phone,
        created_by
    )
    VALUES (
        o_patient_code, p_full_name, p_dob, p_gender, p_blood_group,
        p_phone, p_address,
        p_emergency_contact_name, p_emergency_contact_phone,
        p_created_by
    )
    RETURNING patient_id INTO o_patient_id;

    -- ── Step 4: Audit log ─────────────────────────────────────────────────────
    INSERT INTO audit_log (user_id, action, target_table, target_id, new_data)
    VALUES (
        p_created_by,
        'PATIENT_REGISTERED',
        'patients',
        o_patient_id,
        jsonb_build_object(
            'patient_code', o_patient_code,
            'full_name',    p_full_name,
            'gender',       p_gender,
            'phone',        p_phone
        )
    );

    RAISE NOTICE 'SUCCESS: Patient "%" registered with code %. ID: %.',
        p_full_name, o_patient_code, o_patient_id;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION '%', SQLERRM;
END;
$$;

COMMENT ON PROCEDURE sp_register_patient IS
'Registers a new patient with an auto-generated patient code (IN-xxxx or OPD-xxxx) and writes an audit entry.';


-- =============================================================================
-- VERIFICATION
-- List all stored procedures in the hsk schema.
-- =============================================================================

SELECT
    routine_name        AS procedure_name,
    routine_type        AS type,
    external_language   AS language
FROM information_schema.routines
WHERE routine_schema = 'hsk'
  AND routine_type   = 'PROCEDURE'
ORDER BY routine_name;
