# Quickstart

Setup is about 15 minutes, once. After that everything is plain English to your AI. Each step below tells you what to do and, where relevant, exactly what to type to the AI.

You need: Claude Desktop (or Cursor) and [Node.js LTS](https://nodejs.org/) installed. Nothing else.

Before you start, read the "This is not an IICRC certificate" and "PHI / PII boundary" sections of `README.md`. Short version: this kit is GPS + daily moisture % + billing, not Xactimate and not a psychrometric package; insured name, claim number, and policy number stay on your computer; ZenSched only ever sees `Dry-out J-2026-0001 - Willow Ln`, an address, and a Moisture Log. No BAA. No signature pad.

## 1. Make a data folder

Create a folder such as `C:\Users\YourName\dryout-ops` (Windows) or `/Users/yourname/dryout-ops` (Mac). Note the full path. It will hold insured names, claim numbers, and policy numbers, so keep it on an encrypted, backed-up disk.

## 2. Add the two tools to your AI's config

Open the config file:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** Settings → MCP → Add new global MCP server

Paste this in and fix only the `SQLITE_PATH` line to match your folder from step 1:

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

- On Windows, double every backslash: `"C:\\Users\\YourName\\dryout-ops\\dryout-ops.db"`.
- Leave `zsc_your_key_here` as it is. You get the real key in the next step.

Save, then **fully quit and reopen** the AI app.

## 3. Create your ZenSched account

Type to the AI:

> Call account_create with org_name "My Dry-Out Co". Show me the zsc_ key.

Copy the key into the config file in place of `zsc_your_key_here`. Save. Quit and reopen the app once more.

## 4. Create the database tables

Copy the full contents of `schema.sql` and paste it into the chat with this line above it:

> Create these tables in my dryout-ops database. Run each statement one at a time with the SQLite tool, then list the tables to confirm.

## 5. Give the AI its instructions

Paste `SKILL.md` into the AI as standing instructions (Claude Desktop: a Project's instructions; Cursor: a rule). Then:

> We're High Plains Restoration in Denver, Mountain time. It's just me, Jordan Hale, jordan@example.com, 303-555-0144. Set me up.

The AI saves your settings, invites **you** to ZenSched as a worker ($0.25, once; you are the tech on the phone), and calls `form_create` once (free) to build the Moisture Log you fill in at each room: room, moisture %, meter type, meter photo (max 2), and notes. No signature pad, no insured name, no claim number. It stores the form id so every visit gets it. Install the app from the invitation email ([Android](https://play.google.com/store/apps/details?id=com.zensched.app) / [iOS TestFlight](https://testflight.apple.com/join/Wp51m5Yq)).

Optional but recommended: "Allow check-in 20 minutes early and set the radius to 150 m." Techs wait for occupants and often park on the street. The radius is a **policy** setting, not per location.

More techs: "Add my tech Reese Okonkwo, reese@example.com" for each person you dispatch.

## 6. Open your first job

Paste the work order you received, then:

> Book it. Daily until dry.

Behind the scenes the AI extracts the client, work-order number, water class, insured, claim number, address, rooms, first day, and daily rate; **stashes claim number / policy / insured in SQLite only**; adds the client if new (asks for their payment terms); creates one ZenSched location at the loss address (`location_create`, geocode $0.03, may trigger the $5 activation deposit the first time); saves the job as `J-2026-0001`; rolls a **≤60-day** event titled `Dry-out J-2026-0001 - Willow Ln`; attaches the Moisture Log with `form_assign`; and creates this week's daily `shift_create`s. You get one line back with the job number, the rooms, and the daily rate.

## 7. The daily visit

Your phone shows today's stop. At the site, **Check in** (GPS-verified). For **each room** on the job, open the **Moisture Log**: pick the room, type the moisture %, pick the meter type, photograph the meter (up to 2), notes if needed, Submit. Then the next room. **Check out**.

## 8. Close out

> Pull today's readings.

The AI pulls your GPS-verified arrival and departure (free), reads each Moisture Log (metered, so it tells you the cost first — about $0.15 per room with a photo, **once ever**), updates the rooms, and tells you what is still wet and what is receivable.

> What's still wet on J-2026-0001?

Answered from the local record, free: each room vs its target.

> Export pack for J-2026-0001.

A plain-text pack with the order ref, GPS facts, and per-day per-room readings + photo URLs. No insured name or policy number. Not a drying certificate.

> Kitchen and living hit target. Basement is dry too. Mark J-2026-0001 dry.

Stops the daily recurrence, cancels leftover phone visits, leaves the completed days ready to invoice.

## 9. Money

> Invoice Summit TPA.

A plain-text invoice under Summit's terms with one line per visit (your job number, date, class, their order ref, rooms logged). Nothing about insureds on it.

> Who owes me money?

Open invoices aged current / 30 / 60 / 90+ days past due.

> Summit paid INV-2026-0001.

Marks it paid.

## What next

- `README.md` for the full explanation, the IICRC / BAA / PII boundaries, troubleshooting table, and developer notes
- `example-workflow.md` to see the exact tool calls behind each step above
