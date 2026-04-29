-- =============================================================================
-- HSK BONE CARE — HOSPITAL MANAGEMENT SYSTEM
-- Layer 2: Index Strategy (PostgreSQL)
-- Author  : Muhammad Arham (23-CSE-13)
-- Course  : Database Management System — 6th Semester, DUET
-- Teacher : Engr. Motia Rani
-- Run AFTER: hsk_layer1_schema.sql
-- =============================================================================

SET search_path TO hsk;

-- =============================================================================
-- WHY INDEXES?
-- Without indexes, PostgreSQL does a sequential scan — it reads every row in
-- the table for every query. On a hospital DB with 10,000+ patient records and
-- years of appointments, that becomes unacceptably slow.
--
-- PostgreSQL automatically creates indexes for PRIMARY KEY and UNIQUE
-- constraints. Everything below is ADDITIONAL indexing for query performance.
--
-- Index types used:
--   BTREE  — default, best for equality (=) and range (<, >, BETWEEN)
--   GIN    — best for JSONB columns (full document search)
--   BRIN   — best for naturally ordered timestamp columns (very low overhead)
-- =============================================================================


-- =============================================================================
-- SECTION 1 — FOREIGN KEY INDEXES
-- PostgreSQL does NOT auto-index FK columns. Without these, every JOIN and
-- ON DELETE check does a full sequential scan on the child table.
-- Rule: every FK column gets its own index.
-- =============================================================================

-- users
CREATE INDEX idx_users_created_by
    ON users(created_by);

-- doctors
CREATE INDEX idx_doctors_user_id
    ON doctors(user_id);

-- patients
CREATE INDEX idx_patients_created_by
    ON patients(created_by);

-- appointments
CREATE INDEX idx_appointments_patient_id
    ON appointments(patient_id);

CREATE INDEX idx_appointments_doctor_id
    ON appointments(doctor_id);

CREATE INDEX idx_appointments_created_by
    ON appointments(created_by);

-- admissions
CREATE INDEX idx_admissions_patient_id
    ON admissions(patient_id);

CREATE INDEX idx_admissions_doctor_id
    ON admissions(doctor_id);

CREATE INDEX idx_admissions_room_id
    ON admissions(room_id);

CREATE INDEX idx_admissions_created_by
    ON admissions(created_by);

-- medical_records
CREATE INDEX idx_medical_records_patient_id
    ON medical_records(patient_id);

CREATE INDEX idx_medical_records_admission_id
    ON medical_records(admission_id);

CREATE INDEX idx_medical_records_appointment_id
    ON medical_records(appointment_id);

CREATE INDEX idx_medical_records_uploaded_by
    ON medical_records(uploaded_by);

-- invoices
CREATE INDEX idx_invoices_patient_id
    ON invoices(patient_id);

CREATE INDEX idx_invoices_admission_id
    ON invoices(admission_id);

CREATE INDEX idx_invoices_appointment_id
    ON invoices(appointment_id);

CREATE INDEX idx_invoices_generated_by
    ON invoices(generated_by);

-- invoice_items
CREATE INDEX idx_invoice_items_invoice_id
    ON invoice_items(invoice_id);

-- payments
CREATE INDEX idx_payments_invoice_id
    ON payments(invoice_id);

CREATE INDEX idx_payments_received_by
    ON payments(received_by);

-- audit_log
CREATE INDEX idx_audit_log_user_id
    ON audit_log(user_id);


-- =============================================================================
-- SECTION 2 — COMPOSITE INDEXES
-- Cover the most common multi-column query patterns in a hospital system.
-- Order of columns matters: most selective / most filtered column goes first.
-- =============================================================================

-- ── 2a. Doctor's daily schedule ──────────────────────────────────────────────
-- Query: "Show all appointments for Dr. X on date Y"
-- Used by: OPD dashboard, receptionist booking screen
CREATE INDEX idx_appt_doctor_date
    ON appointments(doctor_id, appointment_date);

-- ── 2b. Doctor's schedule with time (slot availability check) ────────────────
-- Query: "Is Dr. X free at 10:00 AM on date Y?" (before booking)
-- Used by: appointment booking validation
CREATE INDEX idx_appt_doctor_date_time
    ON appointments(doctor_id, appointment_date, appointment_time);

-- ── 2c. Patient appointment history ──────────────────────────────────────────
-- Query: "All appointments for patient X, newest first"
-- Used by: patient profile page, medical history view
CREATE INDEX idx_appt_patient_date
    ON appointments(patient_id, appointment_date DESC);

-- ── 2d. Appointments by status ────────────────────────────────────────────────
-- Query: "All pending appointments today"
-- Used by: dashboard queue, receptionist morning workflow
CREATE INDEX idx_appt_status_date
    ON appointments(status, appointment_date);

-- ── 2e. Admissions by doctor ──────────────────────────────────────────────────
-- Query: "All patients currently under Dr. X's care"
-- Used by: doctor's ward round view
CREATE INDEX idx_admissions_doctor_status
    ON admissions(doctor_id, status);

-- ── 2f. Invoice lookup by patient + status ───────────────────────────────────
-- Query: "All unpaid invoices for patient X"
-- Used by: billing desk, outstanding dues report
CREATE INDEX idx_invoices_patient_status
    ON invoices(patient_id, status);

-- ── 2g. Payments by date range ───────────────────────────────────────────────
-- Query: "Total payments received today / this week"
-- Used by: daily revenue report, cashier end-of-day summary
CREATE INDEX idx_payments_date_method
    ON payments(paid_at DESC, payment_method);

-- ── 2h. Audit log by table + action ──────────────────────────────────────────
-- Query: "All DELETE actions on the patients table this month"
-- Used by: admin audit review screen
CREATE INDEX idx_audit_table_action
    ON audit_log(target_table, action, logged_at DESC);


-- =============================================================================
-- SECTION 3 — PARTIAL INDEXES
-- Index only a subset of rows. Smaller, faster, and directly maps to the
-- most common operational queries (which always filter on status).
-- =============================================================================

-- ── 3a. Only currently admitted patients ─────────────────────────────────────
-- Full index on admissions would include years of discharged records.
-- This index covers only the handful of patients admitted right now.
-- Query: "Who is currently in the hospital?" (used constantly)
CREATE INDEX idx_active_admissions
    ON admissions(patient_id, room_id)
    WHERE status = 'admitted';

-- ── 3b. Only pending/confirmed appointments ───────────────────────────────────
-- Completed and cancelled appointments are historical — rarely queried live.
-- This index covers only the actionable queue.
CREATE INDEX idx_open_appointments
    ON appointments(appointment_date, doctor_id)
    WHERE status IN ('pending', 'confirmed');

-- ── 3c. Only unpaid or partial invoices ──────────────────────────────────────
-- Paid invoices are archived data. The billing desk only works on open ones.
CREATE INDEX idx_open_invoices
    ON invoices(patient_id, generated_at DESC)
    WHERE status IN ('unpaid', 'partial');

-- ── 3d. Only available rooms ─────────────────────────────────────────────────
-- When admitting a patient, we only query available rooms.
-- No point scanning rooms that are already occupied.
CREATE INDEX idx_available_rooms
    ON rooms(room_type, daily_rate)
    WHERE is_available = TRUE;

-- ── 3e. Only active doctors ───────────────────────────────────────────────────
-- Inactive/archived doctors should never appear in booking dropdowns.
CREATE INDEX idx_active_doctors
    ON doctors(specialization, full_name)
    WHERE is_active = TRUE;

-- ── 3f. Only active patients (not soft-deleted) ───────────────────────────────
-- Soft-deleted patients are excluded from all search results.
CREATE INDEX idx_active_patients
    ON patients(full_name, created_at DESC)
    WHERE is_deleted = FALSE;


-- =============================================================================
-- SECTION 4 — TEXT SEARCH INDEXES
-- Hospital staff search patients and doctors by name constantly.
-- pg_trgm enables fast ILIKE '%search%' queries without full table scans.
-- =============================================================================

-- Enable the trigram extension (run once per cluster)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ── 4a. Patient name search ──────────────────────────────────────────────────
-- Enables: WHERE full_name ILIKE '%arham%' to use index instead of seq scan
CREATE INDEX idx_patients_name_trgm
    ON patients USING gin(full_name gin_trgm_ops)
    WHERE is_deleted = FALSE;

-- ── 4b. Doctor name search ───────────────────────────────────────────────────
CREATE INDEX idx_doctors_name_trgm
    ON doctors USING gin(full_name gin_trgm_ops)
    WHERE is_active = TRUE;

-- ── 4c. Doctor specialization search ─────────────────────────────────────────
-- Enables: WHERE specialization ILIKE '%ortho%'
CREATE INDEX idx_doctors_spec_trgm
    ON doctors USING gin(specialization gin_trgm_ops);


-- =============================================================================
-- SECTION 5 — TIMESTAMP INDEXES (BRIN)
-- BRIN (Block Range Index) is ideal for append-only timestamp columns.
-- Extremely small index size — perfect for audit_log and payments
-- which will have millions of rows over time.
-- =============================================================================

-- ── 5a. Audit log time range queries ─────────────────────────────────────────
-- Query: "All actions logged between Jan 1 and Jan 31"
CREATE INDEX idx_audit_logged_at_brin
    ON audit_log USING brin(logged_at);

-- ── 5b. Payments time range queries ──────────────────────────────────────────
-- Query: "All payments received this month"
CREATE INDEX idx_payments_paid_at_brin
    ON payments USING brin(paid_at);

-- ── 5c. Admissions time range queries ────────────────────────────────────────
-- Query: "All admissions in the last 6 months"
CREATE INDEX idx_admissions_date_brin
    ON admissions USING brin(admission_date);


-- =============================================================================
-- SECTION 6 — JSONB INDEX (Audit Log)
-- The audit_log stores old_data and new_data as JSONB.
-- GIN index allows querying inside the JSON document efficiently.
-- =============================================================================

-- ── 6a. Search inside old/new snapshots ──────────────────────────────────────
-- Query: "Find all audit entries where the old data had status = 'admitted'"
-- Example: SELECT * FROM audit_log WHERE old_data @> '{"status": "admitted"}';
CREATE INDEX idx_audit_old_data_gin
    ON audit_log USING gin(old_data);

CREATE INDEX idx_audit_new_data_gin
    ON audit_log USING gin(new_data);


-- =============================================================================
-- VERIFICATION
-- Lists all indexes created in the hsk schema with their type and table.
-- =============================================================================

SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'hsk'
  AND indexname NOT LIKE '%_pkey'    -- exclude auto-created PK indexes
  AND indexname NOT LIKE '%_key'     -- exclude auto-created UNIQUE indexes
ORDER BY tablename, indexname;
