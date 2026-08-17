# Net Report

A native SwiftUI macOS app (Apple Silicon, macOS 14+) for running a local
amateur-radio net. It is a redevelopment of the original Python `ham_lookup.py`
CLI, with the interactive prompt loop replaced by a real macOS interface.

## Features (ported from the Python tool)

- **QRZ XML lookups** — signs in to the QRZ XML data service with **your own
  account** and resolves call signs to name / street / city / county / state,
  with transparent re-login on session timeout. Credentials can be saved to the
  macOS **Keychain** so you only enter them once.
- **Receiving-station nickname** — the operator receiving the NTS form can be
  shown by a familiar name: W1AW "Theodore Marks" with nickname `Ted` prints as
  **"Ted Marks"** on the radiogram.
- **Net check-in log** — the operator is seeded as the first check-in. **Add
  Check-in…** opens a dedicated window for the call sign, nickname, and notes,
  auto-filling name, city, county, and state. It stays open across entries when
  you use **Save and Add New**, so a whole net can be logged without returning to
  the main window. **Right-click any row** in the check-in list to **Edit** (fix a
  mistyped call sign) or **Delete** it; double-click also opens the editor.
- **Persistent and temporary notes** — each check-in carries two note fields:
  **Persistent Notes** are saved to the operator directory and pre-fill at every
  future net, while **Temporary Notes** apply to tonight only and are never
  written to the database. Both appear in the **Activity log** (what net control
  reads from during the net, labelled `Notes:` and `Tonight:`), in the check-in
  table as separate *Notes* and *Tonight* columns, and combined into the **Notes
  column of the check-in list PDF**.
- **NTS Receiving Station checkbox** — tick it on any check-in and that operator
  becomes the station receiving the NTS form; their call sign and nickname fill
  the report automatically.
- **Announcements** — tick **Announcement** in the add/edit window to flag a
  station with an announcement or QST. Flagged rows get a 📣 marker in the
  check-in table and a `★ ANNOUNCEMENT` marker in the activity log, and
  **File ▸ Announcements** (⇧⌘A) opens a window collecting every flagged station
  with their notes, ready to read off. Each announcement has a **Read** checkbox:
  tick it once you've read it on the air and the entry dims and strikes through,
  the header shows "*n* of *m* read", and the button badge counts down to zero.
- **Force a QRZ refresh** — when a locally-cached record is missing details, the
  ↻ button beside the call sign forces a fresh QRZ lookup and fills the gaps.
  Your **nickname and persistent notes are never overwritten**.
- **Database manager** — **Edit ▸ Edit Databases…** (⇧⌘D) opens a window to browse
  and edit the operator directory, review the report log, and back up or erase
  either database. The Edit menu also has **Report Database** and **Operator
  Directory** submenus with *Edit / Back Up / Erase* for each.
- **Local operator directory** — every station you look up is remembered in its
  own `users.sqlite` database. Later check-ins are filled in from that local
  directory, and **QRZ is only queried for stations not already known**. Nicknames
  and notes you add are kept there and reused automatically. This database is
  deliberately **separate** from the report log, so erasing report history never
  loses your operators, and each can be backed up on its own.
- **Two PDFs per net** — generates a *check-in list* PDF (the roster table) and a
  separate *net report* PDF (the hand-drawn ARRL radiogram form, "Oregon D1 Net
  Report …"), rendered with CoreGraphics/CoreText (the Swift equivalent of the
  original ReportLab output).
- **SQLite report database** — every net report is logged to a `netreport.sqlite`
  database with an auto-incrementing message number. The database and the report
  PDFs live together in one **data folder**; point that folder at a synced or
  network location (iCloud, OneDrive, an SMB share) and several computers can
  share the same database. A single self-contained file — no server to run.
- **Guided first-run setup** — the first launch on a machine walks through a
  four-step wizard: QRZ sign-in (skippable), where the data lives, how each
  database gets its starting contents, and a summary. See
  [First-run setup](#first-run-setup) below.
- **Back up & erase** — back up the database to a file at any time, or erase it to
  start fresh (with a warning and an offer to back up first). Available in the
  in-app **Database** panel and under the **File** menu.

Output is written under the data folder (default **`~/Documents/Net Report/`**):

```
~/Documents/Net Report/
├─ Checkin List/   checkin_list_YYYYMMDD_HHMMSS.pdf
├─ Net Reports/    net_report_YYYYMMDD_HHMMSS.pdf
├─ netreport.sqlite   report log (message numbers, per-net totals)
└─ users.sqlite       local operator directory (separate database)
```

Each report carries a date **and time** stamp, so generating a new report never
overwrites an earlier one.

## First-run setup

The first time Net Report runs on a machine it opens a setup wizard:

1. **QRZ.com Account** — sign in with your own QRZ login, with an optional
   *Save to my Keychain*. **Skip — don't use QRZ** moves on without it; you can
   still run a net and type station details by hand, and sign in later from
   **File ▸ QRZ Account…**
2. **Data Location** — choose the folder holding the databases and report PDFs.
   Point it at a synced or network folder to share with another computer. The
   step reports what it found there (*"3 net reports · 42 operators — these will
   be used as-is"*), so a **new computer picks up existing databases** rather
   than starting over.
3. **Starting Data** — shown only when the folder has no data yet. Each database
   is set up independently:
   - *Operator Directory*: **Import CSV…** or **Start Empty** (it fills itself in
     as you look call signs up). The CSV needs a header row with a call sign
     column; `name`/`first_name`/`last_name`, `nickname`, `street`, `city`,
     `county`, `state`, and `notes` are optional and matched by name, so column
     order doesn't matter.
   - *Net Report Log*: **Import CSV…** (original `message_index.csv` format),
     **Start at number** *n*, or **Start Fresh (1)**.
4. **All Set** — a summary of the choices, then straight to the main window.

Re-run it any time with **File ▸ Run Setup Again…**. The "setup completed" flag
is stored per-machine, not in the database, which is what makes step 2 appear on
a new computer even when the shared folder is already populated.

### Sharing the database across computers

Choose **File ▸ Choose Data Folder…** and pick a folder that syncs or is
network-mounted. The app keeps the database as a single rollback-journaled file
(not WAL) specifically so it stays a clean single file safe to sync. This suits a
weekly net with one operator writing at a time; it is not designed for two
computers writing simultaneously.

## Project layout

```
Net Report/
├─ Package.swift
├─ Sources/
│  ├─ NetReportKit/         Platform-agnostic core (testable, no UI)
│  │  ├─ HamRecord.swift        Station + check-in models
│  │  ├─ QRZClient.swift        QRZ XML API client (actor)
│  │  ├─ QRZResponseParser.swift  XMLParser-based response reader
│  │  ├─ SQLiteStore.swift      Shared SQLite plumbing (open, backup, helpers)
│  │  ├─ NetDatabase.swift      Report log: numbering, CSV import, erase
│  │  ├─ UserDatabase.swift     Local operator directory (separate database)
│  │  ├─ NTSForm.swift          NTS field computation + report orchestration
│  │  └─ RadiogramPDF.swift     CoreGraphics radiogram + table renderer
│  └─ NetReport/            SwiftUI application
│     ├─ NetReportApp.swift     @main entry point, windows + menu commands
│     ├─ FontSettings.swift     Per-box UI font sizes (persisted)
│     ├─ KeychainStore.swift    QRZ credentials in the macOS Keychain
│     ├─ NetSession.swift       @Observable workflow model
│     ├─ ContentView.swift      Operator bar, check-in table, report panel, log
│     ├─ SetupWizardView.swift  First-run setup (QRZ, location, import)
│     ├─ AnnouncementsView.swift  Announcements / QST window
│     └─ DatabaseManagerView.swift  Browse, edit, back up, erase both databases
├─ Tests/NetReportKitTests/ swift-testing unit tests for the core
└─ scripts/build-app.sh     Bundle + ad-hoc sign NetReport.app
```

## Build & run

Requires the Swift 6 toolchain (Xcode or Command Line Tools).

```bash
# Run from source
swift run NetReport

# Run the unit tests (swift-testing)
swift test

# Build a self-contained, ad-hoc-signed app bundle and install it
bash scripts/build-app.sh
open ~/Applications/NetReport.app
```

The build script stages the bundle in `dist/` and then installs (replacing) it
into **`~/Applications`** on every run. `~/Applications` is used because this
account can't write to the system `/Applications` without an admin password; to
target the system folder instead, run with `INSTALL_DIR=/Applications` (needs
write access there).

> **Note:** `swift test` uses the Xcode toolchain. If a freshly installed Xcode
> blocks the toolchain with a license prompt, run `sudo xcodebuild -license accept`
> once. To build (not test) against Command Line Tools instead, prefix commands
> with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

## QRZ credentials

There is **no built-in account** — each operator signs in with their own QRZ.com
login. On first launch a sign-in sheet asks for your user name and password, with
an optional **"Save to my Keychain"**. Saved logins live in the macOS Keychain
only; they are never written to a file, to `UserDefaults`, or into the report
database. The login is verified against QRZ before it is stored.

Manage the account from **File ▸ QRZ Account…** (change accounts) or
**File ▸ Sign Out of QRZ** (forget the saved login), or click the QRZ status
button in the Net Control bar.

For headless or scripted runs you can supply credentials via the environment
instead, which bypasses both the Keychain and the prompt. Read the password out
of the Keychain rather than typing it — a literal password on the command line
is saved to your shell history in clear text:

```bash
QRZ_USERNAME=YOURCALL QRZ_PASSWORD="$(security find-generic-password -s com.w7skw.netreport.qrz -w)" swift run NetReport
```

A QRZ XML subscription is required for full address data.

> **Ad-hoc signing and the Keychain.** Every rebuild changes the app's code
> signature, so macOS treats each build as a new program and re-asks for
> Keychain access. Choosing "Always Allow" grants that access permanently to
> *that build only*, so you will be asked again after the next rebuild. Signing
> with a stable Developer ID certificate removes the prompts properly; prefer
> that over clicking through repeatedly.

## Usage

On a brand-new install you'll see the [setup wizard](#first-run-setup) first.
After that:

1. Enter your call sign and **Start Net** — you are looked up and added as the
   first check-in.
2. Click **Add Check-in…** (⌘K) to open the entry window. Type the call sign and
   press Return (or click **Look Up**) — the local directory answers instantly,
   otherwise QRZ is queried once and the result is cached. Add a nickname,
   persistent notes (remembered) and temporary notes (tonight only), tick
   **NTS Receiving Station** if this operator will receive the form, then:
   - **Save and Add New** — records it and clears the form for the next station,
     keeping the window open (cursor returns to the call sign field).
   - **Save** — records it and closes the window.
   - **Break** — saves whatever is entered, logs a net break, and closes.

   Right-click a row in the check-in list to **Edit** or **Delete** it (deleting
   asks "Delete &lt;call sign&gt;?" first).
3. Enter the **receiving station**, an optional **nickname** for that operator,
   and the **traffic message** count, then
   **Generate Report**. Both PDFs are written and the report is logged to the
   database; use **Open Check-in List** / **Open Net Report** / **Reveal Folder**.

## Security & privacy notes

- **Your QRZ password** lives only in the macOS Keychain, marked
  `WhenUnlockedThisDeviceOnly` and non-synchronizable, so it stays on this Mac
  and is excluded from backups and iCloud. It is never written to a file, to
  `UserDefaults`, or to the databases, and never appears in a URL or log line.
  The app contains no built-in account.
- **All SQL is parameterised.** Every statement is a literal with `?`
  placeholders; values from CSVs and QRZ are bound, never interpolated.
- **XML from QRZ is parsed with external entities disabled**, so a spoofed or
  compromised endpoint can't use an XXE payload to read local files. The
  credentialed login POST also refuses HTTP redirects, so it can't be bounced
  to another host with the password still attached.
- **Imported files are treated as untrusted.** CSV message numbers are
  range-checked, and the stored PDF path is only ever *revealed in Finder*,
  never opened or executed. An imported **backup database** is vetted before a
  single page is copied — size, SQLite's own integrity check, absence of
  triggers or views (a restore would otherwise adopt the source's schema), and
  the expected table and columns — so a crafted or mismatched file is rejected
  with your existing data intact. Values that arrive this way are re-clamped on
  read rather than trusted.
- **Your data never enters this repository.** `.gitignore` excludes the
  databases, PDFs, and any `*.csv` — those hold real names, addresses, and call
  signs of net participants. Example data in the source and tests uses the
  fictitious operator "Theodore Marks" at W1AW (ARRL's club station).

## Differences from the Python version

- GUI workflow instead of a terminal prompt loop (same feature set).
- PDF rendering uses CoreGraphics/CoreText rather than ReportLab — no third-party
  dependency, identical layout.
- Report history is a SQLite database (`netreport.sqlite`) rather than
  `message_index.csv`; the old CSV can be imported on first run.
- Output defaults to `~/Documents/Net Report/` (relocatable) rather than the
  current working directory.
