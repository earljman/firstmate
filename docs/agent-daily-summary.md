# Daily agent summary

The daily agent summary is one small JSON file per local day that a firstmate home writes from its own records, so an outside collector can combine the files from several developer boxes into a daily velocity report.
`bin/fm-daily-summary.sh` writes it; this page is the file's contract and the scheduling recipe.
The file is computed from recorded events and samples with no model calls; raw status text is never copied into it.

## Turning it on

The generator runs only when a timer runs it, so there is nothing to enable inside firstmate.
Two things make its measures complete:

1. Turn on the [fleet activity ledger](fleet-ledger.md) by creating `config/fleet-ledger`, so dispatches, PRs, merges, and cleanups of finished tasks are still on record after their logs are retired.
2. Run `bin/fm-daily-summary.sh sample` every five minutes, so supervisor uptime, agent lifetimes, and time without available tickets are observed.

Optional `config/daily-summary` holds `key=value` lines:

| Key                   | Meaning                                                                 | Default              |
| --------------------- | ----------------------------------------------------------------------- | -------------------- |
| `out`                 | Output directory, also settable with `FM_DAILY_SUMMARY_OUT` or `--out`  | `~/agent-summary`    |
| `box`                 | The `box` name in the file                                              | the short hostname   |
| `developer`           | The `developer` name in the file                                        | `null`               |
| `working_hours`       | Informational only, as `HH:MM-HH:MM [days]`, copied into the file       | omitted              |

Keep the output directory outside the firstmate home so a reader of the files never needs access to `state/` or `.env`.

## The files

In the output directory, `daily/<YYYY-MM-DD>.json` is one complete local day, `daily/latest.json` is a copy of the newest complete day, and `daily/today.json` is the current day so far, marked `"partial": true`.
`samples.jsonl` in the same directory is the sampler's own record.
The JSON summary files are written atomically, so a reader never sees a half-written summary.
The sampler appends lines to `samples.jsonl` and `state/no-ticket.jsonl`.

## Schema `datapel-agent-daily.v1`

```json
{
  "schema": "datapel-agent-daily.v1",
  "box": "pel-dev-peter",
  "developer": "Peter Liu",
  "date": "2026-10-13",
  "tz": "Australia/Sydney",
  "window": {"start": "2026-10-13T00:00:00+11:00", "end": "2026-10-14T00:00:00+11:00"},
  "generated_at": "2026-10-13T13:05:00Z",
  "partial": false,
  "capacity": {
    "agent_hours": 41.5,
    "agents_dispatched": 6,
    "dispatched_by_kind": {"ship": 4, "scout": 2},
    "harnesses": {"claude": 5, "codex": 1},
    "working_hours": {"start": "08:30", "end": "17:30", "days": "Mon-Fri"},
    "no_ticket_hours": 1.5,
    "no_ticket_stretches": [
      {"start": "2026-10-13T15:00:00+11:00", "end": "2026-10-13T16:30:00+11:00", "hours": 1.5, "free_slots": 1,
       "reason": "all_blocked", "detail": {"assigned_open": 4, "held": 0, "blocked": 4}}
    ]
  },
  "output": {
    "prs_ready": ["https://github.com/TeohCapital/datapel-wms/pull/2113"],
    "prs_merged": [],
    "tasks_done": 3,
    "tasks_failed": 0
  },
  "lost": {
    "hours_total": 4.5,
    "items": [
      {"cause": "usage_limit", "provider": "codex", "start": "2026-10-13T09:10:00+11:00", "end": "2026-10-13T13:40:00+11:00", "hours": 4.5, "task": "fix-dwr-3706"},
      {"cause": "host_down", "start": "2026-10-13T11:53:00+11:00", "end": "2026-10-13T12:38:00+11:00", "hours": 0.75}
    ]
  },
  "uptime": {"host_up_hours": 23.25, "supervisor_up_hours": 23.0, "boots": 1},
  "blocker": "DWR-3705 waiting on a design decision (carton size per PO line)",
  "data_quality": {"ledger": true, "sampler_gaps_minutes": 45, "notes": []}
}
```

Readers ignore unknown fields.
Any breaking change bumps the schema to `.v2`.
Hours are rounded to two decimals, local times carry their UTC offset, and `generated_at` is UTC.

### Capacity

- `agent_hours` is the sum over every agent of the hours it was alive inside the window: each ship or scout worker, each second mate, and the box's own firstmate.
  A worker's lifetime runs from its ledger dispatch record to its cleanup record.
  Without those, the first and last time-stamped lines of its status log stand in, a task whose record is still present counts as alive to the end of the window, and `data_quality.notes` says the lifetime was approximated.
  A worker counts only during samples that see its live endpoint; sampler gaps add no worker hours.
  The firstmate's own hours are the sampled supervisor uptime; without samples they are not added and a note says so.
- `agents_dispatched` counts agents started inside the window, a relaunch excluded; `dispatched_by_kind` and `harnesses` break that count down.
  The schema deliberately carries no resident or peak agent count.
- `no_ticket_hours` is time without available tickets across the whole Sydney calendar day: the union of the `no_ticket_stretches`, so two free slots idle at the same time count once.
  Time already counted under `lost` is removed from the stretches, so a usage limit or downtime is never counted twice.
- Each stretch carries its start, end, hours, and the free slots, reason, and exclusion counts from one consistent sequence of observations.
  `reason` is `empty_queue` (no open ticket assigned to the developer), `all_blocked`, `not_required`, `awaiting_ruling`, `out_of_scope`, or `mixed`.
- `working_hours` is optional informational context, copied from the configuration when set, and clips nothing because no-ticket time counts all hours.
  A configured value must use `HH:MM-HH:MM [days]`; invalid values make generation fail.

### Output

`prs_ready` and `prs_merged` list the PR URLs the ledger recorded as ready for review and as merged inside the window.
Without the ledger, `prs_ready` falls back to PR URLs in `done` status lines.
`tasks_done` and `tasks_failed` count tasks whose newest `done` or `failed` status line fell inside the window.

### Lost time

`lost.items` lists wall-clock intervals when the box could not make progress, each with its `cause`:

- `usage_limit`, with `provider`, from a `blocked` or `paused` status line whose text speaks of a usage limit, quota, rate limit, or exhaustion.
  The provider is the one the line names, else the task's harness.
- `credential` from a `blocked`, `paused`, or `needs-decision` line about a login, token, or credential.
- `waiting_on_human` from a `needs-decision` line.
- `other` from any other `blocked` line.
- `host_down` from gaps between boots in `journalctl --list-boots`, when that command exists.
- `supervisor_down` from sampled time when the supervision heartbeat was stale, and from sampler gaps while the host was up.

A status interval closes at the `resolved` line carrying its key, else at the task's next `working`, `done`, `failed`, or `resolved` line, or at its cleanup; an interval still open runs to the end of the window.
A `captain-held` transfer keeps a decision open until every task in its held inventory has an answer; a known answer time closes the interval, while an unavailable answer time is noted in `data_quality.notes`.
`lost.hours_total` is the union of the intervals, not their sum, so three workers stuck on the same limit count once.

### Uptime, blocker, and data quality

- `uptime.host_up_hours` and `boots` come from `journalctl --list-boots`; both are `null` with a note when the command is unavailable, as on macOS.
  `supervisor_up_hours` is the sampled time the heartbeat and available supervisor probes were healthy, excluding known host downtime, or `null` without samples.
- `blocker` is the first non-blank line of `data/daily-blocker.txt` when that file exists.
  Otherwise it names the task with the newest still-open `blocked` or `needs-decision` line and when it opened, without quoting the line, because status text can carry paths and other internal detail.
  A supervision handoff escalation recorded in `state/.watch-handoff-escalation` whose escalation time falls in the window, and whose delivery is newer than that task line, takes the line instead, naming the delivery time and wake sequence (docs/watcher-continuity.md "Claude delivery confirmation").
  It is `null` when none exists.
- `data_quality.ledger` says whether the fleet ledger file exists, `sampler_gaps_minutes` is the part of the observed window no sample covered, and `notes` lists every measure that could not be derived from the records and every approximation made.

## Recording hooks

Every five-minute `sample` reads live ship endpoints and `bin/fm-tasks-axi.sh ready`; when a ship slot is free and no ready ship task exists, it records a no-ticket observation from the backlog's held and blocked counts.
The summary sampler sums free slots for each project in the backlog, capacity declarations, or live ship records: each project uses its declared `config/project-capacity` limit or one slot by default, minus its own live ships.
When none of those records names a project, the sampler uses one default home slot.
An unreadable or invalid capacity declaration, or an unavailable backlog, closes any open no-ticket stretch and records a data-quality note.
The sampler derives `empty_queue`, `awaiting_ruling`, `all_blocked`, or `mixed` from the backlog's held and blocked ship tasks.
Consecutive no-ticket observations join while their free slots, reason, and exclusion counts agree; a stretch ends when those values change, when selection finds a ticket, or when a ship dispatches from the home.
An open stretch continues across midnight into the next Sydney day, and `today.json` stops it at generation time.

`bin/fm-daily-summary.sh sample` records workers whose endpoints answer the existing backend agent probe, remote secondmates whose remote endpoint answers the crew-state probe, and the supervision heartbeat plus installed Herdr and no-mistakes daemon status commands.
Run it every five minutes; each sample covers at most fifteen minutes, and the writer keeps ninety days of dated files.
Worker hours require a live sample and exclude known host downtime; sampler gaps add no worker hours.

## Schedule

Run the sampler every five minutes, `generate --today` hourly, and `generate` shortly after local midnight, which writes the finished day, `latest.json`, `today.json`, and prunes old files.
With systemd (user units, `systemctl --user`), the calendar timer takes the time zone, so daylight-saving changes need nothing further:

```ini
# ~/.config/systemd/user/fm-daily-summary-sample.timer
[Timer]
OnCalendar=*:0/5
Persistent=true
[Install]
WantedBy=timers.target

# ~/.config/systemd/user/fm-daily-summary-today.timer
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target

# ~/.config/systemd/user/fm-daily-summary.timer
[Timer]
OnCalendar=*-*-* 00:05 Australia/Sydney
Persistent=true
[Install]
WantedBy=timers.target
```

Each timer's `.service` runs the matching command with `Type=oneshot`, `Environment=FM_HOME=/path/to/home`, and `ExecStart=/path/to/firstmate/bin/fm-daily-summary.sh sample`, `... generate --today`, or `... generate`.
Enable them with `systemctl --user enable --now <unit>.timer` and `loginctl enable-linger <user>` so they run without a login session.

With launchd on macOS, `StartCalendarInterval` uses the machine's local time zone, so set the box to the summary's time zone or accept that the daily run drifts by the zone difference:

```xml
<key>ProgramArguments</key>
<array><string>/path/to/firstmate/bin/fm-daily-summary.sh</string><string>generate</string></array>
<key>EnvironmentVariables</key>
<dict><key>FM_HOME</key><string>/path/to/home</string></dict>
<key>StartCalendarInterval</key>
<dict><key>Hour</key><integer>0</integer><key>Minute</key><integer>5</integer></dict>
```

Use `StartInterval` of `300` for the sampler agent and `3600` for the hourly agent, and load each with `launchctl bootstrap gui/$(id -u) <plist>`.

## Limits

- Usage limits are seen only through status lines; provider quota windows are not polled.
- The sampler probes live endpoints, so a retained task record alone never contributes worker hours.
- A re-held task's transfer pairs with the first recorded answer after that transfer; if the available records cannot establish one, the wait remains open to day end with a data-quality note.
- Project slot totals are estimates from declared project capacities and live ship endpoints; a memory gate without an existing probe cannot reduce that estimate.
- Supervisor components without an existing status probe are named in `data_quality.notes`.
- Lifetimes of tasks that finished before the ledger was turned on are invisible once their status logs are retired.
- A finished day is regenerated from the records as they are at the time of the run, so a later truncation of the ledger changes nothing already written but makes a rerun differ.
- The summary includes task ids, PR URLs, and the first non-blank line of the developer's `data/daily-blocker.txt` override when present; raw status text is not included.

`bin/fm-daily-summary.py`'s header owns the exact inputs, flags, and exit codes.
