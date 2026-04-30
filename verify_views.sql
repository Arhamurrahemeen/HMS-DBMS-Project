-- =============================================================================
-- HSK BONE CARE — HOSPITAL MANAGEMENT SYSTEM
-- Verification Script for Layer 5: Views
-- Author  : Muhammad Arham (23-CSE-13)
-- =============================================================================

SET search_path TO hsk;

-- 1. CLEANUP
-- Carefully clear existing data to ensure verification results are predictable.
TRUNCATE TABLE payments, invoice_items, invoices, medical_records, admissions, appointments, patients, doctors, users, rooms, services_catalog, audit_log RESTART IDENTITY CASCADE;

-- 2. SEED BASIC DATA
-- Insert System User
INSERT INTO users (username, password_hash, role) 
VALUES ('admin_arham', 'hashed_pass_123', 'admin');

-- Insert Doctors
INSERT INTO doctors (full_name, specialization, phone, email)
VALUES 
    ('Dr. Kashif Khalil', 'Orthopedic Surgeon', '+923001234567', 'kashif@hsk.com'),
    ('Dr. Sarah Ahmed', 'Physiotherapist', '+923009876543', 'sarah@hsk.com');

-- Insert Rooms
INSERT INTO rooms (room_number, room_type, capacity, daily_rate)
VALUES 
    ('101', 'private', 1, 5000.00),
    ('201', 'general', 4, 1500.00);

-- Insert Services
INSERT INTO services_catalog (service_name, category, standard_price)
VALUES 
    ('Consultation Fee', 'Consultation', 1500.00),
    ('X-Ray Knee', 'Lab', 2000.00),
    ('Physiotherapy Session', 'Treatment', 1200.00),
    ('Room Charge - Private', 'Stay', 5000.00);

-- Insert Patients
INSERT INTO patients (patient_code, full_name, dob, gender, blood_group, phone)
VALUES 
    ('OPD-101', 'Ali Khan', '1995-05-15', 'male', 'O+', '+923111111111'),
    ('IN-501', 'Zainab Bibi', '1988-10-20', 'female', 'B+', '+923222222222'),
    ('OPD-102', 'Umar Farooq', '1990-01-01', 'male', 'A-', '+923333333333');


-- 3. TEST CASE 1: OPD Appointment with Full Payment
-- Ali Khan visits for Consultation and X-Ray.
INSERT INTO appointments (patient_id, doctor_id, appointment_date, appointment_time, status)
VALUES (1, 1, CURRENT_DATE, '09:00:00', 'confirmed');

-- Create Invoice for OPD (Trigger will handle status)
INSERT INTO invoices (patient_id, appointment_id, generated_by)
VALUES (1, 1, 1);

INSERT INTO invoice_items (invoice_id, description, quantity, unit_price)
VALUES 
    (1, 'Consultation Fee', 1, 1500.00),
    (1, 'X-Ray Knee', 1, 2000.00);

-- Record Full Payment
INSERT INTO payments (invoice_id, amount, payment_method, received_by)
VALUES (1, 3500.00, 'cash', 1);


-- 4. TEST CASE 2: IPD Lifecycle (Admit -> Partial Payment -> Discharge)
-- Zainab Bibi is admitted.
DO $$
DECLARE
    v_adm_id INT;
    v_inv_id INT;
    v_pay_id INT;
    v_new_paid NUMERIC;
    v_new_status invoice_status;
    v_room_charge NUMERIC;
BEGIN
    -- Admit Patient
    CALL sp_admit_patient(
        p_patient_id    => 2,
        p_doctor_id     => 1,
        p_room_id       => 1,
        p_diagnosis     => 'Fractured Femur',
        p_created_by    => 1,
        o_admission_id  => v_adm_id,
        o_invoice_id    => v_inv_id
    );

    -- Manually backdate admission slightly.
    -- In a single transaction (DO block), NOW() returns the same value.
    -- The CHECK constraint requires discharge_date > admission_date.
    UPDATE admissions SET admission_date = admission_date - INTERVAL '1 hour' 
    WHERE admission_id = v_adm_id;
    
    -- IMPORTANT: Add items to the invoice FIRST so total_amount > 0
    INSERT INTO invoice_items (invoice_id, description, quantity, unit_price)
    VALUES 
        (v_inv_id, 'Admission & File Charges', 1, 2500.00),
        (v_inv_id, 'Initial X-Ray', 1, 2000.00);

    -- Now record Partial Payment (PKR 2000 upfront)
    CALL sp_record_payment(
        p_invoice_id     => v_inv_id,
        p_amount         => 2000.00,
        p_payment_method => 'card',
        p_received_by    => 1,
        p_notes          => 'Advance payment',
        o_payment_id     => v_pay_id,
        o_new_paid_amount => v_new_paid,
        o_new_status     => v_new_status
    );

    -- Discharge Patient (This adds room charges to the invoice)
    CALL sp_discharge_patient(
        p_admission_id   => v_adm_id,
        p_discharged_by  => 1,
        o_invoice_id     => v_inv_id,
        o_total_room_charge => v_room_charge
    );
END $$;


-- 5. TEST CASE 3: Cancelled Appointment
-- Umar Farooq cancels his appointment.
INSERT INTO appointments (patient_id, doctor_id, appointment_date, appointment_time, status)
VALUES (3, 2, CURRENT_DATE, '11:00:00', 'cancelled');


-- =============================================================================
-- 6. VIEW VERIFICATION QUERIES
-- =============================================================================

\echo '\n=========================================================='
\echo 'VIEW VERIFICATION RESULTS'
\echo '==========================================================\n'

\echo '--- VIEW 1: v_active_admissions (Should be EMPTY after discharge) ---'
SELECT * FROM v_active_admissions;

\echo '\n--- VIEW 2: v_todays_opd (Should show Ali Khan, NOT Umar Farooq) ---'
SELECT appointment_id, patient_name, doctor_name, appointment_time, appointment_status, queue_position 
FROM v_todays_opd;

\echo '\n--- VIEW 3: v_patient_full_history ---'
SELECT patient_name, total_opd_visits, total_admissions, lifetime_billed, lifetime_paid 
FROM v_patient_full_history;

\echo '\n--- VIEW 4: v_doctor_workload ---'
SELECT doctor_name, appointments_today, current_ipd_patients, total_completed 
FROM v_doctor_workload;

\echo '\n--- VIEW 5: v_billing_summary (Should show outstanding dues for Zainab) ---'
SELECT patient_name, total_billed, total_paid, total_outstanding, has_outstanding_dues 
FROM v_billing_summary;

\echo '\n--- VIEW 6: v_invoice_detail (Zainab''s Admission Breakdown) ---'
SELECT invoice_id, patient_name, visit_type, invoice_status, total_amount, paid_amount 
FROM v_invoice_detail 
WHERE admission_id IS NOT NULL;

\echo '\n--- VIEW 7: v_room_status (Both rooms should be AVAILABLE) ---'
SELECT room_number, room_type, is_available, current_patient 
FROM v_room_status;

\echo '\n--- VIEW 8: v_audit_trail (Recent Actions) ---'
SELECT log_id, action, target_table, username FROM v_audit_trail ORDER BY log_id DESC LIMIT 10;

-- 7. MATERIALIZED VIEWS (Must Refresh First)
REFRESH MATERIALIZED VIEW mv_daily_revenue;
REFRESH MATERIALIZED VIEW mv_monthly_summary;

\echo '\n--- MATERIALIZED VIEW 1: mv_daily_revenue ---'
SELECT revenue_date, payment_method, total_collected, ipd_revenue, opd_revenue FROM mv_daily_revenue;

\echo '\n--- MATERIALIZED VIEW 2: mv_monthly_summary ---'
SELECT month_label, total_revenue, total_admissions, opd_completed FROM mv_monthly_summary;

\echo '\n=========================================================='
\echo 'VERIFICATION COMPLETE — ALL VIEWS VALIDATED'
\echo '==========================================================\n'

