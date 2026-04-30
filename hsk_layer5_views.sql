-- =============================================================================
-- HSK BONE CARE — HOSPITAL MANAGEMENT SYSTEM
-- Layer 5: Views (PostgreSQL)
-- Author  : Muhammad Arham (23-CSE-13)
-- Course  : Database Management System — 6th Semester, DUET
-- Teacher : Engr. Motia Rani
-- Run AFTER: Layers 1–4
-- =============================================================================

SET search_path TO hsk;

-- =============================================================================
-- WHAT ARE VIEWS?
--
-- A view is a saved SELECT query stored inside the database with a name.
-- Your frontend or application queries the view like a table — one clean
-- SELECT — and the DB runs the full multi-table JOIN behind the scenes.
--
-- Benefits:
--   • Simplifies application code — no complex JOINs in Node.js
--   • Single source of truth — logic lives in DB, not scattered across routes
--   • Security — you can grant SELECT on a view without exposing base tables
--   • Performance — combined with indexes from Layer 2, views are very fast
--
-- View types used here:
--   Regular VIEW        — re-runs the query on every SELECT (always fresh data)
--   MATERIALIZED VIEW   — stores the result physically; must be REFRESH-ed.
--                         Used for expensive aggregation reports.
-- =============================================================================


-- =============================================================================
-- VIEW 1 — v_active_admissions
-- The primary IPD ward dashboard view.
-- Shows every currently admitted patient with their room, doctor,
-- days stayed so far, accruing room charges, and outstanding balance.
--
-- Used by: Ward dashboard, nurse station, doctor ward-round screen
-- =============================================================================

CREATE OR REPLACE VIEW v_active_admissions AS
SELECT
    a.admission_id,
    a.admission_date,

    -- Patient info
    p.patient_id,
    p.patient_code,
    p.full_name                                     AS patient_name,
    p.gender,
    p.blood_group,
    p.phone                                         AS patient_phone,
    p.emergency_contact_name,
    p.emergency_contact_phone,

    -- Doctor info
    d.doctor_id,
    d.full_name                                     AS doctor_name,
    d.specialization,

    -- Room info
    r.room_id,
    r.room_number,
    r.room_type,
    r.daily_rate,

    -- Stay duration and accruing cost (live calculation)
    GREATEST(1, CURRENT_DATE - a.admission_date::DATE)
                                                    AS days_stayed,
    GREATEST(1, CURRENT_DATE - a.admission_date::DATE) * r.daily_rate
                                                    AS accrued_room_charge,

    -- Billing snapshot
    i.invoice_id,
    i.total_amount                                  AS invoice_total,
    i.paid_amount,
    i.total_amount - i.paid_amount                  AS outstanding_balance,
    i.status                                        AS invoice_status,

    -- Diagnosis
    a.diagnosis

FROM admissions a
JOIN patients p  ON p.patient_id  = a.patient_id
JOIN doctors  d  ON d.doctor_id   = a.doctor_id
JOIN rooms    r  ON r.room_id     = a.room_id
LEFT JOIN invoices i ON i.admission_id = a.admission_id

WHERE a.status = 'admitted'
  AND p.is_deleted = FALSE
  AND d.is_active  = TRUE;

COMMENT ON VIEW v_active_admissions IS
'All currently admitted patients with room, doctor, accruing charges, and billing status. Refreshes live on every query.';


-- =============================================================================
-- VIEW 2 — v_todays_opd
-- The OPD receptionist queue for the current day.
-- Shows every pending or confirmed appointment today with patient and
-- doctor details, sorted by appointment time.
--
-- Used by: Reception desk, OPD dashboard, morning queue screen
-- =============================================================================

CREATE OR REPLACE VIEW v_todays_opd AS
SELECT
    ap.appointment_id,
    ap.appointment_date,
    ap.appointment_time,
    ap.status                                       AS appointment_status,
    ap.notes,

    -- Patient info
    p.patient_id,
    p.patient_code,
    p.full_name                                     AS patient_name,
    p.phone                                         AS patient_phone,
    p.gender,
    p.blood_group,

    -- Doctor info
    d.doctor_id,
    d.full_name                                     AS doctor_name,
    d.specialization,

    -- Billing
    i.invoice_id,
    i.total_amount,
    i.paid_amount,
    i.status                                        AS invoice_status,

    -- Wait position (rank within the day by appointment time)
    ROW_NUMBER() OVER (
        PARTITION BY ap.appointment_date
        ORDER BY ap.appointment_time ASC
    )                                               AS queue_position

FROM appointments ap
JOIN patients p ON p.patient_id = ap.patient_id
JOIN doctors  d ON d.doctor_id  = ap.doctor_id
LEFT JOIN invoices i ON i.appointment_id = ap.appointment_id

WHERE ap.appointment_date = CURRENT_DATE
  AND ap.status IN ('pending', 'confirmed')
  AND p.is_deleted = FALSE

ORDER BY ap.appointment_time ASC;

COMMENT ON VIEW v_todays_opd IS
'Live OPD queue for today — pending and confirmed appointments only, ordered by time with queue position.';


-- =============================================================================
-- VIEW 3 — v_patient_full_history
-- Complete patient profile: all appointments, admissions, invoices,
-- and payments in one place.
-- Used by: Patient profile page, doctor review screen
-- =============================================================================

CREATE OR REPLACE VIEW v_patient_full_history AS
SELECT
    p.patient_id,
    p.patient_code,
    p.full_name                                     AS patient_name,
    p.dob,
    DATE_PART('year', AGE(p.dob))::INT             AS age,
    p.gender,
    p.blood_group,
    p.phone,
    p.address,
    p.emergency_contact_name,
    p.emergency_contact_phone,

    -- Visit counts
    COUNT(DISTINCT ap.appointment_id)               AS total_opd_visits,
    COUNT(DISTINCT ad.admission_id)                 AS total_admissions,

    -- Billing totals across all visits
    COALESCE(SUM(i.total_amount), 0)                AS lifetime_billed,
    COALESCE(SUM(i.paid_amount),  0)                AS lifetime_paid,
    COALESCE(SUM(i.total_amount), 0)
           - COALESCE(SUM(i.paid_amount),  0)       AS lifetime_outstanding,

    -- Last visit info
    MAX(ap.appointment_date)                        AS last_opd_visit,
    MAX(ad.admission_date)                          AS last_admission,

    p.created_at                                    AS registered_on

FROM patients p
LEFT JOIN appointments ap ON ap.patient_id = p.patient_id
LEFT JOIN admissions   ad ON ad.patient_id = p.patient_id
LEFT JOIN invoices      i ON i.patient_id  = p.patient_id

WHERE p.is_deleted = FALSE

GROUP BY
    p.patient_id, p.patient_code, p.full_name, p.dob,
    p.gender, p.blood_group, p.phone, p.address,
    p.emergency_contact_name, p.emergency_contact_phone,
    p.created_at;

COMMENT ON VIEW v_patient_full_history IS
'Complete patient profile with visit counts, lifetime billing totals, and last visit dates.';


-- =============================================================================
-- VIEW 4 — v_doctor_workload
-- Shows each active doctor's current and historical workload:
-- appointments today, this week, this month, and active admissions.
--
-- Used by: Admin dashboard, scheduling, staffing decisions
-- =============================================================================

CREATE OR REPLACE VIEW v_doctor_workload AS
SELECT
    d.doctor_id,
    d.full_name                                     AS doctor_name,
    d.specialization,
    d.phone,
    d.email,

    -- Appointment counts
    COUNT(DISTINCT ap.appointment_id)
        FILTER (WHERE ap.appointment_date = CURRENT_DATE
                  AND ap.status IN ('pending','confirmed','completed'))
                                                    AS appointments_today,

    COUNT(DISTINCT ap.appointment_id)
        FILTER (WHERE ap.appointment_date >= DATE_TRUNC('week', CURRENT_DATE)
                  AND ap.status IN ('pending','confirmed','completed'))
                                                    AS appointments_this_week,

    COUNT(DISTINCT ap.appointment_id)
        FILTER (WHERE ap.appointment_date >= DATE_TRUNC('month', CURRENT_DATE)
                  AND ap.status IN ('pending','confirmed','completed'))
                                                    AS appointments_this_month,

    COUNT(DISTINCT ap.appointment_id)
        FILTER (WHERE ap.status = 'completed')
                                                    AS total_completed,

    -- IPD workload
    COUNT(DISTINCT ad.admission_id)
        FILTER (WHERE ad.status = 'admitted')
                                                    AS current_ipd_patients,

    COUNT(DISTINCT ad.admission_id)                 AS total_admissions_handled

FROM doctors d
LEFT JOIN appointments ap ON ap.doctor_id = d.doctor_id
LEFT JOIN admissions   ad ON ad.doctor_id = d.doctor_id

WHERE d.is_active = TRUE

GROUP BY
    d.doctor_id, d.full_name, d.specialization,
    d.phone, d.email

ORDER BY appointments_today DESC, current_ipd_patients DESC;

COMMENT ON VIEW v_doctor_workload IS
'Active doctor workload: appointment counts by day/week/month plus current IPD patients.';


-- =============================================================================
-- VIEW 5 — v_billing_summary
-- Per-patient billing overview: total billed, paid, outstanding,
-- and count of open invoices.
--
-- Used by: Billing desk, outstanding dues report, patient billing page
-- =============================================================================

CREATE OR REPLACE VIEW v_billing_summary AS
SELECT
    p.patient_id,
    p.patient_code,
    p.full_name                                     AS patient_name,
    p.phone,

    -- Invoice counts
    COUNT(i.invoice_id)                             AS total_invoices,
    COUNT(i.invoice_id) FILTER (WHERE i.status = 'unpaid')
                                                    AS unpaid_invoices,
    COUNT(i.invoice_id) FILTER (WHERE i.status = 'partial')
                                                    AS partial_invoices,
    COUNT(i.invoice_id) FILTER (WHERE i.status = 'paid')
                                                    AS paid_invoices,

    -- Financial totals
    COALESCE(SUM(i.total_amount), 0)                AS total_billed,
    COALESCE(SUM(i.paid_amount),  0)                AS total_paid,
    COALESCE(SUM(i.total_amount - i.paid_amount), 0)
                                                    AS total_outstanding,

    -- Most recent invoice
    MAX(i.generated_at)                             AS last_invoice_date,

    -- Flag patients with any outstanding balance
    CASE
        WHEN COALESCE(SUM(i.total_amount - i.paid_amount), 0) > 0
        THEN TRUE ELSE FALSE
    END                                             AS has_outstanding_dues

FROM patients p
LEFT JOIN invoices i ON i.patient_id = p.patient_id

WHERE p.is_deleted = FALSE

GROUP BY
    p.patient_id, p.patient_code, p.full_name, p.phone

ORDER BY total_outstanding DESC, last_invoice_date DESC;

COMMENT ON VIEW v_billing_summary IS
'Per-patient billing summary: invoice counts by status, financial totals, and outstanding dues flag.';


-- =============================================================================
-- VIEW 6 — v_invoice_detail
-- Full invoice breakdown: header + all line items + all payments in one view.
-- Used by: Invoice print screen, billing detail page
-- =============================================================================

CREATE OR REPLACE VIEW v_invoice_detail AS
SELECT
    i.invoice_id,
    i.generated_at,
    i.status                                        AS invoice_status,
    i.total_amount,
    i.paid_amount,
    i.total_amount - i.paid_amount                  AS balance_due,

    -- Patient
    p.patient_id,
    p.patient_code,
    p.full_name                                     AS patient_name,
    p.phone                                         AS patient_phone,

    -- Visit context
    CASE
        WHEN i.admission_id    IS NOT NULL THEN 'IPD'
        WHEN i.appointment_id  IS NOT NULL THEN 'OPD'
    END                                             AS visit_type,
    i.admission_id,
    i.appointment_id,

    -- Line items (aggregated as JSON array)
    COALESCE(
        JSON_AGG(
            JSON_BUILD_OBJECT(
                'item_id',      ii.item_id,
                'description',  ii.description,
                'quantity',     ii.quantity,
                'unit_price',   ii.unit_price,
                'total_price',  ii.total_price
            ) ORDER BY ii.item_id
        ) FILTER (WHERE ii.item_id IS NOT NULL),
        '[]'::json
    )                                               AS line_items,

    -- Payments (aggregated as JSON array)
    COALESCE(
        JSON_AGG(
            JSON_BUILD_OBJECT(
                'payment_id',   pay.payment_id,
                'amount',       pay.amount,
                'method',       pay.payment_method,
                'paid_at',      pay.paid_at
            ) ORDER BY pay.paid_at
        ) FILTER (WHERE pay.payment_id IS NOT NULL),
        '[]'::json
    )                                               AS payments_made

FROM invoices i
JOIN patients p         ON p.patient_id  = i.patient_id
LEFT JOIN invoice_items ii  ON ii.invoice_id = i.invoice_id
LEFT JOIN payments      pay ON pay.invoice_id = i.invoice_id

GROUP BY
    i.invoice_id, i.generated_at, i.status,
    i.total_amount, i.paid_amount,
    i.admission_id, i.appointment_id,
    p.patient_id, p.patient_code, p.full_name, p.phone;

COMMENT ON VIEW v_invoice_detail IS
'Full invoice breakdown with patient info, line items and payments as JSON arrays. Used for invoice print/display.';


-- =============================================================================
-- VIEW 7 — v_room_status
-- Live room occupancy board.
-- Shows every room with current patient (if occupied) and occupancy stats.
--
-- Used by: Admission desk "find a room", ward management screen
-- =============================================================================

CREATE OR REPLACE VIEW v_room_status AS
SELECT
    r.room_id,
    r.room_number,
    r.room_type,
    r.capacity,
    r.daily_rate,
    r.is_available,

    -- Current occupant (if any)
    p.patient_id,
    p.patient_code,
    p.full_name                                     AS current_patient,
    d.full_name                                     AS attending_doctor,
    a.admission_date,
    GREATEST(1, CURRENT_DATE - a.admission_date::DATE)
                                                    AS days_occupied,
    a.diagnosis

FROM rooms r
LEFT JOIN admissions a  ON a.room_id    = r.room_id
                       AND a.status     = 'admitted'
LEFT JOIN patients   p  ON p.patient_id = a.patient_id
LEFT JOIN doctors    d  ON d.doctor_id  = a.doctor_id

ORDER BY r.room_type, r.room_number;

COMMENT ON VIEW v_room_status IS
'Live room occupancy board: all rooms with current patient and doctor if occupied.';


-- =============================================================================
-- MATERIALIZED VIEW 1 — mv_daily_revenue
-- Aggregated daily revenue report.
-- Expensive to compute live (sums across all payments ever).
-- Stored physically and refreshed on demand (e.g., nightly or after billing).
--
-- Refresh command: REFRESH MATERIALIZED VIEW hsk.mv_daily_revenue;
-- Used by: Admin revenue dashboard, Excel export, financial reports
-- =============================================================================

CREATE MATERIALIZED VIEW mv_daily_revenue AS
SELECT
    pay.paid_at::DATE                               AS revenue_date,
    pay.payment_method,

    COUNT(pay.payment_id)                           AS payment_count,
    SUM(pay.amount)                                 AS total_collected,

    -- Split by visit type
    SUM(pay.amount) FILTER (
        WHERE i.admission_id IS NOT NULL
    )                                               AS ipd_revenue,

    SUM(pay.amount) FILTER (
        WHERE i.appointment_id IS NOT NULL
    )                                               AS opd_revenue,

    -- Running total (window function)
    SUM(SUM(pay.amount)) OVER (
        ORDER BY pay.paid_at::DATE
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                               AS cumulative_revenue

FROM payments pay
JOIN invoices i ON i.invoice_id = pay.invoice_id

GROUP BY
    pay.paid_at::DATE,
    pay.payment_method

ORDER BY revenue_date DESC, payment_method;

-- Index on the materialized view for fast date range queries
CREATE INDEX idx_mv_daily_revenue_date
    ON mv_daily_revenue(revenue_date DESC);

COMMENT ON MATERIALIZED VIEW mv_daily_revenue IS
'Daily revenue aggregated by payment method and visit type (IPD/OPD). Refresh with: REFRESH MATERIALIZED VIEW hsk.mv_daily_revenue';


-- =============================================================================
-- MATERIALIZED VIEW 2 — mv_monthly_summary
-- High-level monthly hospital performance summary.
-- Includes patient volume, revenue, bed occupancy, and top doctors.
-- Expensive aggregation — stored and refreshed monthly or on demand.
--
-- Refresh command: REFRESH MATERIALIZED VIEW hsk.mv_monthly_summary;
-- Used by: Management dashboard, monthly board report
-- =============================================================================

CREATE MATERIALIZED VIEW mv_monthly_summary AS
WITH monthly_payments AS (
    SELECT
        DATE_TRUNC('month', pay.paid_at)::DATE AS month_start,
        SUM(pay.amount) AS total_revenue,
        SUM(pay.amount) FILTER (WHERE i.admission_id IS NOT NULL) AS ipd_revenue,
        SUM(pay.amount) FILTER (WHERE i.appointment_id IS NOT NULL) AS opd_revenue
    FROM payments pay
    JOIN invoices i ON i.invoice_id = pay.invoice_id
    GROUP BY 1
),
monthly_appointments AS (
    SELECT
        DATE_TRUNC('month', appointment_date::TIMESTAMPTZ)::DATE AS month_start,
        COUNT(appointment_id) FILTER (WHERE status = 'completed') AS opd_completed,
        COUNT(appointment_id) FILTER (WHERE status = 'cancelled') AS opd_cancelled
    FROM appointments
    GROUP BY 1
),
monthly_admissions AS (
    SELECT
        DATE_TRUNC('month', admission_date)::DATE AS month_start,
        COUNT(admission_id) AS total_admissions,
        COUNT(admission_id) FILTER (WHERE status = 'discharged') AS total_discharges
    FROM admissions
    GROUP BY 1
),
monthly_registrations AS (
    SELECT
        DATE_TRUNC('month', created_at)::DATE AS month_start,
        COUNT(patient_id) AS new_patients_registered
    FROM patients
    GROUP BY 1
),
months AS (
    SELECT month_start FROM monthly_payments
    UNION
    SELECT month_start FROM monthly_appointments
    UNION
    SELECT month_start FROM monthly_admissions
    UNION
    SELECT month_start FROM monthly_registrations
)
SELECT
    m.month_start,
    TO_CHAR(m.month_start, 'Month YYYY') AS month_label,
    COALESCE(ap.opd_completed, 0)       AS opd_completed,
    COALESCE(ap.opd_cancelled, 0)       AS opd_cancelled,
    COALESCE(ad.total_admissions, 0)     AS total_admissions,
    COALESCE(ad.total_discharges, 0)     AS total_discharges,
    COALESCE(pay.total_revenue, 0)       AS total_revenue,
    COALESCE(pay.ipd_revenue, 0)         AS ipd_revenue,
    COALESCE(pay.opd_revenue, 0)         AS opd_revenue,
    COALESCE(reg.new_patients_registered, 0) AS new_patients_registered
FROM months m
LEFT JOIN monthly_payments pay ON pay.month_start = m.month_start
LEFT JOIN monthly_appointments ap ON ap.month_start = m.month_start
LEFT JOIN monthly_admissions ad ON ad.month_start = m.month_start
LEFT JOIN monthly_registrations reg ON reg.month_start = m.month_start
ORDER BY m.month_start DESC;

CREATE INDEX idx_mv_monthly_summary_month
    ON mv_monthly_summary(month_start DESC);

COMMENT ON MATERIALIZED VIEW mv_monthly_summary IS
'Monthly hospital performance: OPD/IPD volumes, revenue by type, and new patient registrations. Refresh monthly.';


-- =============================================================================
-- VIEW 8 — v_audit_trail
-- Human-readable audit log with user names and timestamps.
-- Joins audit_log with users to show who did what.
--
-- Used by: Admin audit screen, compliance review
-- =============================================================================

CREATE OR REPLACE VIEW v_audit_trail AS
SELECT
    al.log_id,
    al.logged_at,
    al.action,
    al.target_table,
    al.target_id,
    al.ip_address,

    -- Who did it
    u.user_id,
    u.username,
    u.role                                          AS user_role,

    -- Change summary (show key fields from snapshots)
    al.old_data,
    al.new_data

FROM audit_log al
LEFT JOIN users u ON u.user_id = al.user_id

ORDER BY al.logged_at DESC;

COMMENT ON VIEW v_audit_trail IS
'Human-readable audit trail: all DB changes with username, role, and before/after JSON snapshots.';


-- =============================================================================
-- VERIFICATION — List all views in the hsk schema
-- =============================================================================

-- REGULAR VIEWS
SELECT
    table_name      AS view_name,
    'regular'       AS view_type
FROM information_schema.views
WHERE table_schema = 'hsk'
ORDER BY table_name;

-- MATERIALIZED VIEWS
SELECT
    matviewname     AS view_name,
    'materialized'  AS view_type,
    ispopulated     AS has_data
FROM pg_matviews
WHERE schemaname = 'hsk'
ORDER BY matviewname;
