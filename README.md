# ZenSched Dry-Out Reference Kit

A copy-pasteable setup for a solo water-damage restoration tech, or a 2–8 tech shop, that wants an AI assistant to run dry-out job intake, GPS-verified daily visits at the loss address until the structure is dry, a Moisture Log (room, moisture %, meter type, meter photo), an export pack for the insurer or TPA, and receivables. ZenSched handles the phone app, the GPS check-in at the loss address, one rolling event per job (renewed every 60 days), one shift per daily visit, and the Moisture Log form. A small local database on your computer holds your clients, jobs (with the insured's name, claim number, and policy number), rooms, each day's readings, invoices, and your roster.

**You do not need to know how to program or write SQL to use this.** You paste a work order into your AI assistant ("Summit TPA just sent this, daily until dry"), ask "what's today", "what's still wet on Willow", "pull today's readings", "export pack for J-2026-0001", "mark it dry", "invoice Summit", "who owes me money", and the AI does the work using two tools you set up once. Setup takes about 15 minutes and is the only technical part.

If you *are* a developer, skip to [For developers](#for-developers).

## This is not an IICRC certificate, not Xactimate, and there is no BAA — read this first

**What this kit is:** a way for a restoration shop to get every monitoring day onto the phone from a pasted work order, prove GPS-verified arrival, record what the meter said in each room, and turn those records into a pack the TPA can file, plus invoices you can actually chase, with an AI assistant doing the clerical work.

**What it is not:**

- **It is not an IICRC S500 psychrometric package and it is not a drying certificate.** Nothing here computes GPP, grains, dew point, or a manufacturer's dry standard from ambient readings. The Moisture Log is room + moisture % + meter type + a photo of the meter. If a carrier wants the official drying record, you still write that on the form you already use.
- **It is not Xactimate / XactAnalysis / Symbility.** Nothing writes a scope, a line item, equipment days, or a replacement-cost figure. A work order that *arrived* from Xactimate is treated as a dispatch ticket only: the AI extracts the address, class, rooms, and rate, and **stashes the claim number locally**.
- **There is no BAA.** ZenShows / ZenSched is not a HIPAA business associate. Use this kit for property water losses. Do not run medical-records retrieval or workers-comp health visits on it. Insured name, claim number, and policy number are stored locally as ordinary PII, not as PHI under a BAA.
- **Meter photos can carry a burned-in stamp (opt-in).** The kit sets `"stamp_photos": true` on the meter photo field. After upload, ZenSched burns readable date, time, and GPS onto the JPEG from capture metadata. Gallery picks without EXIF may stamp date/time only.
- **It does not decide "dry."** Room readings vs a shop target (default 16%) are facts. The owner marks the job dry. The kit will *offer* when every room is at or under target; it will not flip the status on its own.

If any of that is a deal-breaker, this kit is not for you. If you want a phone schedule with GPS proof at the loss, a daily moisture log you can pack for the TPA, and receivables you can chase, read on.

## PHI / PII boundary

Everything that identifies an insured or a claim file lives only in the local database:

| Field | Column | Goes to ZenSched? | Goes on the invoice / pack? |
|---|---|---|---|
| Insured name | `jobs.insured_name` | **Never** | **Never** |
| Policy number | `jobs.policy_no` | **Never** | **Never** |
| Claim number | `jobs.claim_no` | **Never** | Only if you ask — the TPA already has it |
| Client's file / work-order number | `jobs.client_order_ref` | No | Yes (identifies the file to them) |
| Your job number | `jobs.job_no` | Yes, in the event title | Yes |
| Loss-site street address | `jobs.address` | Yes (required for the geofence) | City / street only on the pack |
| Gate codes / key / tenant hints | `jobs.access_notes` | **Never** | **Never** |

ZenSched titles are always `Dry-out {job_no} - {street}` (for example `Dry-out J-2026-0001 - Willow Ln`). Location labels are `Dry-out - {street}`. `SKILL.md` forbids the AI from putting any local-only column into any ZenSched field, including cancellation reasons (techs see those). The Moisture Log has **no** insured-name, claim-number, or policy fields.

You are still responsible for your own privacy obligations (the local database, your email, your phone). This kit narrows what a third party sees; it does not make you compliant by itself. There is no BAA.

## What lives where

**ZenSched (source of truth for where you were and when):**

- Locations (one per job / loss address; the check-in radius is a **policy** setting, not per location)
- Workers (you, in solo mode; you plus your techs, each with the mobile app)
- Events (one "Dry-out" event per job address, **renewed every 60 days**)
- Shifts (one per daily visit, 45 minutes by default, with a push notification to the tech)
- GPS punches (check-in / check-out with distance-from-the-pin verification)
- The Moisture Log form (room, moisture %, meter type, meter photo, notes) and every submission with its photos

**Local SQLite database (`dryout-ops.db`, on your computer):**

- Clients: insurers, TPAs, homeowners, with payment terms and default daily / trip rates
- Jobs: loss address, water class, **claim number / policy / insured name (local only)**, status (`drying` until you mark it dry), the current ZenSched location and event ids, `event_valid_until`
- Rooms on each job (mapped to the Moisture Log's fixed room list)
- Daily visits: each day's window, the ZenSched shift id, GPS stamps copied once, `moisture_readings` JSON from the form
- Invoices per client with aging
- Technicians (you, and anyone you dispatch); license numbers **never leave your computer**
- Your settings (timezone, default tech, default visit time, target moisture %, invoice terms and prefix, Moisture Log form id)

**Never duplicated:** the live schedule, punches, and photos stay in ZenSched. The local database stores *references* to them plus the few facts you need to answer "was I on site", "what's still wet", and "who owes me" without paying to re-read records.

## How it works day to day

Your AI assistant has two sets of tools:

1. **ZenSched tools** (`location_create`, `event_create`, `shift_create`, `shift_status`, `form_submissions`, ...) that talk to ZenSched over the internet.
2. **A SQLite tool** (`sqlite_query`, `sqlite_execute`) that reads and writes `dryout-ops.db` on your computer.

When you paste a work order, the AI extracts the client, file number, water class, insured, claim number, address, rooms, first day, and rate; **stashes claim number / policy / insured in SQLite only**; adds the client if new; saves the job as `J-2026-0001`; creates one location at the loss address; rolls a ≤60-day event titled `Dry-out J-2026-0001 - Willow Ln`; attaches the Moisture Log; and puts this week's daily visits on the phone. You see today's stop, check in (GPS-verified), submit the Moisture Log once per room (meter photo), check out. In the evening you say "pull today's readings" and the AI reads each room log **once** (metered, then free forever), updates each room, and tells you what is still wet. Recurrence is **daily until you mark the job dry** — "schedule this week" expands the next 7 days for every `drying` job. A job that runs past 60 days gets a new event on the same location (`event_valid_until`). "Export pack for J-2026-0001" writes the readings and GPS facts for the TPA. "Invoice Summit" produces a plain-text invoice under their terms. You never run SQL yourself. `SKILL.md` in this repo is the instruction sheet that teaches the AI how to do all of this; you paste it into your AI tool once.

## Setup

### 0. What you need

- **An AI tool that supports MCP.** These instructions use Claude Desktop (Windows or Mac). Cursor works too.
- **Node.js 20 or newer.** The SQLite tool runs on it. Download the LTS installer from [nodejs.org](https://nodejs.org/) and run it with the defaults. This is the only software install.
- You do **not** need the `sqlite3` command-line program, Python, or Git.

### 1. Make a folder for your data

Create a folder where the database will live and write down its full path. Examples:

- Windows: `C:\Users\YourName\dryout-ops`
- Mac: `/Users/yourname/dryout-ops`

The database file will be created automatically inside this folder the first time the AI uses it. This folder will contain insured names, claim numbers, and policy numbers; keep it on an encrypted, backed-up disk, not in a shared folder.

### 2. Add both tools to your AI's config file

Open the MCP configuration file for your AI tool:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json` (paste that into the File Explorer address bar)
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json` (in Claude Desktop: Settings → Developer → Edit Config)
- **Cursor:** Settings → MCP → Add new global MCP server

Paste in the contents of `mcp.json.example` from this repo, then change one line, the `SQLITE_PATH`, to point at your folder from step 1 plus `\dryout-ops.db` (Windows) or `/dryout-ops.db` (Mac):

```json
{
  "mcpServers": {
    "zensched": {
      "url": "https://mcp.zensched.com/mcp",
      "headers": { "Authorization": "Bearer zsc_your_key_here" }
    },
    "dryout-ops-db": {
      "command": "npx",
      "args": ["-y", "easy-sqlite-mcp"],
      "env": { "SQLITE_PATH": "/Users/yourname/dryout-ops/dryout-ops.db" }
    }
  }
}
```

**Windows path gotcha:** inside a JSON file every backslash must be doubled. Write `"C:\\Users\\YourName\\dryout-ops\\dryout-ops.db"`, not `"C:\Users\..."`. A single backslash will silently break the config.

**Leave `zsc_your_key_here` exactly as it is for now.** You do not have a key yet. The ZenSched tools that create your account work without one, and you will fill this in during step 3.

Save the file and **fully quit and reopen** your AI tool (on Mac, Cmd-Q; on Windows, right-click the tray icon → Quit). It only reads this file on startup.

### 3. Create your ZenSched account

In a new chat, type:

> Call `account_create` with org_name "My Dry-Out Co" (use my real business name if I told you one). Show me the `zsc_` key it returns.

Copy the `zsc_` key. Go back to the config file from step 2, replace `zsc_your_key_here` with your real key, save, and fully quit and reopen the AI tool again.

Keep the key private; it is the password to your account.

### 4. Create the database tables

Open `schema.sql` from this repo in any text editor, copy the whole thing, and paste it into the chat with this message in front of it:

> Create these tables in my dryout-ops database. Run each statement one at a time using the SQLite tool, then list the tables to confirm.

The AI will run each statement and confirm the tables exist. The `dryout-ops.db` file now exists in your folder with default settings (09:00 visits, 45 minutes, 16% target, net 30) you can change.

If you happen to have the `sqlite3` command-line tool, `sqlite3 dryout-ops.db < schema.sql` does the same thing, but it is not required.

### 5. Teach the AI the workflow

Paste the contents of `SKILL.md` into your AI tool as standing instructions. In Claude Desktop, create a Project and put it in the project instructions; in Cursor, save it as a rule. Then tell it your basics once:

> We're High Plains Restoration in Denver, Mountain time. It's just me, Jordan Hale, jordan@example.com. Set me up.

It writes those to the `settings` table, **invites you to ZenSched as a worker** (you are the tech on the phone; $0.25, one time), creates the Moisture Log form on ZenSched (free), and saves the form id so every visit gets it automatically. Then say "add my tech Reese Okonkwo, reese@example.com" for each person you dispatch.

**Check-in radius.** ZenSched enforces the radius through the account's **policy**, not per address, and with geofencing on it raises anything under 100 m to about 91 m (300 ft), so a house and its driveway are covered as is. For apartments, rural driveways, and occupied homes where you park on the street, ask the AI to "set the check-in radius to 150 m" or 300 m (`policy_update`), or to move the pin onto the entrance (`location_update`, free; the job keeps it). Techs often wait for the occupant: ask for "allow check-in 20 minutes before the shift" (`checkin_slack_min`). `remote_checkin` turns GPS verification off for every visit and should be a last resort, because it also turns off the proof.

**Forgotten check-outs.** Ask the AI to "remind me to check out 15 minutes after the shift ends" (`checkout_reminder_min_after`).

### 6. Funding (only when asked)

The first 200 ZenSched tool calls per day are free. Some things are metered: creating a location (geocoding, $0.03; once per job), inviting a worker ($0.25, including yourself), each GPS-verified check-in or check-out ($0.10), and reading a Moisture Log ($0.05, or $0.15 when it has a meter photo, which this form usually does; each record is billed **once, ever**). One visit is one shift but **one form submission per room**, so a 4-room house with photos is $0.20 + $0.60 = **$0.80** after the address is cached ($0.83 the first day). When a metered call happens without funds, the AI will get a `payment_required` response and tell you how to add the $5 activation deposit, which is credited to your balance. You will not be charged without seeing this first.

Ten monitoring days, 4 rooms with photos, is about $8 in reads + $2 in punches. The AI states the cost before it spends. Skip the meter photo on a room and that submission bills $0.05 instead — insurers usually want the photo.

## Using it

Everything after setup is plain English. Examples:

- (paste a TPA / carrier / homeowner work order) "Book it. Daily until dry."
- "What's today?" / "What's still wet?"
- "Put this week's visits on the phone."
- "Was I on site at Willow?"
- "Pull today's readings."
- "Export pack for J-2026-0001."
- "Mark J-2026-0001 dry."
- "Couldn't get in at Pearl — trip fee."
- "The 9 o'clock moved to 11." / "Move Thursday's Willow visit to Friday."
- "Invoice Summit TPA." / "Invoice everyone."
- "Who owes me money?"
- "Summit paid INV-2026-0001."
- "Add my tech Reese Okonkwo, reese@example.com." / "Give Willow to Reese."

See `QUICKSTART.md` for the first-week walkthrough and `example-workflow.md` for exactly which tools the AI calls behind each of these.

### What "invoice" means here

"Invoice Summit TPA" records the invoice in your database (number, date, due date under that client's terms, total, which visits with their fee breakdown) and the AI writes out a plain-text invoice you can paste into an email or the TPA's payables portal, with a line per visit (your job number, date, water class, their order ref, rooms logged, amount) and, for no access, the GPS-verified arrival. It does **not** generate a PDF, submit it for you, or collect payment. Invoices never carry an insured name, claim number, or policy number; the order ref identifies the file to them. When the client pays, tell the AI ("Summit paid INV-2026-0001") and it marks it paid. "Who owes me money" ages what is open into current / 30 / 60 / 90+ days past due.

### What a visit costs the client vs ZenSched

You bill the *client* your daily monitoring rate (shop default, snapshotted onto the job). ZenSched bills *you* the meters above. They are not the same number. A $175/day monitoring fee does not become $175 to ZenSched.

## Mobile app for technicians

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.zensched.app)
- **iOS:** [TestFlight](https://testflight.apple.com/join/Wp51m5Yq)

In solo mode you invite yourself; the email arrives at your own address, you install the app, and your visits appear as they are booked. Each one shows the address and time (`Dry-out J-2026-0001 - Willow Ln`); you check in on arrival (GPS-verified), submit the Moisture Log once per room, and check out. Other techs get the same email when you add them. There is no signature step — they tap Submit.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AI says it has no ZenSched tools | Config file not saved, or the app was not fully restarted | Check the JSON is valid (paste it into [jsonlint.com](https://jsonlint.com)), then quit and reopen the app |
| AI says it has no SQLite / `dryout-ops-db` tools | Node.js not installed, or bad `SQLITE_PATH` | Install Node.js LTS; on Windows check every backslash is doubled |
| `SQLITE_PATH` points nowhere / "unable to open database" | Folder from step 1 does not exist | Create the folder; the file is created automatically but the folder is not |
| ZenSched tools return an auth error | Key still says `zsc_your_key_here`, or was pasted with a space | Re-paste the key, restart |
| `payment_required` | Metered call with no balance | Follow the instructions in the response; $5 deposit |
| AI creates shifts at the wrong hour | Timezone not set, or daylight saving changed | "Set my timezone offset to -06:00 in settings" (use your own offset; Mountain is -06:00 in summer, -07:00 in winter) |
| Visit not on my phone | Job is drying but this week's shifts were never created (`visits_due_this_week` still lists the days) | "Put this week's visits on the phone" |
| Shift creation fails for dates a couple of months out | The job's 60-day ZenSched event has expired | Say "renew the events"; the AI rolls a new ≤60-day event on the same location and retries |
| Check-in not GPS-verified at an apartment / long drive | You parked outside the policy radius, or the pin is on the road | "Set the check-in radius to 200 m" (`policy_update`), or "move the pin to the entrance" (`location_update`, free). Do **not** ask to widen the radius on that location — the policy enforces it. |
| App would not let me check in 15 minutes early | Early check-in window too small | "Allow check-in 20 minutes before the shift" (`checkin_slack_min`) |
| Forgot to check out | Shift still `checked_in` | Tell the AI the real time; ask for a 15-minute check-out reminder |
| Moisture Log not on the phone | Form not assigned to that job's current event | "Attach the Moisture Log to J-2026-0001" (`form_assign(form_id, event_id=...)`). That installs the form on the shifts already on that event; do **not** cancel and recreate the shift (the recreate would replay the same `shift-job-{job_id}-{YYYYMMDD}` idempotency key and hand back the cancelled shift) |
| Only one room on the form / can't add "Bedroom 4" as its own option | The form is account-wide with a fixed room list | Use key `other` with label `Bedroom 4` on the job's `rooms` row |
| AI refuses to put a claim number on the phone event | Working as intended | Claim numbers stay in SQLite; the title is `Dry-out J-2026-0001 - Willow Ln` |
| AI marked a job dry without being asked | It shouldn't | Re-open it: `status = 'drying'`, `dry_date` NULL; tell it never to flip dry on its own |
| AI asks you to run SQL yourself | It does not have `SKILL.md` loaded | Re-paste `SKILL.md` as project instructions |

If something is confusing or broken in ZenSched itself, ask the AI to call `feedback_submit` with a description. It is free, needs no account, and a human reads every submission.

## For developers

**Architecture.** Two MCP servers, no application code. The agent is the integration layer; `SKILL.md` is the spec it follows. ZenSched is authoritative for operations (schedule, punches, form submissions); SQLite is authoritative for clients, jobs (including all insured / claim PII), rooms, daily visits, billing, and the roster; each side stores only the other's **integer** IDs, plus a per-visit `moisture_readings` JSON, GPS stamps, and photo URL list cached locally because submission reads are metered. The PII boundary is enforced by data placement (insured / claim / policy columns exist only locally, and the views compute the ZenSched-safe `zensched_location_name` / `zensched_event_title` strings) and by `SKILL.md` rules 1–3; there is no technical control stopping a misbehaving agent, so review the rules if you swap models.

**Data model decisions.**

- **Clients → jobs → rooms → daily_visits.** A client is who pays (insurer / TPA / homeowner). A job *is* the loss address (no separate `places` table). Rooms are the cavities being monitored. `daily_visits` is the driving table for the phone: one row per calendar day, one shift each. `UNIQUE(job_id, visit_date)`.
- **Recurring daily until dry.** There is no weekday mask. `jobs.status = 'drying'` plus `visits_due_this_week` (recursive `days` CTE, today through today+6, local date) emits every calendar day that does not yet have a `daily_visits` row and whose `monitor_start` has been reached. Marking the job `dry` or `cancelled` stops the expansion. The agent inserts the row, then `shift_create`s it. Idempotent: unique visit-date plus `shift-job-{job_id}-{YYYYMMDD}`.
- **60-day event roll per job address.** ZenSched caps an event at 60 days, so a class-4 concrete dry-out cannot live on one event. Each job holds one permanent `zensched_location_id` and the *current* `zensched_event_id` / `event_valid_until`. The agent creates a new event (`event_create(location_id, title="Dry-out {job_no} - {street}", start_date, end_date=start+59 days, idempotency_key="event-job-{job_id}-{YYYYMMDD}")`) whenever a shift date is later than `event_valid_until`, calls `form_assign` on it, and updates the row. `visits_due_this_week` / `visits_upcoming` / `jobs_drying` expose `event_needs_roll`; `events_expiring` lists drying jobs due for renewal within 14 days. **Never an event per visit.** The event idempotency key uses the *window start*, not the visit date — a naive per-day event key would blow the 60-day model.
- **Water class is IICRC S500 class 1–4** (how much water / how hard to dry), stored as `class_1` … `class_4`. Optional `water_category` (`cat_1` | `cat_2` | `cat_3`) is contamination and is local-only in the sense that it never goes to ZenSched titles; it can appear on the pack if the owner wants it. The kit does not encode drying-time estimates from class.
- **Room keys are the form's option keys.** The Moisture Log is created once per account, so it cannot list *this job's* rooms. `rooms.room_key` is `CHECK`'d to that vocabulary; `room_label` is what you say (`Master bedroom` on `bedroom_1`). `UNIQUE(job_id, room_key)` — a fourth bedroom is `other`. Target % NULL → `settings.default_target_moisture_pct` (16).
- **`moisture_readings` is an aggregated JSON array**, one object per form submission (one submission per room per visit): `room`, `moisture_pct`, `meter_type`, `photo_urls`, `notes`, `submission_id`. The agent writes it on the one metered read and updates `rooms.last_*`. Later packs and "what's wet" are local.
- **`job_no`** is assigned by trigger as `J-{YYYY of monitor_start, else loss_date, else today}-{job_id:04d}` when left NULL. `invoices.invoice_number` is `{prefix}-{YYYY}-{invoice_id:04d}` the same way.
- **`scheduled_start` is local wall-clock time without an offset.** The visit insert can be just `(job_id, visit_date)`; `fill_visit_defaults` builds `scheduled_start` from the job's `visit_time` (else 09:00). Views append `settings.timezone_offset`. Day-based views use `date('now', 'localtime')` because the SQLite MCP server runs on the owner's computer. `CHECK` rejects a trailing offset or `Z`.
- **`billable_total` is computed in a view, not stored.** Snapshot rates live on the job (`daily_rate`, `trip_fee` filled by trigger from the client). `billable_visits`: `completed` → daily + other; `no_access` → trip + other; everything else → 0. A late-cancel you want billed is `other_fee` on the visit *and* status `no_access`.
- **No signature field on the form.** ZenSched replaces the Submit button with the signature pad when a form has a `signature` field. Meter photos are `photo` (`max_images: 2`). A submission with photos bills $0.15 instead of $0.05, once ever, *per room*.
- **GPS stamps and readings are copied once.** `checked_in_at`, `checked_out_at`, `gps_verified`, `checkin_distance_m`, and `moisture_readings` are filled at close-out so "was I on site" and the export pack are answered locally. ZenSched remains the original.
- **Solo mode is the default.** The owner is invited as a ZenSched worker (`worker_invite` with their own email, $0.25) and stored on `technicians` with `is_owner = 1`; `settings.default_technician_id` points at that row. The kit does not compute sub payouts (restoration crews are usually W-2 / hourly; use free `timesheet_export(mode="hours")` if you want an hours record).
- `daily_visits.zensched_shift_id` and `technicians.zensched_worker_id` are `UNIQUE`. `PRAGMA foreign_keys = ON` is in `schema.sql` and `SKILL.md` tells the agent to run it per session. Deleting a client cascades to jobs, rooms, visits, and invoices; deleting a technician sets `jobs.technician_id` / `daily_visits.technician_id` NULL.

**Moisture Log form.** Created once with `form_create(title, fields_json, idempotency_key="form-moisture-log")`; the exact `fields_json` is in `SKILL.md` and `example-workflow.md` (byte-identical) and was validated against ZenSched's `_validate_fields`. Every field carries an explicit `identifier` so submission `data` keys are stable (`room`, `moisture_pct`, `meter_type`, `meter`, `notes`; section `sec_moisture`). Option keys are derived by ZenSched from the labels (lowercase, non-alphanumerics → `_`, truncated at 30 characters): rooms `living_room` / `dining_room` / `kitchen` / `bedroom_1` / `bedroom_2` / `bedroom_3` / `bathroom_1` / `bathroom_2` / `hallway` / `basement` / `garage` / `laundry` / `closet` / `other`; meter `pin` / `pinless` / `thermo_hygrometer` / `other`. No key truncates. Attaching is `form_assign(form_id, event_id=...)` per event (including after each roll).

**Idempotency keys.** Deterministic, derived from local IDs so a retried or re-run agent turn cannot duplicate:

- location: `loc-job-{job_id}`
- event: `event-job-{job_id}-{YYYYMMDD}` (window start)
- shift: `shift-job-{job_id}-{YYYYMMDD}` (visit date; a tech swap appends `-2`)
- assignment: `assign-moisture-{event_id}`
- cancel: `cancel-shift-{shift_id}`
- worker: `worker-{email}`
- form: `form-moisture-log`

ZenSched caches idempotent responses for 24 hours. The views emit `loc_idempotency_key` and `shift_idempotency_key` per row. They do **not** emit a per-day event key — that would invite an event per visit.

**Timestamps.** `shift_create` / `shift_update` take `start` and `end` in ISO 8601 with an explicit offset. Always use the business's local offset from `settings.timezone_offset` (e.g. `2026-09-08T09:00:00-06:00`), never `Z`. The views build these strings so the agent does not have to.

**Metered reads.** `form_submissions(form_id, event_id=...)` is the natural per-job read while the event is current; after a roll, pass the visit's own `zensched_event_id`. `form_export` covers a week or month in one call. Both bill $0.05 per submission ($0.15 with photos), once per submission ever. `shift_list`, `shift_status`, and `timesheet_export(mode="hours"|"raw")` are free.

**Check-in policy.** The radius is enforced by `policy_update(0, '{"checkin_radius_m": N}')`, not by `location_create(checkin_radius_m=...)`, which is informational; with geofencing on, values under 100 m are raised to about 91 m. The kit's example sets 150 m / 20 min slack / 15 min check-out reminder.

**SQLite MCP server.** `mcp.json.example` uses [`easy-sqlite-mcp`](https://github.com/chenkumi/easy-sqlite-mcp) (Node, `better-sqlite3`, `SQLITE_PATH` env var). Its `sqlite_execute` calls `prepare()`, so it accepts **one statement per call**; `schema.sql` is written so every statement stands alone and is idempotent.

**Schema test.** The schema was verified by splitting the file into its 51 statements (line comments stripped; `CREATE TRIGGER … END;` kept whole so inner `;` are not separate calls) and executing each individually (as the MCP server does) twice for idempotency (seed rows not duplicated), then exercising: all 7 tables, 10 views, and 10 triggers present; every view on an empty database; `technicians.zensched_worker_id` and `daily_visits.zensched_shift_id` `UNIQUE`; `UNIQUE(job_id, visit_date)` and `UNIQUE(job_id, room_key)`; the `number_job` trigger (`J-YYYY-0001`, explicit number kept); `fill_job_defaults` (daily_rate from client, trip_fee from client else daily_rate, visit_time / duration / monitor_start / zensched_label filled, explicit values kept); `fill_room_defaults` (target from settings, label from key); `fill_visit_defaults` (`scheduled_start` from visit_date + job time, duration from job then settings, technician from job then default, explicit duration kept); `visits_due_this_week` (`start_iso` / `end_iso` with offset, `event_needs_roll` when `event_valid_until` is null or before the day, drying-only, `monitor_start` in the future excluded, existing visit-date excluded, 7-day window, unassigned when no tech, `zensched_event_title` = `Dry-out {job_no} - {street}` with no insured name or claim number); `visits_upcoming` (`needs_shift`, ISO times, cancelled excluded); `jobs_drying` (`needs_today`, `wet_room_count`); `rooms_still_wet` (null last reading and above-target included, at-or-under excluded); `events_expiring`; `billable_visits` for completed (daily), no_access (trip), cancelled (0); `reports_ready` (`needs_pull` when readings NULL); `moisture_log` (completed + readings only); `receivables_by_client` totals and the drop-off after invoicing; invoice numbering, total, due date = +30 days from the client's terms, `line_items` JSON with no claim PII; `invoices_outstanding` aging buckets `90+` / `60` / `30` / `current` with paid excluded; `updated_at` on jobs; every `CHECK` (client type, water class, water category, job status, visit status, room key, `visit_time`, `visit_date`, `scheduled_start` format with offset and `Z` rejected, duration range); foreign keys rejecting an unknown client, `SET NULL` on technician delete, and the full cascade on client delete; integer affinity on every `zensched_*_id`. The Moisture Log `fields_json` was validated against ZenSched's `_validate_fields` (6 fields, no signature, identifiers stable, option keys untruncated). 153 checks, all passing.

## Support

- ZenSched docs: <https://www.zensched.com/docs/>
- Tool reference: <https://www.zensched.com/docs/tools/>
- Feedback: ask your AI to call `feedback_submit` (categories: `bug`, `friction`, `missing_capability`, `docs`, `billing`, `feature`, `other`)

## License

MIT. See `LICENSE`.
