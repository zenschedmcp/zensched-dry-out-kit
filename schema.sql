-- ZenSched Water-Damage Dry-Out Local Database Schema
-- SQLite database for clients (insurers, TPAs, homeowners), dry-out jobs at
-- a loss address (water class, 60-day ZenSched event roll), rooms being
-- monitored, daily visits (one shift each, moisture_readings JSON from the
-- Moisture Log form), technician roster, and client invoices / receivables.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, timesheets).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my dryout-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 dryout-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- THIS IS NOT AN IICRC S500 PSYCHROMETRIC PACKAGE AND NOT XACTIMATE. Nothing
-- here computes GPP, grains, or a drying goal from ambient readings. The
-- Moisture Log is room + moisture % + meter type + a photo of the meter.
-- You (or the desk adjuster) still write the official drying record elsewhere
-- if the carrier requires one.
--
-- NO BAA. ZenShows / ZenSched is not a HIPAA business associate. Use this kit
-- for property water losses. Do not run medical / workers-comp health visits
-- on it. Insured name, claim number, and policy number live ONLY in this file.
--
-- PHI / PII BOUNDARY: insured name, claim number, and policy number live ONLY
-- here: jobs.insured_name, jobs.claim_no, jobs.policy_no. Gate codes live in
-- jobs.access_notes. ZenSched receives a place label ("Dry-out - Willow Ln"),
-- the street address for the GPS pin, an event title
-- ("Dry-out J-2026-0001 - Willow Ln"), and the Moisture Log (room, moisture %,
-- meter type, meter photo, notes). SKILL.md forbids the agent from putting
-- any local-only column into a ZenSched field.

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session (timezone, defaults, business name, form id).
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My Dry-Out Co');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '-05:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('state', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_technician_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_visit_time', '09:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_visit_minutes', '45');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_target_moisture_pct', '16');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('moisture_form_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('event_window_days', '60');

-- Clients: who hires you and who pays you. An insurer, a TPA, or a
-- homeowner paying cash. payment_terms_days drives invoice due dates;
-- default_daily_rate / default_trip_fee are copied onto the job when the
-- work order does not state a rate.
CREATE TABLE IF NOT EXISTS clients (
  client_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_name TEXT NOT NULL,
  client_type TEXT NOT NULL DEFAULT 'insurer'
    CHECK (client_type IN ('insurer', 'tpa', 'homeowner', 'other')),
  contact_name TEXT,                                -- LOCAL ONLY: desk / claim handler / AP
  contact_phone TEXT,
  billing_email TEXT,
  payment_terms_days INTEGER NOT NULL DEFAULT 30,   -- net 30 / net 45; homeowner cash = 0
  default_daily_rate REAL,                          -- $ per completed daily monitoring visit
  default_trip_fee REAL,                            -- $ when nobody is home / access denied
  notes TEXT,
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Technicians: in solo mode this is one row (you, is_owner = 1) whose
-- zensched_worker_id came from inviting yourself. license_no (IICRC / state
-- restoration cert) is LOCAL ONLY.
CREATE TABLE IF NOT EXISTS technicians (
  technician_id INTEGER PRIMARY KEY AUTOINCREMENT,
  technician_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite (integer)
  is_owner INTEGER DEFAULT 0,                       -- 1 = the business owner
  license_no TEXT,                                  -- LOCAL ONLY
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Jobs: one row per dry-out at a loss address. The address lives here (one
-- ZenSched LOCATION per job, kept for the life of the job). One ZenSched
-- EVENT per job per rolling window of at most 60 days (ZenSched caps event
-- length). zensched_event_id is the CURRENT event and event_valid_until is
-- its last valid date. When a visit date is later than event_valid_until,
-- the agent creates a new event and updates both columns.
--
-- job_no is YOUR reference, filled by trigger as 'J-2026-0001' when NULL.
-- client_order_ref is THE CLIENT's file / work-order number (safe to put on
-- an invoice; they issued it).
--
-- water_class is IICRC S500 class 1–4 (how much water / how hard to dry),
-- not category 1–3 (contamination). claim_no, policy_no, insured_name are
-- LOCAL ONLY and never reach ZenSched. The event title is
-- "Dry-out {job_no} - {street}".
--
-- status: intake | drying | dry | cancelled.
-- drying means daily visits continue until the owner marks the job dry.
CREATE TABLE IF NOT EXISTS jobs (
  job_id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_no TEXT UNIQUE,                               -- 'J-2026-0001', filled by trigger if NULL
  client_id INTEGER NOT NULL,
  client_order_ref TEXT,                            -- the client's file / work-order number
  water_class TEXT NOT NULL DEFAULT 'class_2'
    CHECK (water_class IN ('class_1', 'class_2', 'class_3', 'class_4')),
  water_category TEXT                               -- optional IICRC category (contamination)
    CHECK (water_category IS NULL OR water_category IN ('cat_1', 'cat_2', 'cat_3')),
  loss_date TEXT,                                   -- ISO date of loss
  monitor_start TEXT,                               -- first daily-visit date (ISO); NULL = today
  dry_date TEXT,                                    -- set when status becomes dry
  address TEXT NOT NULL,
  city TEXT,
  state TEXT,
  zip TEXT,
  street_name TEXT,                                 -- 'Willow Ln' (no number); used in titles
  access_notes TEXT,                                -- LOCAL ONLY: gate code, key, dog, tenant
  zensched_label TEXT,                              -- sent to ZenSched: 'Dry-out - Willow Ln'
  zensched_location_id INTEGER,                     -- from location_create (permanent), integer
  zensched_event_id INTEGER,                        -- from event_create (current <=60-day window)
  event_valid_until TEXT,                           -- ISO date: last day the current event covers
  visit_time TEXT                                   -- 'HH:MM' 24-hour local; NULL -> setting
    CHECK (visit_time IS NULL OR visit_time GLOB '[0-2][0-9]:[0-5][0-9]'),
  duration_minutes INTEGER                          -- NULL -> settings.default_visit_minutes
    CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 15 AND 480),
  technician_id INTEGER,                            -- preferred tech; NULL -> default_technician_id
  daily_rate REAL,                                  -- NULL -> client default_daily_rate (trigger)
  trip_fee REAL,                                    -- NULL -> client default_trip_fee (trigger)
  claim_no TEXT,                                    -- LOCAL ONLY
  policy_no TEXT,                                   -- LOCAL ONLY
  insured_name TEXT,                                -- LOCAL ONLY
  status TEXT NOT NULL DEFAULT 'drying'
    CHECK (status IN ('intake', 'drying', 'dry', 'cancelled')),
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE,
  FOREIGN KEY (technician_id) REFERENCES technicians(technician_id) ON DELETE SET NULL
);

-- Rooms: the cavities / finishes being monitored on a job. room_key MUST be
-- one of the Moisture Log form option keys (the form is created once and
-- cannot be per-job). room_label is the name you say to the owner
-- ('Master bedroom' on key bedroom_1). UNIQUE(job_id, room_key) — a fourth
-- bedroom uses key 'other'. target_moisture_pct NULL -> setting.
CREATE TABLE IF NOT EXISTS rooms (
  room_id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id INTEGER NOT NULL,
  room_key TEXT NOT NULL
    CHECK (room_key IN (
      'living_room', 'dining_room', 'kitchen',
      'bedroom_1', 'bedroom_2', 'bedroom_3',
      'bathroom_1', 'bathroom_2', 'hallway',
      'basement', 'garage', 'laundry', 'closet', 'other'
    )),
  room_label TEXT,                                  -- 'Master bedroom'; NULL -> pretty room_key
  target_moisture_pct REAL,                         -- NULL -> settings.default_target_moisture_pct
  last_moisture_pct REAL,
  last_reading_date TEXT,                           -- ISO date of the latest logged reading
  last_meter_type TEXT,                             -- form option key: pin, pinless, ...
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  UNIQUE (job_id, room_key),
  FOREIGN KEY (job_id) REFERENCES jobs(job_id) ON DELETE CASCADE
);

-- Daily visits: THE driving table for the phone. One row per calendar day on
-- a drying job; each row maps to exactly one ZenSched shift on the job's
-- current (<=60-day) event. Recurring daily until the job is marked dry —
-- visits_due_this_week expands the next 7 days; the agent inserts a row and
-- shift_create's it.
--
-- scheduled_start is LOCAL wall-clock time as 'YYYY-MM-DDTHH:MM' with NO
-- offset and no 'Z'; the views append settings.timezone_offset to produce
-- start_iso / end_iso for shift_create.
--
-- moisture_readings is a JSON array aggregated from every Moisture Log
-- submission on that visit (one submission per room):
--   [{"room":"living_room","moisture_pct":22.5,"meter_type":"pin",
--     "photo_urls":["..."],"notes":"...","submission_id":3501}, ...]
-- checked_in_at / checked_out_at / gps_verified / checkin_distance_m are
-- copied from shift_status once so "was the tech on site" is free later.
CREATE TABLE IF NOT EXISTS daily_visits (
  visit_id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id INTEGER NOT NULL,
  visit_date TEXT NOT NULL                          -- ISO date; UNIQUE per job (one visit / day)
    CHECK (visit_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  scheduled_start TEXT                              -- local 'YYYY-MM-DDTHH:MM[:SS]', no offset
    CHECK (scheduled_start IS NULL
           OR (scheduled_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-2][0-9]:[0-5][0-9]*'
               AND scheduled_start NOT GLOB '*T*[+-]*'
               AND scheduled_start NOT GLOB '*Z')),
  duration_minutes INTEGER                          -- NULL -> job / settings
    CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 15 AND 480),
  technician_id INTEGER,                            -- NULL -> job.technician_id / default
  status TEXT NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned', 'completed', 'no_access', 'cancelled', 'no_show')),
  zensched_event_id INTEGER,                        -- event this shift hangs on (may be a rolled window)
  zensched_shift_id INTEGER UNIQUE,                 -- one shift per visit
  moisture_readings TEXT,                           -- JSON array from Moisture Log submissions
  rooms_logged INTEGER,                             -- count of readings stored
  rooms_still_wet INTEGER,                          -- readings still above that room's target
  report_dc_ids TEXT,                               -- JSON array of submission_ids (one per room)
  checked_in_at TEXT,                               -- from shift_status (ISO with offset)
  checked_out_at TEXT,
  gps_verified INTEGER,                             -- 1 if the check-in punch was on site
  checkin_distance_m INTEGER,
  other_fee REAL,                                   -- after-hours, extra equipment day, ...
  invoiced INTEGER DEFAULT 0,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  UNIQUE (job_id, visit_date),
  FOREIGN KEY (job_id) REFERENCES jobs(job_id) ON DELETE CASCADE,
  FOREIGN KEY (technician_id) REFERENCES technicians(technician_id) ON DELETE SET NULL
);

-- Invoices: one per client per billing run. invoice_number is filled by trigger
-- if left NULL. due_date is invoice_date + the client's payment_terms_days.
-- line_items is a JSON array with one object per visit (job_no, date,
-- water_class, order ref, fee breakdown, shift id). Never put insured name,
-- claim number, or policy number in line_items.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id INTEGER NOT NULL,
  invoice_number TEXT UNIQUE,                       -- 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  sent_date TEXT,
  line_items TEXT,                                  -- JSON array
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_jobs_client ON jobs(client_id, status);
CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status, monitor_start);
CREATE INDEX IF NOT EXISTS idx_jobs_location ON jobs(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_jobs_event ON jobs(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_rooms_job ON rooms(job_id, is_active);
CREATE INDEX IF NOT EXISTS idx_visits_date ON daily_visits(visit_date);
CREATE INDEX IF NOT EXISTS idx_visits_status_date ON daily_visits(status, visit_date);
CREATE INDEX IF NOT EXISTS idx_visits_job ON daily_visits(job_id);
CREATE INDEX IF NOT EXISTS idx_visits_event ON daily_visits(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_visits_invoiced ON daily_visits(invoiced, status);
CREATE INDEX IF NOT EXISTS idx_invoices_client ON invoices(client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_paid ON invoices(paid, due_date);

-- Which fees are billable depends on what happened at the visit. This is the
-- single place that rule lives; receivables and invoicing read billable_total
-- from here rather than re-deriving it.
--   completed  -> daily_rate + other_fee
--   no_access  -> trip_fee + other_fee
--   cancelled / planned / no_show -> 0  (put a late-cancel on other_fee AND
--                                       flip status to no_access if you want it billed)
CREATE VIEW IF NOT EXISTS billable_visits AS
SELECT
  v.visit_id,
  v.visit_date,
  v.status,
  v.invoiced,
  v.other_fee,
  v.zensched_shift_id,
  v.rooms_logged,
  v.rooms_still_wet,
  v.gps_verified,
  j.job_id,
  j.job_no,
  j.client_id,
  j.client_order_ref,
  j.water_class,
  j.daily_rate,
  j.trip_fee,
  j.status                                          AS job_status,
  CASE v.status
    WHEN 'completed' THEN round(COALESCE(j.daily_rate, 0) + COALESCE(v.other_fee, 0), 2)
    WHEN 'no_access' THEN round(COALESCE(j.trip_fee, 0) + COALESCE(v.other_fee, 0), 2)
    ELSE 0
  END                                               AS billable_total
FROM daily_visits v
JOIN jobs j ON j.job_id = v.job_id;

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_client_timestamp
AFTER UPDATE ON clients
BEGIN
  UPDATE clients SET updated_at = datetime('now') WHERE client_id = NEW.client_id;
END;

CREATE TRIGGER IF NOT EXISTS update_technician_timestamp
AFTER UPDATE ON technicians
BEGIN
  UPDATE technicians SET updated_at = datetime('now') WHERE technician_id = NEW.technician_id;
END;

CREATE TRIGGER IF NOT EXISTS update_job_timestamp
AFTER UPDATE OF client_id, client_order_ref, water_class, water_category, loss_date,
                monitor_start, dry_date, address, city, state, zip, street_name,
                access_notes, zensched_label, zensched_location_id, zensched_event_id,
                event_valid_until, visit_time, duration_minutes, technician_id,
                daily_rate, trip_fee, claim_no, policy_no, insured_name, status, notes
ON jobs
BEGIN
  UPDATE jobs SET updated_at = datetime('now') WHERE job_id = NEW.job_id;
END;

CREATE TRIGGER IF NOT EXISTS update_room_timestamp
AFTER UPDATE OF job_id, room_key, room_label, target_moisture_pct, last_moisture_pct,
                last_reading_date, last_meter_type, is_active, notes
ON rooms
BEGIN
  UPDATE rooms SET updated_at = datetime('now') WHERE room_id = NEW.room_id;
END;

CREATE TRIGGER IF NOT EXISTS update_visit_timestamp
AFTER UPDATE OF job_id, visit_date, scheduled_start, duration_minutes, technician_id,
                status, zensched_event_id, zensched_shift_id, moisture_readings,
                rooms_logged, rooms_still_wet, report_dc_ids, checked_in_at,
                checked_out_at, gps_verified, checkin_distance_m, other_fee,
                invoiced, notes
ON daily_visits
BEGIN
  UPDATE daily_visits SET updated_at = datetime('now') WHERE visit_id = NEW.visit_id;
END;

-- Auto-number jobs: J-2026-0001, J-2026-0002, ... (year of monitor_start,
-- else loss_date, else today; sequence = job_id).
CREATE TRIGGER IF NOT EXISTS number_job
AFTER INSERT ON jobs
WHEN NEW.job_no IS NULL
BEGIN
  UPDATE jobs
  SET job_no = 'J-'
    || strftime('%Y', COALESCE(NEW.monitor_start, NEW.loss_date, date('now', 'localtime')))
    || '-' || printf('%04d', NEW.job_id)
  WHERE job_id = NEW.job_id;
END;

-- Fill defaults the agent left NULL:
--   daily_rate        <- clients.default_daily_rate, else 0
--   trip_fee          <- clients.default_trip_fee, else daily_rate
--   visit_time        <- settings.default_visit_time (else 09:00)
--   duration_minutes  <- settings.default_visit_minutes (else 45)
--   monitor_start     <- today (local)
--   zensched_label    <- 'Dry-out - {street_name}' (else job_no, else 'site')
-- Rates are snapshots: changing a client's defaults later never rewrites history.
CREATE TRIGGER IF NOT EXISTS fill_job_defaults
AFTER INSERT ON jobs
BEGIN
  UPDATE jobs
  SET daily_rate = COALESCE(NEW.daily_rate, (SELECT default_daily_rate FROM clients WHERE client_id = NEW.client_id), 0),
      trip_fee = COALESCE(NEW.trip_fee, (SELECT default_trip_fee FROM clients WHERE client_id = NEW.client_id),
                          NEW.daily_rate, (SELECT default_daily_rate FROM clients WHERE client_id = NEW.client_id), 0),
      visit_time = COALESCE(NEW.visit_time,
                            (SELECT value FROM settings WHERE key = 'default_visit_time'),
                            '09:00'),
      duration_minutes = COALESCE(NEW.duration_minutes,
                                  (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_visit_minutes'),
                                  45),
      monitor_start = COALESCE(NEW.monitor_start, date('now', 'localtime')),
      zensched_label = COALESCE(NEW.zensched_label,
                                'Dry-out - ' || COALESCE(NEW.street_name,
                                  (SELECT job_no FROM jobs WHERE job_id = NEW.job_id),
                                  'site'))
  WHERE job_id = NEW.job_id;
END;

-- Fill room target from settings when the agent leaves it NULL.
CREATE TRIGGER IF NOT EXISTS fill_room_defaults
AFTER INSERT ON rooms
BEGIN
  UPDATE rooms
  SET target_moisture_pct = COALESCE(NEW.target_moisture_pct,
                                     (SELECT CAST(value AS REAL) FROM settings WHERE key = 'default_target_moisture_pct'),
                                     16),
      room_label = COALESCE(NEW.room_label, REPLACE(NEW.room_key, '_', ' '))
  WHERE room_id = NEW.room_id;
END;

-- Fill visit defaults the agent left NULL:
--   scheduled_start   <- visit_date + job.visit_time (else settings)
--   duration_minutes  <- job.duration_minutes (else settings, else 45)
--   technician_id     <- job.technician_id (else settings.default_technician_id)
--   other_fee         <- 0
CREATE TRIGGER IF NOT EXISTS fill_visit_defaults
AFTER INSERT ON daily_visits
BEGIN
  UPDATE daily_visits
  SET scheduled_start = COALESCE(NEW.scheduled_start,
                                 NEW.visit_date || 'T' || COALESCE(
                                   (SELECT visit_time FROM jobs WHERE job_id = NEW.job_id),
                                   (SELECT value FROM settings WHERE key = 'default_visit_time'),
                                   '09:00')),
      duration_minutes = COALESCE(NEW.duration_minutes,
                                  (SELECT duration_minutes FROM jobs WHERE job_id = NEW.job_id),
                                  (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_visit_minutes'),
                                  45),
      technician_id = COALESCE(NEW.technician_id,
                               (SELECT technician_id FROM jobs WHERE job_id = NEW.job_id),
                               (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_technician_id' AND value IS NOT NULL)),
      other_fee = COALESCE(NEW.other_fee, 0)
  WHERE visit_id = NEW.visit_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Days that still need a visit in the next 7 days (today + 6, local date of
-- the computer running the database) for every drying job. One row = one
-- shift_create after the agent inserts the daily_visits row. start_iso /
-- end_iso carry settings.timezone_offset. event_needs_roll = 1 means create
-- a new ZenSched event first (see SKILL.md). Event title is ALWAYS
-- "Dry-out {job_no} - {street}" — never an insured name or claim number.
CREATE VIEW IF NOT EXISTS visits_due_this_week AS
WITH RECURSIVE days(d) AS (
  SELECT date('now', 'localtime')
  UNION ALL
  SELECT date(d, '+1 day') FROM days WHERE d < date('now', 'localtime', '+6 days')
)
SELECT
  days.d                                                                              AS visit_date,
  j.job_id,
  j.job_no,
  j.status                                                                            AS job_status,
  j.water_class,
  j.water_category,
  j.loss_date,
  j.monitor_start,
  j.client_order_ref,
  j.claim_no,                                                                         -- LOCAL: show the owner, never ZenSched
  j.insured_name,                                                                     -- LOCAL
  j.daily_rate,
  j.trip_fee,
  c.client_id,
  c.client_name,
  c.client_type,
  j.address,
  j.city,
  j.state,
  j.zip,
  j.street_name,
  j.address || COALESCE(', ' || j.city, '') || COALESCE(', ' || j.state, '') || COALESCE(' ' || j.zip, '') AS street_address,
  COALESCE(j.zensched_label, 'Dry-out - ' || COALESCE(j.street_name, j.job_no))       AS zensched_location_name,
  'Dry-out ' || j.job_no || ' - ' || COALESCE(j.street_name, 'site')                  AS zensched_event_title,
  j.access_notes                                                                      AS job_access_notes,
  j.zensched_location_id,
  CASE WHEN j.zensched_location_id IS NULL THEN 1 ELSE 0 END                          AS needs_location,
  j.zensched_event_id,
  j.event_valid_until,
  CASE WHEN j.event_valid_until IS NULL OR j.event_valid_until < days.d THEN 1 ELSE 0 END AS event_needs_roll,
  COALESCE(j.visit_time, (SELECT value FROM settings WHERE key = 'default_visit_time'), '09:00') AS start_time,
  COALESCE(j.duration_minutes, CAST((SELECT value FROM settings WHERE key = 'default_visit_minutes') AS INTEGER), 45) AS duration_minutes,
  days.d || 'T'
    || COALESCE(j.visit_time, (SELECT value FROM settings WHERE key = 'default_visit_time'), '09:00')
    || ':00' || (SELECT value FROM settings WHERE key = 'timezone_offset')            AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(
      days.d || ' '
      || COALESCE(j.visit_time, (SELECT value FROM settings WHERE key = 'default_visit_time'), '09:00')
      || ':00',
      '+' || COALESCE(j.duration_minutes, CAST((SELECT value FROM settings WHERE key = 'default_visit_minutes') AS INTEGER), 45) || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                    AS end_iso,
  COALESCE(j.technician_id, (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_technician_id' AND value IS NOT NULL)) AS technician_id,
  (SELECT t.technician_name FROM technicians t
    WHERE t.technician_id = COALESCE(j.technician_id,
           (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_technician_id' AND value IS NOT NULL))) AS technician_name,
  (SELECT t.zensched_worker_id FROM technicians t
    WHERE t.technician_id = COALESCE(j.technician_id,
           (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_technician_id' AND value IS NOT NULL))) AS zensched_worker_id,
  CASE WHEN COALESCE(j.technician_id,
           (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_technician_id' AND value IS NOT NULL)) IS NULL THEN 1 ELSE 0 END AS unassigned,
  (SELECT COUNT(*) FROM rooms r WHERE r.job_id = j.job_id AND r.is_active = 1)        AS room_count,
  'loc-job-' || j.job_id                                                              AS loc_idempotency_key,
  'shift-job-' || j.job_id || '-' || strftime('%Y%m%d', days.d)                       AS shift_idempotency_key,
  j.notes                                                                             AS job_notes
FROM days
JOIN jobs j ON j.status = 'drying'
 AND (j.monitor_start IS NULL OR j.monitor_start <= days.d)
JOIN clients c ON c.client_id = j.client_id AND c.is_active = 1
WHERE NOT EXISTS (
  SELECT 1 FROM daily_visits v WHERE v.job_id = j.job_id AND v.visit_date = days.d
)
ORDER BY days.d, COALESCE(j.visit_time, '09:00'), j.job_no;

-- Planned visits already inserted (today through today + 6) with ISO times
-- and keys ready for shift_create. needs_shift = 1 -> booked locally but
-- never put on the phone.
CREATE VIEW IF NOT EXISTS visits_upcoming AS
SELECT
  v.visit_id,
  v.visit_date,
  v.status,
  v.scheduled_start,
  v.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', v.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                     AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(v.scheduled_start, '+' || v.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                     AS end_iso,
  j.job_id,
  j.job_no,
  j.status                                                                            AS job_status,
  j.water_class,
  j.client_order_ref,
  j.claim_no,                                                                         -- LOCAL
  j.insured_name,                                                                     -- LOCAL
  j.daily_rate,
  c.client_id,
  c.client_name,
  c.client_type,
  j.address || COALESCE(', ' || j.city, '') || COALESCE(', ' || j.state, '') || COALESCE(' ' || j.zip, '') AS street_address,
  j.street_name,
  COALESCE(j.zensched_label, 'Dry-out - ' || COALESCE(j.street_name, j.job_no))       AS zensched_location_name,
  'Dry-out ' || j.job_no || ' - ' || COALESCE(j.street_name, 'site')                  AS zensched_event_title,
  j.access_notes                                                                      AS job_access_notes,
  j.zensched_location_id,
  CASE WHEN j.zensched_location_id IS NULL THEN 1 ELSE 0 END                          AS needs_location,
  COALESCE(v.zensched_event_id, j.zensched_event_id)                                  AS zensched_event_id,
  j.event_valid_until,
  CASE WHEN j.event_valid_until IS NULL OR j.event_valid_until < v.visit_date THEN 1 ELSE 0 END AS event_needs_roll,
  v.zensched_shift_id,
  CASE WHEN v.zensched_shift_id IS NULL THEN 1 ELSE 0 END                             AS needs_shift,
  v.technician_id,
  n.technician_name,
  n.zensched_worker_id,
  (SELECT COUNT(*) FROM rooms r WHERE r.job_id = j.job_id AND r.is_active = 1)        AS room_count,
  'loc-job-' || j.job_id                                                              AS loc_idempotency_key,
  'shift-job-' || j.job_id || '-' || strftime('%Y%m%d', v.visit_date)                  AS shift_idempotency_key,
  v.notes
FROM daily_visits v
JOIN jobs j ON j.job_id = v.job_id
JOIN clients c ON c.client_id = j.client_id
LEFT JOIN technicians n ON n.technician_id = v.technician_id
WHERE v.status = 'planned'
  AND j.status IN ('intake', 'drying')
  AND v.visit_date BETWEEN date('now', 'localtime') AND date('now', 'localtime', '+6 days')
ORDER BY v.scheduled_start;

-- Drying jobs whose current ZenSched event expires within 14 days (or has none).
-- Roll these proactively before the next week's visits fall off the window.
CREATE VIEW IF NOT EXISTS events_expiring AS
SELECT
  j.job_id,
  j.job_no,
  j.street_name,
  j.address,
  j.zensched_label,
  j.zensched_location_id,
  j.zensched_event_id,
  j.event_valid_until,
  c.client_name
FROM jobs j
JOIN clients c ON c.client_id = j.client_id AND c.is_active = 1
WHERE j.status = 'drying'
  AND (j.event_valid_until IS NULL OR j.event_valid_until <= date('now', 'localtime', '+14 days'))
ORDER BY j.event_valid_until;

-- Open drying jobs — the morning board. Lead with jobs that have no visit
-- today, then rooms still above target.
CREATE VIEW IF NOT EXISTS jobs_drying AS
SELECT
  j.job_id,
  j.job_no,
  j.status,
  j.water_class,
  j.water_category,
  j.loss_date,
  j.monitor_start,
  CAST(julianday(date('now', 'localtime')) - julianday(COALESCE(j.monitor_start, j.loss_date, date('now', 'localtime'))) AS INTEGER) AS days_open,
  j.daily_rate,
  j.client_order_ref,
  j.claim_no,                                                                         -- LOCAL
  j.insured_name,                                                                     -- LOCAL
  c.client_id,
  c.client_name,
  c.client_type,
  j.city,
  j.street_name,
  j.zensched_location_id,
  j.zensched_event_id,
  j.event_valid_until,
  CASE WHEN j.event_valid_until IS NULL OR j.event_valid_until < date('now', 'localtime') THEN 1 ELSE 0 END AS event_needs_roll,
  (SELECT COUNT(*) FROM rooms r WHERE r.job_id = j.job_id AND r.is_active = 1)        AS room_count,
  (SELECT COUNT(*) FROM rooms r
    WHERE r.job_id = j.job_id AND r.is_active = 1
      AND (r.last_moisture_pct IS NULL
           OR r.last_moisture_pct > COALESCE(r.target_moisture_pct,
                (SELECT CAST(value AS REAL) FROM settings WHERE key = 'default_target_moisture_pct'), 16))) AS wet_room_count,
  (SELECT MAX(v.visit_date) FROM daily_visits v
    WHERE v.job_id = j.job_id AND v.status = 'completed')                             AS last_completed,
  (SELECT v.status FROM daily_visits v
    WHERE v.job_id = j.job_id AND v.visit_date = date('now', 'localtime'))            AS today_status,
  CASE WHEN EXISTS (
    SELECT 1 FROM daily_visits v WHERE v.job_id = j.job_id AND v.visit_date = date('now', 'localtime')
  ) THEN 0 ELSE 1 END                                                                 AS needs_today,
  n.technician_name,
  j.notes
FROM jobs j
JOIN clients c ON c.client_id = j.client_id
LEFT JOIN technicians n ON n.technician_id = COALESCE(j.technician_id,
  (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_technician_id' AND value IS NOT NULL))
WHERE j.status = 'drying'
ORDER BY needs_today DESC, wet_room_count DESC, j.monitor_start;

-- Active rooms on drying jobs that are still above target (or have never
-- been read). The "is it dry yet?" query.
CREATE VIEW IF NOT EXISTS rooms_still_wet AS
SELECT
  r.room_id,
  r.job_id,
  j.job_no,
  j.street_name,
  c.client_name,
  r.room_key,
  r.room_label,
  r.target_moisture_pct,
  r.last_moisture_pct,
  r.last_reading_date,
  r.last_meter_type,
  CASE WHEN r.last_moisture_pct IS NULL THEN NULL
       ELSE round(r.last_moisture_pct - COALESCE(r.target_moisture_pct,
            (SELECT CAST(value AS REAL) FROM settings WHERE key = 'default_target_moisture_pct'), 16), 1)
  END                                                                               AS points_above_target,
  j.claim_no                                                                        -- LOCAL
FROM rooms r
JOIN jobs j ON j.job_id = r.job_id AND j.status = 'drying'
JOIN clients c ON c.client_id = j.client_id
WHERE r.is_active = 1
  AND (r.last_moisture_pct IS NULL
       OR r.last_moisture_pct > COALESCE(r.target_moisture_pct,
            (SELECT CAST(value AS REAL) FROM settings WHERE key = 'default_target_moisture_pct'), 16))
ORDER BY j.job_no, r.room_key;

-- Completed (and no-access) visits ready to pull / pack. needs_pull = 1
-- means the Moisture Log submissions have not been read yet (metered, once
-- ever). moisture_readings is the cached JSON after the read.
CREATE VIEW IF NOT EXISTS reports_ready AS
SELECT
  v.visit_id,
  v.visit_date,
  v.status,
  j.job_id,
  j.job_no,
  j.status                                                                          AS job_status,
  j.water_class,
  j.client_order_ref,
  j.claim_no,                                                                       -- LOCAL: for the pack the owner sends the client
  c.client_id,
  c.client_name,
  c.client_type,
  c.billing_email,
  j.address || COALESCE(', ' || j.city, '') || COALESCE(', ' || j.state, '') || COALESCE(' ' || j.zip, '') AS street_address,
  j.street_name,
  n.technician_name,
  v.zensched_event_id,
  v.zensched_shift_id,
  CASE WHEN v.moisture_readings IS NULL THEN 1 ELSE 0 END                           AS needs_pull,
  v.checked_in_at,
  v.checked_out_at,
  v.gps_verified,
  v.checkin_distance_m,
  v.moisture_readings,
  v.rooms_logged,
  v.rooms_still_wet,
  v.report_dc_ids,
  v.invoiced,
  v.notes
FROM daily_visits v
JOIN jobs j ON j.job_id = v.job_id
JOIN clients c ON c.client_id = j.client_id
LEFT JOIN technicians n ON n.technician_id = v.technician_id
WHERE v.status IN ('completed', 'no_access')
ORDER BY v.visit_date DESC;

-- Per-visit moisture pack: completed visits with the cached readings JSON.
-- One row per visit (not per room) because readings arrive as an array.
CREATE VIEW IF NOT EXISTS moisture_log AS
SELECT
  v.visit_id,
  v.visit_date,
  j.job_id,
  j.job_no,
  j.water_class,
  j.water_category,
  j.client_order_ref,
  c.client_name,
  j.street_name,
  j.city,
  n.technician_name,
  v.gps_verified,
  v.checked_in_at,
  v.checked_out_at,
  v.checkin_distance_m,
  v.rooms_logged,
  v.rooms_still_wet,
  v.moisture_readings,
  v.report_dc_ids,
  v.zensched_shift_id,
  v.notes
FROM daily_visits v
JOIN jobs j ON j.job_id = v.job_id
JOIN clients c ON c.client_id = j.client_id
LEFT JOIN technicians n ON n.technician_id = v.technician_id
WHERE v.status = 'completed'
  AND v.moisture_readings IS NOT NULL
ORDER BY v.visit_date DESC, j.job_no;

-- Uninvoiced billable visits grouped by client, with the billing contact
-- and terms. Completed visits bill daily_rate + other; no-access bills
-- trip + other (see billable_visits).
CREATE VIEW IF NOT EXISTS receivables_by_client AS
SELECT
  c.client_id,
  c.client_name,
  c.client_type,
  c.contact_name,
  c.billing_email,
  c.payment_terms_days,
  COUNT(b.visit_id)                                 AS visit_count,
  SUM(CASE WHEN b.status = 'completed' THEN 1 ELSE 0 END) AS completed_count,
  SUM(CASE WHEN b.status = 'no_access' THEN 1 ELSE 0 END) AS no_access_count,
  SUM(b.billable_total)                             AS total_billable,
  MIN(b.visit_date)                                 AS first_date,
  MAX(b.visit_date)                                 AS last_date
FROM billable_visits b
JOIN clients c ON c.client_id = b.client_id
WHERE b.invoiced = 0
  AND b.status IN ('completed', 'no_access')
  AND b.billable_total > 0
GROUP BY c.client_id
ORDER BY total_billable DESC;

-- Unpaid invoices with aging. days_past_due is negative while not yet due.
--   current : not yet due
--   30      : 1-30 days past due
--   60      : 31-60 days past due
--   90+     : more than 60 days past due (chase now)
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  i.invoice_id,
  i.invoice_number,
  c.client_id,
  c.client_name,
  c.client_type,
  c.contact_name,
  c.billing_email,
  c.payment_terms_days,
  i.invoice_date,
  i.due_date,
  i.sent_date,
  i.total_amount,
  CAST(julianday(date('now', 'localtime')) - julianday(i.due_date) AS INTEGER) AS days_past_due,
  CASE
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 0  THEN 'current'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 30 THEN '30'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 60 THEN '60'
    ELSE '90+'
  END                                               AS aging_bucket,
  CASE WHEN i.due_date < date('now', 'localtime') THEN 1 ELSE 0 END AS overdue
FROM invoices i
JOIN clients c ON c.client_id = i.client_id
WHERE i.paid = 0
ORDER BY i.due_date;
