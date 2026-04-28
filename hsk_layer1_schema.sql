-- =============================================================================
-- HSK BONE CARE — HOSPITAL MANAGEMENT SYSTEM
-- Layer 1: Schema & DDL (PostgreSQL)
-- Author  : Muhammad Arham (23-CSE-13)
-- Course  : Database Management System — 6th Semester, DUET
-- Teacher : Engr. Motia Rani
-- =============================================================================

-- Drop schema cleanly if re-running (development convenience)
DROP SCHEMA IF EXISTS hsk CASCADE;
CREATE SCHEMA hsk;
SET search_path TO hsk;

-- Required for EXCLUDE constraints using GIST with standard types like INTEGER
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- =============================================================================
-- SECTION 0 — CUSTOM TYPES (ENUMs)
-- Defined first; referenced by tables below.
-- =============================================================================

CREATE TYPE gender_type    AS ENUM ('male', 'female', 'other');
CREATE TYPE blood_group    AS ENUM ('A+','A-','B+','B-','AB+','AB-','O+','O-');
CREATE TYPE user_role      AS ENUM ('admin', 'receptionist', 'doctor');
CREATE TYPE room_type      AS ENUM ('general', 'private', 'icu', 'operation');
CREATE TYPE appt_status    AS ENUM ('pending', 'confirmed', 'completed', 'cancelled');
CREATE TYPE admit_status   AS ENUM ('admitted', 'discharged');
CREATE TYPE record_type    AS ENUM ('xray', 'report', 'prescription', 'other');
CREATE TYPE invoice_status AS ENUM ('unpaid', 'partial', 'paid');
CREATE TYPE pay_method     AS ENUM ('cash', 'card', 'bank_transfer', 'insurance');


-- =============================================================================
-- SECTION 1 — USERS
-- System login accounts. The first table — no FK dependencies.
-- Self-referencing FK (created_by) deferred to after table creation.
-- =============================================================================

CREATE TABLE users (
    user_id        SERIAL          PRIMARY KEY,
    username       VARCHAR(50)     NOT NULL,
    password_hash  VARCHAR(255)    NOT NULL,
    role           user_role       NOT NULL,
    is_active      BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by     INT             REFERENCES users(user_id) ON DELETE SET NULL,

    CONSTRAINT uq_username UNIQUE (username),
    CONSTRAINT chk_username_len CHECK (char_length(username) >= 3)
);

COMMENT ON TABLE  users              IS 'System login accounts for all staff roles.';
COMMENT ON COLUMN users.password_hash IS 'bcrypt hash — never store plaintext.';
COMMENT ON COLUMN users.created_by   IS 'Which admin account created this user.';


-- =============================================================================
-- SECTION 2 — DOCTORS
-- Doctor profiles. May optionally link to a users login account.
-- Depends on: users
-- =============================================================================

CREATE TABLE doctors (
    doctor_id      SERIAL          PRIMARY KEY,
    user_id        INT             UNIQUE REFERENCES users(user_id) ON DELETE SET NULL,
    full_name      VARCHAR(100)    NOT NULL,
    specialization VARCHAR(100)    NOT NULL,
    phone          VARCHAR(20),
    email          VARCHAR(150),
    image_url      VARCHAR(500),   -- Cloudinary URL
    is_active      BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_doctor_phone  UNIQUE (phone),
    CONSTRAINT uq_doctor_email  UNIQUE (email),
    CONSTRAINT chk_doctor_phone CHECK (phone ~ '^\+?[0-9\s\-]{7,20}$'),
    CONSTRAINT chk_doctor_email CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

COMMENT ON TABLE  doctors          IS 'Doctor profiles, separate from login accounts.';
COMMENT ON COLUMN doctors.user_id  IS 'Linked login account — nullable if doctor has no system access.';
COMMENT ON COLUMN doctors.image_url IS 'Cloudinary-hosted profile photo URL.';


-- =============================================================================
-- SECTION 3 — PATIENTS
-- Master patient registry. Every visit/admission references this table.
-- Depends on: users (created_by)
-- =============================================================================

CREATE TABLE patients (
    patient_id              SERIAL          PRIMARY KEY,
    patient_code            VARCHAR(20)     NOT NULL,
    full_name               VARCHAR(100)    NOT NULL,
    dob                     DATE,
    gender                  gender_type,
    blood_group             blood_group,
    phone                   VARCHAR(20),
    address                 TEXT,
    emergency_contact_name  VARCHAR(100),
    emergency_contact_phone VARCHAR(20),
    is_deleted              BOOLEAN         NOT NULL DEFAULT FALSE,  -- soft delete
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by              INT             REFERENCES users(user_id) ON DELETE SET NULL,

    CONSTRAINT uq_patient_code  UNIQUE (patient_code),
    CONSTRAINT chk_patient_dob  CHECK  (dob <= CURRENT_DATE),
    CONSTRAINT chk_patient_phone CHECK (phone IS NULL OR phone ~ '^\+?[0-9\s\-]{7,20}$'),
    CONSTRAINT chk_patient_code_format
        CHECK (patient_code ~ '^(IN|OPD)-[0-9]{3,6}$')
);

COMMENT ON TABLE  patients             IS 'Master patient registry — all visits and admissions reference this.';
COMMENT ON COLUMN patients.patient_code IS 'Auto-generated ID e.g. IN-001 (indoor) or OPD-045 (outpatient).';
COMMENT ON COLUMN patients.is_deleted   IS 'Soft delete — records are never hard-deleted for legal compliance.';


-- =============================================================================
-- SECTION 4 — ROOMS
-- Physical room and ward inventory.
-- No FK dependencies.
-- =============================================================================

CREATE TABLE rooms (
    room_id      SERIAL       PRIMARY KEY,
    room_number  VARCHAR(10)  NOT NULL,
    room_type    room_type    NOT NULL,
    capacity     INT          NOT NULL DEFAULT 1,
    daily_rate   NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    is_available BOOLEAN      NOT NULL DEFAULT TRUE,

    CONSTRAINT uq_room_number     UNIQUE  (room_number),
    CONSTRAINT chk_room_capacity  CHECK   (capacity > 0),
    CONSTRAINT chk_room_rate      CHECK   (daily_rate >= 0)
);

COMMENT ON TABLE  rooms              IS 'Physical room inventory — general, private, ICU, operation theatre.';
COMMENT ON COLUMN rooms.is_available IS 'Managed automatically by triggers on admission and discharge.';


-- =============================================================================
-- SECTION 5 — APPOINTMENTS (OPD)
-- Outpatient visits. One slot per doctor per date+time.
-- Depends on: patients, doctors, users
-- =============================================================================

CREATE TABLE appointments (
    appointment_id   SERIAL        PRIMARY KEY,
    patient_id       INT           NOT NULL REFERENCES patients(patient_id) ON DELETE RESTRICT,
    doctor_id        INT           NOT NULL REFERENCES doctors(doctor_id)   ON DELETE RESTRICT,
    appointment_date DATE          NOT NULL,
    appointment_time TIME          NOT NULL,
    status           appt_status   NOT NULL DEFAULT 'pending',
    notes            TEXT,
    created_by       INT           REFERENCES users(user_id) ON DELETE SET NULL,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    -- A doctor cannot be double-booked at the same date + time
    CONSTRAINT uq_no_double_booking UNIQUE (doctor_id, appointment_date, appointment_time),
    -- Cannot book an appointment in the past (date only; time flexibility intentional)
    CONSTRAINT chk_appt_date CHECK (appointment_date >= CURRENT_DATE)
);

COMMENT ON TABLE appointments IS 'OPD outpatient appointment slots. Double-booking prevented at DB level.';


-- =============================================================================
-- SECTION 6 — ADMISSIONS (IPD)
-- Indoor patient stays. Links patient to a room and an attending doctor.
-- Depends on: patients, doctors, rooms, users
-- =============================================================================

CREATE TABLE admissions (
    admission_id    SERIAL        PRIMARY KEY,
    patient_id      INT           NOT NULL REFERENCES patients(patient_id)  ON DELETE RESTRICT,
    doctor_id       INT           NOT NULL REFERENCES doctors(doctor_id)    ON DELETE RESTRICT,
    room_id         INT           NOT NULL REFERENCES rooms(room_id)        ON DELETE RESTRICT,
    admission_date  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    discharge_date  TIMESTAMPTZ,                           -- NULL = still admitted
    diagnosis       TEXT,
    status          admit_status  NOT NULL DEFAULT 'admitted',
    created_by      INT           REFERENCES users(user_id) ON DELETE SET NULL,

    -- Discharge must be after admission
    CONSTRAINT chk_discharge_after_admission
        CHECK (discharge_date IS NULL OR discharge_date > admission_date),
    -- A patient cannot be admitted twice simultaneously (one active admission only)
    CONSTRAINT chk_one_active_admission
        EXCLUDE USING gist (
            patient_id WITH =,
            tstzrange(admission_date, discharge_date, '[)') WITH &&
        )
);

COMMENT ON TABLE  admissions                IS 'IPD indoor admissions. Room freed automatically on discharge via trigger.';
COMMENT ON COLUMN admissions.discharge_date IS 'NULL means patient is currently admitted.';

-- Note: The EXCLUDE constraint above requires the btree_gist extension.
-- Run once on your PostgreSQL cluster:
-- CREATE EXTENSION IF NOT EXISTS btree_gist;


-- =============================================================================
-- SECTION 7 — MEDICAL RECORDS
-- Files and X-rays attached to a patient, optionally linked to a visit.
-- Depends on: patients, admissions, appointments, users
-- =============================================================================

CREATE TABLE medical_records (
    record_id      SERIAL        PRIMARY KEY,
    patient_id     INT           NOT NULL REFERENCES patients(patient_id)      ON DELETE RESTRICT,
    admission_id   INT           REFERENCES admissions(admission_id)           ON DELETE SET NULL,
    appointment_id INT           REFERENCES appointments(appointment_id)       ON DELETE SET NULL,
    file_url       VARCHAR(500)  NOT NULL,
    file_type      record_type   NOT NULL DEFAULT 'other',
    description    TEXT,
    uploaded_by    INT           REFERENCES users(user_id) ON DELETE SET NULL,
    uploaded_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    -- A record must link to at most one context (admission OR appointment, not both)
    CONSTRAINT chk_single_context
        CHECK (
            (admission_id IS NULL OR appointment_id IS NULL)
        ),
    CONSTRAINT chk_file_url_not_empty CHECK (char_length(file_url) > 10)
);

COMMENT ON TABLE  medical_records             IS 'X-rays and reports stored on Cloudinary, linked to patient visits.';
COMMENT ON COLUMN medical_records.file_url    IS 'Cloudinary asset URL.';
COMMENT ON COLUMN medical_records.admission_id IS 'Linked to indoor admission — mutually exclusive with appointment_id.';


-- =============================================================================
-- SECTION 8 — INVOICES
-- One invoice per appointment or admission.
-- Depends on: patients, admissions, appointments, users
-- =============================================================================

CREATE TABLE invoices (
    invoice_id    SERIAL          PRIMARY KEY,
    patient_id    INT             NOT NULL REFERENCES patients(patient_id)    ON DELETE RESTRICT,
    admission_id  INT             REFERENCES admissions(admission_id)         ON DELETE RESTRICT,
    appointment_id INT            REFERENCES appointments(appointment_id)     ON DELETE RESTRICT,
    total_amount  NUMERIC(10,2)   NOT NULL DEFAULT 0.00,
    paid_amount   NUMERIC(10,2)   NOT NULL DEFAULT 0.00,
    status        invoice_status  NOT NULL DEFAULT 'unpaid',
    generated_by  INT             REFERENCES users(user_id) ON DELETE SET NULL,
    generated_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Must link to exactly one context (admission or appointment, not both, not neither)
    CONSTRAINT chk_invoice_context
        CHECK (
            (admission_id IS NOT NULL AND appointment_id IS NULL) OR
            (appointment_id IS NOT NULL AND admission_id IS NULL)
        ),
    CONSTRAINT chk_total_amount   CHECK (total_amount >= 0),
    CONSTRAINT chk_paid_amount    CHECK (paid_amount  >= 0),
    -- Paid cannot exceed total
    CONSTRAINT chk_paid_lte_total CHECK (paid_amount  <= total_amount)
);

COMMENT ON TABLE  invoices              IS 'One invoice per OPD appointment or IPD admission.';
COMMENT ON COLUMN invoices.total_amount IS 'Auto-updated by trigger when invoice_items are inserted/updated.';
COMMENT ON COLUMN invoices.paid_amount  IS 'Auto-updated by trigger when payments are recorded.';
COMMENT ON COLUMN invoices.status       IS 'Auto-updated by trigger: unpaid → partial → paid.';


-- =============================================================================
-- SECTION 9 — INVOICE ITEMS
-- Normalized line items. Total is auto-calculated.
-- Depends on: invoices
-- =============================================================================

CREATE TABLE invoice_items (
    item_id      SERIAL          PRIMARY KEY,
    invoice_id   INT             NOT NULL REFERENCES invoices(invoice_id) ON DELETE CASCADE,
    description  VARCHAR(255)    NOT NULL,
    quantity     INT             NOT NULL DEFAULT 1,
    unit_price   NUMERIC(10,2)   NOT NULL,
    total_price  NUMERIC(10,2)   GENERATED ALWAYS AS (quantity * unit_price) STORED,

    CONSTRAINT chk_item_quantity   CHECK (quantity   > 0),
    CONSTRAINT chk_item_unit_price CHECK (unit_price >= 0),
    CONSTRAINT chk_item_desc_len   CHECK (char_length(description) >= 2)
);

COMMENT ON TABLE  invoice_items             IS 'Normalized billing line items per invoice.';
COMMENT ON COLUMN invoice_items.total_price IS 'Auto-computed column: quantity × unit_price.';


-- =============================================================================
-- SECTION 10 — PAYMENTS
-- Individual payment transactions against an invoice.
-- Depends on: invoices, users
-- =============================================================================

CREATE TABLE payments (
    payment_id     SERIAL          PRIMARY KEY,
    invoice_id     INT             NOT NULL REFERENCES invoices(invoice_id) ON DELETE RESTRICT,
    amount         NUMERIC(10,2)   NOT NULL,
    payment_method pay_method      NOT NULL DEFAULT 'cash',
    paid_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    received_by    INT             REFERENCES users(user_id) ON DELETE SET NULL,
    notes          TEXT,

    CONSTRAINT chk_payment_amount CHECK (amount > 0)
);

COMMENT ON TABLE  payments        IS 'Payment transactions. Insert here to auto-update invoice paid_amount and status.';
COMMENT ON COLUMN payments.amount IS 'Must be positive. Refunds handled as separate reversal entries.';


-- =============================================================================
-- SECTION 11 — AUDIT LOG
-- Immutable record of all sensitive system operations.
-- Depends on: users (loosely — SET NULL on delete)
-- =============================================================================

CREATE TABLE audit_log (
    log_id       BIGSERIAL     PRIMARY KEY,
    user_id      INT           REFERENCES users(user_id) ON DELETE SET NULL,
    action       VARCHAR(100)  NOT NULL,
    target_table VARCHAR(50)   NOT NULL,
    target_id    INT,
    old_data     JSONB,        -- snapshot before change
    new_data     JSONB,        -- snapshot after change
    ip_address   VARCHAR(45),  -- IPv4 or IPv6
    logged_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_action_not_empty CHECK (char_length(action) >= 3)
);

COMMENT ON TABLE  audit_log           IS 'Append-only audit trail. Never update or delete rows in this table.';
COMMENT ON COLUMN audit_log.old_data  IS 'JSONB snapshot of the row before the operation.';
COMMENT ON COLUMN audit_log.new_data  IS 'JSONB snapshot of the row after the operation.';
COMMENT ON COLUMN audit_log.log_id    IS 'BIGSERIAL — audit tables grow large; INT would overflow in production.';


-- =============================================================================
-- SECTION 12 — SERVICES CATALOG
-- Master list of hospital services with standard prices.
-- Referenced when creating invoice line items.
-- No FK dependencies.
-- =============================================================================

CREATE TABLE services_catalog (
    service_id    SERIAL          PRIMARY KEY,
    service_name  VARCHAR(150)    NOT NULL,
    category      VARCHAR(100),   -- e.g. 'Consultation', 'Surgery', 'Lab', 'Physiotherapy'
    standard_price NUMERIC(10,2)  NOT NULL DEFAULT 0.00,
    is_active     BOOLEAN         NOT NULL DEFAULT TRUE,

    CONSTRAINT uq_service_name   UNIQUE (service_name),
    CONSTRAINT chk_service_price CHECK  (standard_price >= 0)
);

COMMENT ON TABLE services_catalog IS 'Master list of hospital services and their standard prices for invoice auto-fill.';


-- =============================================================================
-- VERIFICATION QUERY
-- Run this after executing the script to confirm all 12 tables exist.
-- =============================================================================

SELECT
    table_name,
    (SELECT COUNT(*) FROM information_schema.columns c
     WHERE c.table_schema = 'hsk' AND c.table_name = t.table_name) AS column_count
FROM information_schema.tables t
WHERE table_schema = 'hsk'
ORDER BY table_name;
