# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for a first week of operation, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

The business is **High Plains Restoration**, a solo dry-out shop (Jordan Hale) in Denver, Colorado, Mountain time (`-06:00` in September). IDs and responses are illustrative. ZenSched IDs are integers. Watch what does **not** cross to ZenSched: the insureds' names, claim numbers, policy numbers, gate codes. ZenSched sees `Dry-out - Willow Ln`, a street address, `Dry-out J-2026-0001 - Willow Ln`, and a Moisture Log. This is not an IICRC certificate and not Xactimate.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My Dry-Out Co, timezone_offset = -05:00, state = NULL,
    default_technician_id = NULL, default_visit_time = 09:00,
    default_visit_minutes = 45, default_target_moisture_pct = 16,
    invoice_due_days = 30, invoice_prefix = INV, moisture_form_id = NULL,
    event_window_days = 60
sqlite_query:   SELECT * FROM jobs_drying;             → (none)
sqlite_query:   SELECT * FROM rooms_still_wet;         → (none)
sqlite_query:   SELECT * FROM visits_upcoming;         → (none)
```

## "We're High Plains Restoration in Denver, Mountain time. It's just me, Jordan Hale, jordan@highplains.example, 303-555-0144. My IICRC WRT is WRT-44018. Set me up."

```
sqlite_execute: UPDATE settings SET value = 'High Plains Restoration' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '-06:00' WHERE key = 'timezone_offset';
sqlite_execute: UPDATE settings SET value = 'CO' WHERE key = 'state';
```

Agent (first metered call this session, rule 10):

> Saved. Since you're the tech on the phone, I need to invite you to ZenSched as a worker so your visits show up in the app; that's a one-time $0.25. If your account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
worker_invite:
  email: "jordan@highplains.example"
  first_name: "Jordan"
  last_name: "Hale"
  idempotency_key: "worker-jordan@highplains.example"
  → worker_id: 701, status: "invited", invitation_sent: true
    billing: { meter: "worker_invite", units: 1, price: 0.25 }

sqlite_execute:
  INSERT INTO technicians (technician_name, email, phone, zensched_worker_id, is_owner, license_no)
  VALUES ('Jordan Hale', 'jordan@highplains.example', '303-555-0144', 701, 1, 'WRT-44018');
  → lastInsertRowid = 1

sqlite_execute: UPDATE settings SET value = '1' WHERE key = 'default_technician_id';
```

The license number stays in `technicians.license_no`; ZenSched got a name and an email.

> You're invited; install the app from the email. Your visits will land on your own phone. Next, the Moisture Log: it's free to create and the tech submits it once per room — room, moisture %, meter type, a photo of the meter, notes. No signature pad, no insured name, no claim number. Want me to set it up now?

Owner: *"yes"*

```
form_create:
  title: "Moisture Log"
  idempotency_key: "form-moisture-log"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Moisture log", "identifier": "sec_moisture", "text": "One submission per room. Photograph the meter. Do not write the insured's name, claim number, or policy number."},
  {"type": "select", "label": "Room", "identifier": "room", "required": true,
   "options": ["Living room", "Dining room", "Kitchen", "Bedroom 1", "Bedroom 2", "Bedroom 3", "Bathroom 1", "Bathroom 2", "Hallway", "Basement", "Garage", "Laundry", "Closet", "Other"]},
  {"type": "number", "label": "Moisture %", "identifier": "moisture_pct", "required": true},
  {"type": "select", "label": "Meter type", "identifier": "meter_type", "required": true,
   "options": ["Pin", "Pinless", "Thermo-hygrometer", "Other"]},
  {"type": "photo", "label": "Meter photo", "identifier": "meter", "max_images": 2, "stamp_photos": true},
  {"type": "textarea", "label": "Notes", "identifier": "notes"}
]
```

```
  → form_id: 501, fields: [ ...6 fields echoed with identifiers... ]

sqlite_execute: UPDATE settings SET value = '501' WHERE key = 'moisture_form_id';
```

> Moisture Log created. I'll attach it to every job automatically. One policy question: you'll often wait for the occupant and park on the street; want me to allow early check-in and set the check-in radius to 150 m?

Owner: *"yes"*

```
policy_update:
  policy_id: 0
  settings_json: "{\"checkin_radius_m\": 150, \"checkin_slack_min\": 20, \"checkout_reminder_min_after\": 15}"
  → policy_id: 0, updated: [ "checkin_radius_m", "checkin_slack_min", "checkout_reminder_min_after" ]
```

The radius is on the **policy**, not on any location.

## "Summit TPA just sent this. Book it. Daily until dry."

> *WO TPA-8847 — class 2 / cat 1 kitchen, living, basement water — DOL 9/5/2026 — start daily monitoring Tue Sep 8, 2026 9:00 AM MT until dry — 412 Willow Ln, Boulder, CO 80302 — Claim 26-448311 — Insured: Luis Ortega — Policy HO-77410 — $175/day — Note: call from drive, gate 3312.*

The agent parses: client Summit TPA (`tpa`), order ref `TPA-8847`, class_2, cat_1, insured Luis Ortega, claim 26-448311, policy HO-77410, address, Tue 9/8 09:00, $175/day, rooms kitchen / living_room / basement, gate. Claim number, policy, and insured are **stored locally only**.

```
sqlite_query: SELECT client_id, payment_terms_days FROM clients WHERE client_name LIKE 'Summit%';   → (none)

sqlite_execute:
  INSERT INTO clients (client_name, client_type, billing_email, payment_terms_days, default_daily_rate, default_trip_fee)
  VALUES ('Summit TPA', 'tpa', 'ap@summittpa.example', 30, 175, 75);
  → lastInsertRowid = 1
```

> I don't have Summit TPA as a client yet. I've added them as a TPA with a $175/day monitoring / $75 no-access trip default; I've assumed net 30. Tell me if their terms differ.

```
sqlite_execute:
  INSERT INTO jobs (client_id, client_order_ref, water_class, water_category, loss_date, monitor_start,
                    address, city, state, zip, street_name, access_notes, visit_time, daily_rate,
                    claim_no, policy_no, insured_name, status)
  VALUES (1, 'TPA-8847', 'class_2', 'cat_1', '2026-09-05', '2026-09-08',
          '412 Willow Ln', 'Boulder', 'CO', '80302', 'Willow Ln', 'Call from drive. Gate 3312.', '09:00', 175,
          '26-448311', 'HO-77410', 'Luis Ortega', 'drying');
  → lastInsertRowid = 1
  (triggers fill: job_no J-2026-0001, trip_fee 75, duration_minutes 45,
   zensched_label 'Dry-out - Willow Ln')

sqlite_execute: INSERT INTO rooms (job_id, room_key, room_label) VALUES (1, 'kitchen', 'Kitchen');
sqlite_execute: INSERT INTO rooms (job_id, room_key, room_label) VALUES (1, 'living_room', 'Living room');
sqlite_execute: INSERT INTO rooms (job_id, room_key, room_label) VALUES (1, 'basement', 'Basement');
  (triggers fill target_moisture_pct = 16)

sqlite_query: SELECT visit_date, start_iso, end_iso, zensched_location_name, zensched_event_title,
                     street_address, needs_location, event_needs_roll, zensched_worker_id,
                     loc_idempotency_key, shift_idempotency_key, room_count
              FROM visits_due_this_week WHERE job_id = 1;
  → 2026-09-08 | 2026-09-08T09:00:00-06:00 | 2026-09-08T09:45:00-06:00
    | Dry-out - Willow Ln | Dry-out J-2026-0001 - Willow Ln
    | 412 Willow Ln, Boulder, CO 80302 | needs_location 1 | event_needs_roll 1
    | worker 701 | loc-job-1 | shift-job-1-20260908 | 3 rooms
    (plus one row per later day in the 7-day window)
```

> Putting this on ZenSched costs $0.03 to geocode the address; each monitoring day then costs about $0.80 in GPS check-in/out plus reading 3 room logs with photos ($0.83 the first day). OK to proceed for this job?

Owner: *"yes"*

```
location_create:
  name: "Dry-out - Willow Ln"
  street_address: "412 Willow Ln, Boulder, CO 80302"
  checkin_radius_m: 100
  idempotency_key: "loc-job-1"
  → location_id: 9201, lat: 40.0150, lng: -105.2705, pin_quality: "street",
    radius_note: "Check-in radius is enforced by the talent policy ...",
    billing: { meter: "geocode", units: 1, price: 0.03 }

sqlite_execute: UPDATE jobs SET zensched_location_id = 9201 WHERE job_id = 1;

event_create:
  location_id: 9201
  title: "Dry-out J-2026-0001 - Willow Ln"
  start_date: "2026-09-08"
  end_date:   "2026-11-06"
  idempotency_key: "event-job-1-20260908"
  → event_id: 7201

form_assign:
  form_id: 501
  event_id: 7201
  idempotency_key: "assign-moisture-7201"
  → status: "assigned", form_id: 501, event_id: 7201, policy_id: 0

sqlite_execute: UPDATE jobs SET zensched_event_id = 7201, event_valid_until = '2026-11-06' WHERE job_id = 1;
```

Window is 60 days inclusive: `date('2026-09-08', '+59 days')` = `2026-11-06`. Not an event per visit.

Then for each due day this week (shown for Tue only):

```
sqlite_execute: INSERT INTO daily_visits (job_id, visit_date, status) VALUES (1, '2026-09-08', 'planned');
  → lastInsertRowid = 1
  (triggers fill: scheduled_start 2026-09-08T09:00, duration 45, technician_id 1, other_fee 0)

shift_create:
  event_id: 7201
  worker_id: 701
  start: "2026-09-08T09:00:00-06:00"
  end:   "2026-09-08T09:45:00-06:00"
  idempotency_key: "shift-job-1-20260908"
  → shift_id: 89101, status: "scheduled", forms_installed: [501]

sqlite_execute: UPDATE daily_visits SET zensched_event_id = 7201, zensched_shift_id = 89101 WHERE visit_id = 1;
```

(Same insert + `shift_create` for Wed–Mon of the window, keys `shift-job-1-20260909` …)

Nothing about Luis Ortega, claim 26-448311, policy HO-77410, or the gate is in `name`, `title`, or `notes`.

> Opened **J-2026-0001**: class 2 (cat 1) at Willow Ln, Boulder, Summit TPA order TPA-8847. Daily 9:00–9:45 starting Tue Sep 8, kitchen + living + basement on the Moisture Log. $175/day. This week's visits are on your phone. Luis Ortega, claim 26-448311, and policy HO-77410 are only on your computer; ZenSched sees "Dry-out J-2026-0001 - Willow Ln".

## Tuesday: first monitoring day

8:52, outside 412 Willow Ln, in the ZenSched app: Jordan taps **Check in** (GPS: 14 m from the pin, verified, $0.10). Opens **Moisture Log** three times:

1. Room = Kitchen; Moisture % = 22; Meter type = Pin; meter photo × 2; Notes = "Cabinet toe-kick, still beading."
2. Room = Living room; Moisture % = 18; Meter type = Pin; meter photo × 1.
3. Room = Basement; Moisture % = 28; Meter type = Pinless; meter photo × 1; Notes = "North-east corner, pad still dark."

Submits each. **Check out** 9:40 ($0.10).

## "Willow is done for today. Pull today's readings."

```
shift_status: shift_id 89101
  → status "checked_out", actual_in "2026-09-08T08:52:10-06:00", actual_out "2026-09-08T09:40:20-06:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 14 },
               { type: "out", gps_verified: true, distance_from_site_m: 11 } ]
(free)
```

> Reading the 3 Moisture Logs for J-2026-0001 costs $0.45 because they have meter photos. It bills once; after this I answer from the local record and any export pack is free. OK?

Owner: *"go"*

```
form_submissions:
  form_id: 501
  event_id: 7201
  limit: 50
  → submissions: [
      { submission_id: 3501, worker_id: 701, event_id: 7201, submitted_at: "2026-09-08 09:10:12",
        data: { room: "kitchen", moisture_pct: 22, meter_type: "pin",
                notes: "Cabinet toe-kick, still beading." },
        media: [
          { field_id: 5, cdn_url: "https://cdn.zensched.com/m/.../k1.jpg" },
          { field_id: 5, cdn_url: "https://cdn.zensched.com/m/.../k2.jpg" }
        ] },
      { submission_id: 3502, submitted_at: "2026-09-08 09:22:04",
        data: { room: "living_room", moisture_pct: 18, meter_type: "pin" },
        media: [ { field_id: 5, cdn_url: "https://cdn.zensched.com/m/.../l1.jpg" } ] },
      { submission_id: 3503, submitted_at: "2026-09-08 09:35:40",
        data: { room: "basement", moisture_pct: 28, meter_type: "pinless",
                notes: "North-east corner, pad still dark." },
        media: [ { field_id: 5, cdn_url: "https://cdn.zensched.com/m/.../b1.jpg" } ] }
    ], count: 3, billing: { meter: "form_media", units: 3, price: 0.45 }

sqlite_execute:
  UPDATE daily_visits
  SET status = 'completed',
      moisture_readings = '[{"room":"kitchen","moisture_pct":22,"meter_type":"pin","photo_urls":["https://cdn.zensched.com/m/.../k1.jpg","https://cdn.zensched.com/m/.../k2.jpg"],"notes":"Cabinet toe-kick, still beading.","submission_id":3501},{"room":"living_room","moisture_pct":18,"meter_type":"pin","photo_urls":["https://cdn.zensched.com/m/.../l1.jpg"],"notes":null,"submission_id":3502},{"room":"basement","moisture_pct":28,"meter_type":"pinless","photo_urls":["https://cdn.zensched.com/m/.../b1.jpg"],"notes":"North-east corner, pad still dark.","submission_id":3503}]',
      rooms_logged = 3, rooms_still_wet = 3,
      report_dc_ids = '[3501,3502,3503]',
      checked_in_at = '2026-09-08T08:52:10-06:00', checked_out_at = '2026-09-08T09:40:20-06:00',
      gps_verified = 1, checkin_distance_m = 14
  WHERE visit_id = 1;

sqlite_execute: UPDATE rooms SET last_moisture_pct = 22, last_reading_date = '2026-09-08', last_meter_type = 'pin' WHERE job_id = 1 AND room_key = 'kitchen';
sqlite_execute: UPDATE rooms SET last_moisture_pct = 18, last_reading_date = '2026-09-08', last_meter_type = 'pin' WHERE job_id = 1 AND room_key = 'living_room';
sqlite_execute: UPDATE rooms SET last_moisture_pct = 28, last_reading_date = '2026-09-08', last_meter_type = 'pinless' WHERE job_id = 1 AND room_key = 'basement';
```

All three rooms are above the 16% target, so `rooms_still_wet` still lists them. Job stays `drying`.

> J-2026-0001 Tuesday closed. Kitchen 22% pin (target 16, wet), living 18% pin (wet), basement 28% pinless (wet). GPS-verified on site 8:52–9:40 (14 m from the pin). $175 is now receivable from Summit TPA, net 30. This is a moisture-monitoring record, not a drying certificate. Say "export pack" when you want the URLs for their file.

## Several days later: rooms hit target

(Later visits recorded the same way. Living hits 15%, kitchen 16%, basement 15%.)

## "What's still wet on J-2026-0001?"

```
sqlite_query: SELECT * FROM rooms_still_wet WHERE job_id = 1;
  → (none)
sqlite_query: SELECT room_key, room_label, last_moisture_pct, target_moisture_pct, last_reading_date
              FROM rooms WHERE job_id = 1;
  → kitchen 16 / 16, living_room 15 / 16, basement 15 / 16
```

> All three rooms are at or under 16%. Want me to mark J-2026-0001 dry? I will not flip it unless you say so.

Owner: *"Mark it dry."*

```
sqlite_execute: UPDATE jobs SET status = 'dry', dry_date = date('now', 'localtime') WHERE job_id = 1;
```

Then `shift_cancel` + `UPDATE daily_visits SET status = 'cancelled'` for leftover planned days (reason `"job dry"` — no insured name).

> J-2026-0001 marked dry. Cancelled the leftover phone visits. Completed days are ready to invoice.

## "Export pack for J-2026-0001, then invoice Summit TPA."

```
sqlite_query: SELECT * FROM moisture_log WHERE job_id = 1;
  → one row per completed day: visit_date, gps, rooms_logged, moisture_readings JSON
```

> High Plains Restoration — moisture pack — J-2026-0001
> To: Summit TPA (order TPA-8847)    Class 2 / cat 1
> This is a daily moisture-monitoring record, not an IICRC drying certificate and not an estimate.
>
> Tue Sep 8, 2026  8:52–9:40 MT  GPS-verified 14 m from pin
>   Kitchen      22%  pin      k1.jpg, k2.jpg
>   Living room  18%  pin      l1.jpg
>   Basement     28%  pinless  b1.jpg
> … (later days)
>
> Insured name and policy number are not on this pack.

```
sqlite_query: SELECT * FROM receivables_by_client;
  → Summit TPA | tpa | ap@summittpa.example | net 30
    | N visits completed | N * 175.00 | 2026-09-08 .. dry_date

sqlite_execute:
  INSERT INTO invoices (client_id, invoice_date, due_date, total_amount, line_items)
  SELECT b.client_id, date('now', 'localtime'),
         date('now', 'localtime', '+' || (SELECT payment_terms_days FROM clients WHERE client_id = 1) || ' days'),
         SUM(b.billable_total),
         json_group_array(json_object('job_no', b.job_no, 'date', b.visit_date,
                                      'class', b.water_class, 'status', b.status, 'order_ref', b.client_order_ref,
                                      'daily_rate', b.daily_rate, 'trip_fee', b.trip_fee, 'other_fee', b.other_fee,
                                      'billable', b.billable_total, 'rooms_logged', b.rooms_logged,
                                      'shift_id', b.zensched_shift_id))
  FROM billable_visits b WHERE b.invoiced = 0 AND b.client_id = 1 AND b.billable_total > 0
  GROUP BY b.client_id;
sqlite_execute: UPDATE daily_visits SET invoiced = 1 WHERE invoiced = 0 AND visit_id IN
                (SELECT visit_id FROM billable_visits WHERE client_id = 1 AND invoiced = 0 AND billable_total > 0);
sqlite_query:   SELECT invoice_number, invoice_date, due_date, total_amount FROM invoices
                WHERE invoice_id = last_insert_rowid();
  → INV-2026-0001 | (today) | (today + 30) | (N * 175)
```

> Here's the Summit TPA invoice, ready for their payables portal. No insured names, claim numbers, or policy numbers. The order ref identifies the file. Say "sent" when it's submitted.

## Summary of who stored what

| Thing | Where | Why |
|---|---|---|
| Luis Ortega, claim number, policy number, gate code | SQLite **only** (`jobs.claim_no`, `insured_name`, `policy_no`, `access_notes`) | Claim PII never reaches ZenSched |
| Summit TPA: terms, billing email, default rates | SQLite (`clients`) | Billing; ZenSched does not model clients or fees |
| The job (address, class, rooms, current event / location ids, `event_valid_until`) | SQLite (`jobs`, `rooms`) | Recurrence + 60-day roll live here |
| `Dry-out - Willow Ln` and the street address and GPS pin | ZenSched (ID in `jobs`) | Needed for geofenced check-in; label carries no insured identity |
| One ≤60-day event (`Dry-out J-2026-0001 - Willow Ln`), rolled if the job runs longer | ZenSched (ID in `jobs`) | Shifts hang off events; title is job number + street only |
| One shift per calendar day | ZenSched (ID in `daily_visits`) | Live schedule and push notification; never copied |
| Jordan as a ZenSched worker | ZenSched (ID in `technicians`, `is_owner = 1`) | Solo mode: the owner is the tech on the phone |
| GPS punches, arrival time, distance from pin | ZenSched (originals); stamps copied once to `daily_visits` | Proof of on-site arrival, answered from SQLite afterwards |
| The Moisture Log form | ZenSched (ID in `settings`) | Installed on the phone per shift; no signature field; no insured fields |
| Three Moisture Log submissions (one per room) | ZenSched (originals); `moisture_readings` JSON + `report_dc_ids` in `daily_visits` | Read once (metered), then the pack is free |
| Check-in policy (150 m radius, 20 min early check-in, 15 min check-out reminder) | ZenSched (policy 0) | Radius is enforced by the policy, not per location |
| Fees per visit, billable totals, one invoice, aging | SQLite (`jobs`, `billable_visits`, `invoices`, `invoices_outstanding`) | Receivables from the TPA |
