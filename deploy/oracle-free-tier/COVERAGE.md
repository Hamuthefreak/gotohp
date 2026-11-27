# Read-only coverage ledger

What the live MCP server actually serves, and what has actually been proven to
work against the real Omnivox account. One row per tool, nothing omitted and
nothing invented.

## Where these facts come from

| Pin | Value |
| --- | --- |
| Live servers | `https://github.com/Beat-YT/omnivox-mcp` at `6164a1aa191424fa2d0c27836a44c0f5b89f8858` (`main`, depth 1), patched on the box by this repo's `patch-*.py` |
| This repo at the moment of proof | `a93232c` (`feat(omnivox): read a document's text instead of stopping at a saved path`) |
| Deploy run | `45940490195`, workflow `deploy-gate.yml`, conclusion `success`, job *Install the gate on the relay VM* |
| Live tool list | that run's own output, line `/tools answers 43 tools`, printed after the install step |
| Per-tool evidence | the same job's probe output, `75 answered, 16 rejected bad input, 43 of 43 tools exercised` |
| Server with the extra tools | `d233cba` (college document link, MIO message link, campus events), `f1e5a4f` (upcoming schedule), `a93232c` (read document) |

The tool names below are transcribed from the `/tools` answer above, not from
memory. `check-coverage.py` re-reads this file against any `/tools` answer and
fails unless the two lists are the same set, the same count, and every row names
the same tools that Omnivox really receives. A new upstream tool, a dropped one,
or a row that points at a tool that does not exist all fail there instead of
slipping through.

## Categories and verdicts

`live` means the tool answered with real data from the account. `unverified`
means it was exercised without touching Omnivox, or not exercised at all; the
reason says which. Tools are read-only unless the row says otherwise.

### College documents

| Tool | Introduced | Exercised by | Observed | Verdict |
| --- | --- | --- | --- | --- |
| `get-college-documents` | `6164a1a` | probe `get-college-documents` | `200 # College documents (12) 12 document(s)` | live |
| `get-college-document-link` | `d233cba` (this repo) | probe `get-college-document-link` | `200` returns the text of one document and says nothing was opened; no file to save upstream | live |
| `get-college-document-link` | `d233cba` (this repo) | probe `get-college-document-link (bogus)` | `500 No college document with id 00000000-…` | unverified: bogus id only, the file path itself is never taken because upstream sends no file |
| `get-college-news` | `6164a1a` | probe `get-college-news` | `200 # College news (20)` | live |
| `get-college-list` | `6164a1a` | probe `get-college-list` | `200 {"count":1,"colleges":[{"code":"VAN","name":"Vanier College"}]}` | live |
| `get-online-forms` | `6164a1a` | probe `get-online-forms` | `200 # Online forms (4) 4 open, 0 closed` | live |

### MIO messages and attachments

| Tool | Introduced | Exercised by | Observed | Verdict |
| --- | --- | --- | --- | --- |
| `get-mio-messages` | `6164a1a` | probe `get-mio-messages` | `200 # MIO messages 38 unread / 114 total, showing 21` | live |
| `get-mio-folders` | `6164a1a` | probe `get-mio-folders` | `200 # MIO folders (38 unread)` | live |
| `read-mio-message` | `6164a1a` | probe `read-mio-message` | `200 # food drive … ## Attachments - Vanier_Food_Drive.pdf … has an attachment: e8fc928a-…` | live |
| `search-mio-messages` | `6164a1a` | probe `search-mio-messages` | `200 # MIO search: "vanier" 21 result(s)` | live |
| `get-mio-attachment-link` | `6164a1a` | probe `get-mio-attachment-link` | `200 File saved to: …/downloads/Vanier_Food_Drive.pdf` | live |
| `get-mio-message-link` | `d233cba` (this repo) | probe `get-mio-message-link` | `200 File saved to: …/downloads/Vanier_Food_Drive.pdf (32263 bytes)` | live |
| `get-mio-message-link` | `d233cba` (this repo) | probe `get-mio-message-link (bogus attachment)` | `500 Message … has no attachment 00000000-…` | unverified: bogus id only, the refusal is what this row proves |
| `create-mio-folder` | `6164a1a` | probe `create-mio-folder` | `500 A folder needs a name: pass the name to create.` | unverified: refusals only, before any call, and this write tool is never invoked in a run that could create anything |
| `send-mio-message` | `6164a1a` | probe `send-mio-message` | `400 Invalid input` | unverified: refused by validation before Omnivox; a write tool, never sent |
| `reply-mio-message` | `6164a1a` | probe `reply-mio-message` | `400 Invalid input` | unverified: refused by validation before Omnivox; a write tool, never sent |
| `move-mio-message` | `6164a1a` | probe `move-mio-message` | `200 Error: Cannot move message to a search folder.` | unverified: refuses a search-folder target before Omnivox; a write tool, never moved |
| `delete-mio-message` | `6164a1a` | probe `delete-mio-message` | `500 … the trash still holds … nothing moved` on the all-zeros id | unverified: the id does not exist, so nothing can have been deleted; only the honest refusal is proven. A write tool: no run has deleted anything |
| `restore-mio-message` | `6164a1a` | probe `restore-mio-message` | `500 … the trash still holds … nothing moved` on the all-zeros id | unverified: same as delete, no message was restored |
| `flag-mio-message` | `6164a1a` | probe `flag-mio-message` | `400 Invalid input` | unverified: refused by validation before Omnivox; a write tool, never flagged |

### Assignments: list, detail and instructions

| Tool | Introduced | Exercised by | Observed | Verdict |
| --- | --- | --- | --- | --- |
| `get-course-assignments` | `6164a1a` | probe `get-course-assignments` for 6 courses | `200` 2, 0, 0, 13, 0 and 3 assignment(s), with due dates | live |
| `get-assignments-summary` | `6164a1a` | probe `get-assignments-summary (20263)` | `200 # Assignments — term 20263 (6 courses)` | live |
| `get-assignment-detail` | `6164a1a` | probe `get-assignment-detail` on 3 ids | `200` title, status, published/due dates, deposit state; instructions come back with it | live |
| `get-assignment-file-link` | `6164a1a` | probe `get-assignment-file-link (bogus)` | `400 file_id must be a valid UUID` | unverified: no real assignment file id came back in the account's data, so only the rejection was exercised |
| `get-assignment-submit-link` | `6164a1a` | probe `get-assignment-submit-link` | `500 says it needs MCP_SERVER_URL` | unverified: a URL builder that needs the public base URL, no Omnivox round trip is proven |
| `get-course-announcements` | `6164a1a` | probe `get-course-announcements` for 6 courses | `200` 0, 22, 3, 0, 5 and 0 announcement(s) | live |

### Reading a document's contents

The `get-*-link` tools answer with a saved path or a 15 minute URL. `read-document`
is the other half: the same file, fetched and read, so the text comes back.

| Tool | Introduced | Exercised by | Observed | Verdict |
| --- | --- | --- | --- | --- |
| `read-document` | `a93232c` (this repo) | probe `read-document` on a real course document, and `read-document (bogus)` | `200 # F26_McIntyre_102-SWB_19.docx application/vnd…wordprocessingml.document, 88 KB, docx` and 24746 characters of its text, not a path; a wrong id answers `500 Omnivox answered with an error page` | live |

### Schedule, canceled classes, campus events

| Tool | Introduced | Exercised by | Observed | Verdict |
| --- | --- | --- | --- | --- |
| `get-upcoming-schedule` | `f1e5a4f` (this repo) | probe `get-upcoming-schedule` and `(14 days)` | `200 # Next 7 days: 16 entries` and `# Next 14 days: 23 entries`, with times and rooms | live |
| `get-schedule` | `6164a1a` | probe `get-schedule (20263)` | `200 # Weekly schedule: term 20263 (12 slots)` | live |
| `get-cancelled-classes` | `6164a1a` | probe `get-cancelled-classes` | `200 # Cancelled classes No cancelled classes.` | live (empty: answered "none", no populated list seen) |
| `get-campus-events` | `d233cba` (this repo) | probe `get-campus-events` | `200 # Campus events The college lists no events right now.` | live (empty: answered "none", no populated list seen) |
| `get-calendar` | `6164a1a` | probe `get-calendar` and `(all)` | `200 Current Time: 2026-11-26 …` | live |

### Other existing read tools

| Tool | Introduced | Exercised by | Observed | Verdict |
| --- | --- | --- | --- | --- |
| `get-overview` | `6164a1a` | probe `get-overview (20263)` and `(no term_id)` | `200 ## Today's calendar: • 12:00–14:00 — Renforcement …` | live |
| `get-courses-summary` | `6164a1a` | probe `get-courses-summary` | `200 # Courses — term 20263 (6)` | live |
| `get-course-info` | `6164a1a` | probe `get-course-info` for 6 courses | `200` course id, code, group, title | live |
| `get-course-documents` | `6164a1a` | probe `get-course-documents` for 6 courses | `200` 3, 62, 40, 34, 31 and 25 document(s) | live |
| `get-document-link` | `6164a1a` | probe `get-document-link` on a real id | `200 File saved to: …/downloads/F26_McIntyre_102-SWB_19.docx` | live |
| `get-document-link` | `6164a1a` | probe `get-document-link (bogus)` | `500 Omnivox answered with an error page instead of a file` | unverified: bogus id only |
| `get-course-evals` | `6164a1a` | probe `get-course-evals` for 6 courses | `200 Marks are points; percentages in parentheses …` | live |
| `get-course-people` | `6164a1a` | probe `get-course-people` for 6 courses | `200 {"count":26,…}` … `{"count":41,…}` | live |
| `get-absences` | `6164a1a` | probe `get-absences (20263)` and `(no term_id)` | `200 # Absences — term 20263 (11h total)` | live |
| `get-grades-summary` | `6164a1a` | probe `get-grades-summary (20263)` and `(no term_id)` | `200 # Grades — term 20263 (6 courses)` | live |
| `get-teachers` | `6164a1a` | probe `get-teachers (20263)` and `(no term_id)` | `200 {"term_id":"20263","teachers":[…]}` | live |
| `get-terms` | `6164a1a` | probe `get-terms` | `200 {"default_term":"20263",…}` | live |
| `search-people` | `6164a1a` | probe `search-people` | `200 {"count":15,…}` | live |
| `get-service-link` | `6164a1a` | probe `get-service-link` | `200 Service links are disabled on this server.` | unverified: read-only upstream, but this server keeps external links off (`ENABLE_EXTERNAL_SERVICE_LINKS` unset), so it cannot reach Omnivox at all |

## Rollup

| Category | Tools | live | unverified |
| --- | --- | --- | --- |
| College documents | 5 | 4 | 1 |
| MIO messages and attachments | 13 | 5 | 8 |
| Assignments: list, detail and instructions | 6 | 4 | 2 |
| Reading a document's contents | 1 | 1 | 0 |
| Schedule, canceled classes, campus events | 5 | 5 | 0 |
| Other existing read tools | 13 | 11 | 2 |
| **Served tool set** | **43** | | |

The ledger holds 46 rows over the 43 served tools: three tools have a second row
for the bogus-id path. 30 served tools are live-confirmed (28 answering data, 2
answering an honest "none"), 13 are unverified, and every unverified one is a
write tool refused before Omnivox, a bogus-id-only exercise, or a read the
server keeps switched off.

## Why the empty answers still count

`get-cancelled-classes`, `get-campus-events` and `get-online-forms` answered for
real; the account simply had nothing in them on 2026-11-26. They are marked
live because the call reached Omnivox and the server said "none", which is what
it would say when there is none. A populated list for these three has not been
seen.

## What is not proven at all

- `get-assignment-file-link` and `get-assignment-submit-link` never received a
  real assignment file or a working public base URL.
- Every MIO write tool (`send`, `reply`, `move`, `delete`, `restore`, `flag`,
  `create-folder`) is listed because the server serves it; none was allowed to
  reach Omnivox, by design. The probe only proves they refuse honestly.
- `get-service-link` is off on this server; on a server with
  `ENABLE_EXTERNAL_SERVICE_LINKS=true` it would log into the full account, which
  has never been tried and should not be.
