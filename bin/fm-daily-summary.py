#!/usr/bin/env python3
"""Write the daily agent summary (schema datapel-agent-daily.v1) from a home's own records.

Usage: fm-daily-summary.py generate [--date YYYY-MM-DD | --today] [--out DIR]
                                    [--home PATH]
       fm-daily-summary.py sample   [--out DIR] [--home PATH]

docs/agent-daily-summary.md owns the file contract (schema, measures, where
each measure comes from, limits) and the scheduling recipe. This header owns
only the mechanics.

Inputs, all inside the Firstmate home (FM_HOME, or --home, or this repo):
  config/daily-summary        key=value lines: out, box, developer, working_hours
  state/fleet-ledger.jsonl    the opt-in fleet activity ledger (docs/fleet-ledger.md)
  state/<task>.status         worker status logs; only lines stamped [at=<epoch>] carry time
  state/<task>.meta           task records and endpoint addresses
  state/.last-watcher-beat    the supervision heartbeat file; only its mtime is read
  state/no-ticket.jsonl       observations written by `sample`
  config/project-capacity     declared per-project limits used for ship-slot estimates
  data/backlog.md             read through bin/fm-tasks-axi.sh for ready and excluded tasks
  data/daily-blocker.txt      the developer's own blocker line, when present
  <out>/samples.jsonl         samples written by `sample`
  journalctl --list-boots     host boots, when the command exists
FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and FM_DATA_OVERRIDE relocate those
directories exactly as the shell scripts do. Nothing under .env, projects/, or
the wake queue is ever opened, and no status text is copied into the output.

Output directory: --out, else FM_DAILY_SUMMARY_OUT, else config out=, else
~/agent-summary. generate writes <out>/daily/<date>.json atomically (temp file
in the same directory, then rename). With no --date or --today it writes the
previous complete local day, copies it to daily/latest.json, rewrites
daily/today.json with "partial": true, and deletes dated files older than
90 days. --date writes only that day (partial when the day has not ended);
--today writes only today.json.

sample appends one line to <out>/samples.jsonl: {"v":1,"ts":<epoch>,
"resident":[task ids whose endpoint is live],"supervisor_up":<bool>,
"beat_age_s":<seconds or null>}. supervisor_up requires a fresh heartbeat and
healthy installed supervisor services.

An idle observation remains active until a changed observation or a ship dispatch;
the daily writer clips it at the Sydney day boundary and carries it forward.
The sampler writes an observation from live ship capacity and backlog reads at
every five-minute tick, closing the stretch if either read fails; its reason
comes from the backlog's held and blocked state.
Each project's free slots use its declared capacity or the default of one,
minus its own live ship endpoints; the sampler sums those free slots.
A held transfer uses the first recorded answer after it, leaving a wait open
with a data-quality note when that answer time cannot be established.

Exit status: 0 on success, 2 on a usage or configuration error, 1 when the
output could not be written.
"""

import argparse
import datetime as dt
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python < 3.9
    ZoneInfo = None

SCHEMA = 'datapel-agent-daily.v1'
DEFAULT_TZ = 'Australia/Sydney'
DEFAULT_KEEP_DAYS = 90
DEFAULT_SAMPLE_GAP_MINUTES = 15
DEFAULT_BEAT_STALE_SECONDS = 900
TEST_NOW_ENV = 'FM_DAILY_SUMMARY_TEST_NOW'
NO_TICKET_REASONS = ('empty_queue', 'all_blocked', 'not_required', 'awaiting_ruling', 'out_of_scope', 'mixed')
CAUSE_ORDER = ('usage_limit', 'host_down', 'supervisor_down', 'credential', 'waiting_on_human', 'other')
USAGE_LIMIT_RE = re.compile(r'usage[ -]?limit|quota|rate[ -]?limit|exhausted', re.I)
CREDENTIAL_RE = re.compile(r'\b(login|logged in|credential|token expired|token has expired|re-?auth\w*|auth\w* (expired|failed|required))\b', re.I)
PROVIDER_RE = re.compile(r'\b(claude|anthropic|codex|openai|gemini|google|grok|xai|kimi|moonshot|cursor|devin|pi)\b', re.I)
PROVIDER_FAMILY = {'anthropic': 'claude', 'openai': 'codex', 'google': 'gemini', 'xai': 'grok', 'moonshot': 'kimi'}
STATUS_RE = re.compile(r'^([A-Za-z][A-Za-z-]*)((?:\s*\[[^\]]*\])*)\s*:(.*)$')
TAG_RE = re.compile(r'\[([a-z]+)=([^\]]*)\]')
BOOT_TS_RE = re.compile(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) UTC')
DATE_FILE_RE = re.compile(r'^(\d{4}-\d{2}-\d{2})\.json$')
TASK_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
META_KEYS = ('kind', 'harness', 'model')


class UsageError(Exception):
    pass


# --- home and configuration -------------------------------------------------

def repo_root():
    return Path(__file__).resolve().parent.parent


def resolve_home(arg):
    home = arg or os.environ.get('FM_HOME') or os.environ.get('FM_ROOT_OVERRIDE') or str(repo_root())
    return Path(home).expanduser()


def home_dirs(home):
    state = Path(os.environ.get('FM_STATE_OVERRIDE') or home / 'state')
    config = Path(os.environ.get('FM_CONFIG_OVERRIDE') or home / 'config')
    data = Path(os.environ.get('FM_DATA_OVERRIDE') or home / 'data')
    return state, config, data


def read_config(config_dir):
    cfg = {}
    path = config_dir / 'daily-summary'
    if not path.is_file():
        return cfg
    for raw in path.read_text(encoding='utf-8', errors='replace').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        cfg[key.strip()] = value.strip()
    return cfg


def resolve_out(arg, cfg):
    out = arg or os.environ.get('FM_DAILY_SUMMARY_OUT') or cfg.get('out') or '~/agent-summary'
    return Path(out).expanduser()


def resolve_tz():
    if ZoneInfo is None:
        raise UsageError('Python 3.9+ with zoneinfo is required')
    try:
        return DEFAULT_TZ, ZoneInfo(DEFAULT_TZ)
    except Exception:
        raise UsageError('Australia/Sydney time zone is unavailable')


def parse_now(arg=None):
    arg = arg or os.environ.get(TEST_NOW_ENV)
    if not arg:
        return dt.datetime.now(dt.timezone.utc)
    text = arg.strip()
    if text.endswith('Z'):
        text = text[:-1] + '+00:00'
    try:
        value = dt.datetime.fromisoformat(text)
    except ValueError:
        raise UsageError('%s must be an ISO 8601 timestamp, got %r' % (TEST_NOW_ENV, arg))
    if value.tzinfo is None:
        raise UsageError('%s must carry a UTC offset or Z' % TEST_NOW_ENV)
    return value.astimezone(dt.timezone.utc)


# --- time helpers -----------------------------------------------------------

def epoch(value):
    return value.timestamp()


def iso_local(ts, tz):
    return dt.datetime.fromtimestamp(ts, tz).isoformat(timespec='seconds')


def iso_utc(value):
    return value.astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def hours(seconds):
    return round(seconds / 3600.0, 2)


def day_window(date, tz):
    start = dt.datetime.combine(date, dt.time(0, 0), tzinfo=tz)
    end = dt.datetime.combine(date + dt.timedelta(days=1), dt.time(0, 0), tzinfo=tz)
    return epoch(start), epoch(end)


def clip(intervals, lo, hi):
    out = []
    for a, b in intervals:
        a2, b2 = max(a, lo), min(b, hi)
        if b2 > a2:
            out.append((a2, b2))
    return out


def union(intervals):
    merged = []
    for a, b in sorted(intervals):
        if merged and a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    return merged


def total(intervals):
    return sum(b - a for a, b in intervals)


def subtract(intervals, holes):
    holes = union(holes)
    out = []
    for a, b in intervals:
        cursor = a
        for h0, h1 in holes:
            if h1 <= cursor or h0 >= b:
                continue
            if h0 > cursor:
                out.append((cursor, h0))
            cursor = max(cursor, h1)
            if cursor >= b:
                break
        if cursor < b:
            out.append((cursor, b))
    return out


def intersect(left, right):
    out = []
    for a, b in union(left):
        for c, d in union(right):
            lo, hi = max(a, c), min(b, d)
            if hi > lo:
                out.append((lo, hi))
    return union(out)


def coverage(points, gap, window_end):
    """Intervals each sample point covers: until the next point, capped at gap."""
    out = []
    for i, ts in enumerate(points):
        nxt = points[i + 1] if i + 1 < len(points) else window_end
        out.append((ts, min(nxt, ts + gap, window_end)))
    return [(a, b) for a, b in out if b > a]


# --- record readers ---------------------------------------------------------

def read_jsonl(path):
    rows = []
    if not path.is_file():
        return rows
    with path.open('r', encoding='utf-8', errors='replace') as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows


def parse_status_line(line):
    match = STATUS_RE.match(line.rstrip('\n'))
    if not match:
        return None
    state, tags, text = match.group(1), match.group(2), match.group(3)
    at = key = None
    for name, value in TAG_RE.findall(tags + text):
        if name == 'at' and value.isdigit() and not value.startswith('0') and len(value) <= 12:
            at = int(value)
        elif name == 'key':
            key = value
    return {'state': state, 'at': at, 'key': key, 'text': text.strip()}


def read_meta(path):
    meta = {}
    try:
        with path.open('r', encoding='utf-8', errors='replace') as handle:
            for line in handle:
                if '=' not in line:
                    continue
                key, value = line.rstrip('\n').split('=', 1)
                if key in META_KEYS:
                    meta[key] = value
    except OSError:
        return None
    return meta


class Records:
    """Everything the generator reads, collected once."""

    def __init__(self, home, state, data, out, cfg, now_ts):
        self.notes = []
        self.now = now_ts
        self.ledger_path = state / 'fleet-ledger.jsonl'
        self.ledger = read_jsonl(self.ledger_path) if self.ledger_path.is_file() else []
        self.has_ledger = self.ledger_path.is_file()
        self.samples = [r for r in read_jsonl(out / 'samples.jsonl') if isinstance(r.get('ts'), (int, float))]
        self.samples.sort(key=lambda r: r['ts'])
        missing_probes = sorted({name for row in self.samples for name in row.get('probe_missing', [])})
        for name in missing_probes:
            self.notes.append('%s supervisor probe unavailable' % name)
        for note in sorted({r['selection_note'] for r in self.samples if isinstance(r.get('selection_note'), str)}):
            self.notes.append(note)
        self.observations = [r for r in read_jsonl(state / 'no-ticket.jsonl') if isinstance(r.get('ts'), (int, float))]
        self.observations.sort(key=lambda r: r['ts'])
        self.tasks = {}
        self.events = []
        self.unstamped = 0
        self._read_tasks(state)
        self._read_ledger()
        self.blocker_override = self._read_blocker(data)
        self.home = home
        self.held_resolutions = {}
        held_checked = set()
        for event in self.events:
            if event['state'] == 'resolved' and event['key'] and event['key'].startswith('captain-hold-'):
                match = re.search(r'\bcaptain hold ([A-Za-z0-9._-]+):', event['text'])
                if match:
                    self.held_resolutions.setdefault(match.group(1), []).append(event['ts'])
        for event in self.events:
            if event['state'] == 'captain-held' and event['key']:
                match = re.search(r'\btracked by ([A-Za-z0-9._-]+(?:,[A-Za-z0-9._-]+)*)', event['text'])
                if match:
                    held_ids = match.group(1).split(',')
                    for held_id in held_ids:
                        if held_id not in self.held_resolutions:
                            self.held_resolutions[held_id] = []
                        if held_id not in held_checked:
                            probe = subprocess.run([str(repo_root() / 'bin/fm-captain-hold.sh'), 'open', held_id],
                                                   env=dict(os.environ, FM_HOME=str(self.home)),
                                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                            held_checked.add(held_id)
                            if probe.returncode not in (0, 1):
                                self.notes.append('captain hold state unavailable for %s' % held_id)
                            else:
                                shown = subprocess.run([str(repo_root() / 'bin/fm-tasks-axi.sh'), 'show', held_id, '--full'],
                                                       env=dict(os.environ, FM_HOME=str(self.home)),
                                                       capture_output=True, text=True)
                                if shown.returncode == 0 and 'Resolution recorded by fm-captain-hold.' in shown.stdout:
                                    for stamp in re.findall(r'Resolution recorded at: (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)', shown.stdout):
                                        answer = epoch(dt.datetime.fromisoformat(stamp.replace('Z', '+00:00')))
                                        if answer not in self.held_resolutions[held_id]:
                                            self.held_resolutions[held_id].append(answer)
                    event['held_ids'] = held_ids
                    if held_answer_time(event, self.held_resolutions) is None:
                        self.notes.append('captain hold answer time unavailable after transfer at %s' % event['ts'])

    def task(self, task_id):
        return self.tasks.setdefault(task_id, {
            'id': task_id, 'kind': None, 'harness': None, 'model': None,
            'dispatched': None, 'cleaned_up': None, 'meta': False,
            'first_event': None, 'last_event': None, 'status_source': None,
        })

    def _read_tasks(self, state):
        if not state.is_dir():
            return
        for path in sorted(state.iterdir()):
            name = path.name
            if name.startswith('.'):
                continue
            if name.endswith('.meta'):
                task_id = name[:-5]
                if not TASK_RE.match(task_id):
                    continue
                meta = read_meta(path)
                if meta is None:
                    continue
                task = self.task(task_id)
                task['meta'] = True
                try:
                    task['meta_mtime'] = path.stat().st_mtime
                except OSError:
                    pass
                for key in META_KEYS:
                    if meta.get(key) and task.get(key) is None:
                        task[key] = None if key == 'model' and meta[key] in ('default', '-') else meta[key]
            elif name.endswith('.status'):
                task_id = name[:-7]
                if not TASK_RE.match(task_id):
                    continue
                self._read_status(task_id, path)

    def _read_status(self, task_id, path):
        task = self.task(task_id)
        task['status_source'] = 'log'
        try:
            lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
        except OSError:
            return
        for line in lines:
            parsed = parse_status_line(line)
            if parsed is None:
                continue
            if parsed['at'] is None:
                self.unstamped += 1
                continue
            self._add_event(task, parsed['at'], parsed['state'], parsed['key'], parsed['text'])

    def _add_event(self, task, ts, state, key, text):
        self.events.append({'task': task['id'], 'ts': ts, 'state': state, 'key': key, 'text': text})
        if task['first_event'] is None or ts < task['first_event']:
            task['first_event'] = ts
        if task['last_event'] is None or ts > task['last_event']:
            task['last_event'] = ts

    def _read_ledger(self):
        for row in self.ledger:
            ts, event, task_id = row.get('ts'), row.get('event'), row.get('task')
            if not isinstance(ts, (int, float)) or not isinstance(task_id, str) or not TASK_RE.match(task_id):
                continue
            task = self.task(task_id)
            if event == 'task.dispatched':
                task['dispatched'] = ts
                for key in META_KEYS:
                    value = row.get(key)
                    if isinstance(value, str) and value:
                        task[key] = value
            elif event == 'task.cleaned_up':
                task['cleaned_up'] = ts
            elif event == 'task.pr_ready':
                task.setdefault('prs_ready', []).append((ts, row.get('pr')))
            elif event == 'task.merged':
                task.setdefault('prs_merged', []).append((ts, row.get('pr')))
            elif event == 'task.status' and task['status_source'] != 'log':
                task['status_source'] = 'ledger'
                state = row.get('state')
                if isinstance(state, str):
                    self._add_event(task, ts, state, row.get('key'), str(row.get('text') or '').strip())
        self.events.sort(key=lambda e: e['ts'])

    @staticmethod
    def _read_blocker(data):
        path = data / 'daily-blocker.txt'
        if not path.is_file():
            return None
        for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
            if line.strip():
                return line.strip()
        return None


# --- measures ----------------------------------------------------------------

def task_lifetime(task, records, window_end, partial):
    """[start, end] the records support, with a note code when approximated."""
    note = None
    start = task['dispatched']
    if start is None:
        start = task['first_event']
        note = 'start from first status line'
    if start is None and task['meta']:
        start = task.get('meta_mtime')
        note = 'start from task record time'
    if start is None:
        return None, None
    end = task['cleaned_up']
    if end is None:
        if task['meta']:
            end = records.now if partial else window_end
            end = max(end, start)
        elif task['last_event'] is not None:
            end = max(task['last_event'], start)
            note = (note + '; ' if note else '') + 'end from last status line'
        else:
            end = start
    return (start, end), note


def agent_measures(records, window, partial, gap, host_down):
    lo, hi = window
    # The observed part of the window: a finished day is whole, a partial day
    # ends at the clock, so nothing after it counts as a sampler gap.
    obs_hi = min(records.now, hi) if partial else hi
    notes = []
    points = [r for r in records.samples if lo <= r['ts'] < obs_hi]
    sample_ts = [p['ts'] for p in points]
    sampled = union(coverage(sample_ts, gap, obs_hi)) if points else []
    unsampled = subtract([(lo, obs_hi)], sampled) if obs_hi > lo else []
    seen = {}
    for i, point in enumerate(points):
        nxt = sample_ts[i + 1] if i + 1 < len(sample_ts) else obs_hi
        span = (point['ts'], min(nxt, point['ts'] + gap, obs_hi))
        for task_id in point.get('resident') or []:
            if isinstance(task_id, str):
                seen.setdefault(task_id, []).append(span)
    agent_seconds = 0.0
    dispatched = []
    approximated = 0
    for task in records.tasks.values():
        life, note = task_lifetime(task, records, hi, partial)
        if life is None:
            continue
        if note:
            approximated += 1
        alive = subtract(intersect(clip([life], lo, hi), union(seen.get(task['id'], []))), host_down)
        agent_seconds += total(alive)
        if lo <= life[0] < hi and (task['dispatched'] is not None or task['first_event'] is not None):
            dispatched.append(task)
    if approximated:
        notes.append('%d agent lifetime(s) approximated from status lines or task records' % approximated)
    if not records.has_ledger:
        notes.append('fleet ledger off: dispatch counts come from status logs and task records, cleaned-up tasks are invisible')
    supervisor = []
    for i, point in enumerate(points):
        if point.get('supervisor_up') is True:
            nxt = sample_ts[i + 1] if i + 1 < len(sample_ts) else obs_hi
            supervisor.append((point['ts'], min(nxt, point['ts'] + gap, obs_hi)))
    supervisor = subtract(union(supervisor), host_down)
    if points:
        agent_seconds += total(supervisor)
    else:
        notes.append('no samples in window: supervisor hours unknown and not added to agent_hours')
    by_kind, by_harness = {}, {}
    for task in dispatched:
        kind = task['kind'] or 'unknown'
        harness = task['harness'] or 'unknown'
        by_kind[kind] = by_kind.get(kind, 0) + 1
        by_harness[harness] = by_harness.get(harness, 0) + 1
    gaps_minutes = int(round(total(unsampled) / 60.0))
    return {
        'agent_hours': hours(agent_seconds),
        'agents_dispatched': len(dispatched),
        'dispatched_by_kind': dict(sorted(by_kind.items())),
        'harnesses': dict(sorted(by_harness.items())),
        'supervisor_intervals': supervisor,
        'sampled': sampled,
        'unsampled': unsampled,
        'sampler_gaps_minutes': gaps_minutes,
        'has_samples': bool(points),
        'notes': notes,
    }


def host_boots(records, window):
    """Host up intervals and boots from journalctl, or None when unavailable."""
    if shutil.which('journalctl') is None:
        return None
    try:
        proc = subprocess.run(['journalctl', '--list-boots', '--utc', '--no-pager'],
                              capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    boots = []
    for line in proc.stdout.splitlines():
        stamps = BOOT_TS_RE.findall(line)
        if len(stamps) < 2:
            continue
        first = dt.datetime.strptime(stamps[0], '%Y-%m-%d %H:%M:%S').replace(tzinfo=dt.timezone.utc)
        last = dt.datetime.strptime(stamps[1], '%Y-%m-%d %H:%M:%S').replace(tzinfo=dt.timezone.utc)
        boots.append((epoch(first), epoch(last)))
    boots.sort()
    if not boots:
        return None
    lo, hi = window
    # The newest boot is still running: its last entry is only the newest log line.
    boots[-1] = (boots[-1][0], max(boots[-1][1], records.now))
    up = clip(boots, lo, hi)
    down = []
    for i in range(1, len(boots)):
        prev_end, start = boots[i - 1][1], boots[i][0]
        if start > prev_end:
            down.append((prev_end, start))
    return {'up': union(up), 'down': clip(down, lo, hi), 'boots': sum(1 for b in boots if lo <= b[0] < hi)}


def classify_cause(event, task):
    text = event['text']
    if event['state'] in ('blocked', 'paused') and USAGE_LIMIT_RE.search(text):
        provider = None
        match = PROVIDER_RE.search(text)
        if match:
            name = match.group(1).lower()
            provider = PROVIDER_FAMILY.get(name, name)
        return 'usage_limit', provider or task.get('harness')
    if event['state'] in ('blocked', 'paused', 'needs-decision') and CREDENTIAL_RE.search(text):
        return 'credential', None
    if event['state'] == 'needs-decision':
        return 'waiting_on_human', None
    if event['state'] == 'blocked':
        return 'other', None
    return None, None


def held_answer_time(event, held_resolutions):
    ids = event.get('held_ids') or []
    answers = [min((ts for ts in held_resolutions.get(task_id, []) if ts > event['ts']), default=None)
               for task_id in ids]
    return max(answers) if answers and all(ts is not None for ts in answers) else None


def close_time(event, events_for_task, index, held_resolutions):
    """When a blocked/paused/needs-decision event ended, or None while open."""
    held_active = False
    for later in events_for_task[index + 1:]:
        if event['key'] and later['state'] == 'resolved' and later['key'] == event['key']:
            return later['ts']
        if event['state'] == 'needs-decision' and later['state'] == 'captain-held' and later['key'] == event['key']:
            answer_time = held_answer_time(later, held_resolutions)
            if answer_time is not None and answer_time >= later['ts']:
                return answer_time
            held_active = True
            continue
        if held_active:
            continue
        if later['state'] in ('working', 'done', 'failed') or (not event['key'] and later['state'] == 'resolved'):
            return later['ts']
        if later['state'] in ('blocked', 'paused', 'needs-decision') and later['key'] != event['key']:
            return later['ts']
    return None


def lost_items(records, window, partial, host, supervisor_down):
    lo, hi = window
    items = []
    per_task = {}
    for event in records.events:
        per_task.setdefault(event['task'], []).append(event)
    for task_id, events in per_task.items():
        task = records.tasks[task_id]
        for index, event in enumerate(events):
            cause, provider = classify_cause(event, task)
            if cause is None:
                continue
            end = close_time(event, events, index, records.held_resolutions)
            if end is None:
                end = records.now if partial else hi
                if task['cleaned_up'] is not None and not any(
                        later['state'] == 'captain-held' and later['key'] == event['key'] and
                        held_answer_time(later, records.held_resolutions) is None
                        for later in events[index + 1:]):
                    end = min(end, task['cleaned_up'])
            start = event['ts']
            if end <= start or end <= lo or start >= hi:
                continue
            item = {'cause': cause, 'start': max(start, lo), 'end': min(end, hi), 'task': task_id}
            if cause == 'usage_limit':
                item['provider'] = provider
            items.append(item)
    if host:
        for a, b in host['down']:
            items.append({'cause': 'host_down', 'start': a, 'end': b})
    for a, b in supervisor_down:
        items.append({'cause': 'supervisor_down', 'start': a, 'end': b})
    items.sort(key=lambda i: (i['start'], CAUSE_ORDER.index(i['cause'])))
    return items


def no_ticket_stretches(records, window, lost_intervals, partial):
    lo, hi = window
    if partial:
        hi = min(hi, records.now)
    events = [(o['ts'], 0, o) for o in records.observations if o['ts'] < hi]
    events.extend((task['dispatched'], 1, None)
                  for task in records.tasks.values() if task['kind'] == 'ship' and
                  task['dispatched'] is not None and task['dispatched'] < hi)
    events.sort(key=lambda entry: (entry[0], entry[1]))
    stretches = []
    current = None
    for ts, _order, row in events:
        if row is not None and row.get('event') == 'no_ticket':
            signature = (row.get('free_slots'), row.get('reason'), row.get('detail'))
            if current and current['signature'] == signature:
                continue
            if current:
                stretches.append({'start': current['start'], 'end': ts, 'row': current['row']})
            current = {'start': ts, 'signature': signature, 'row': row}
        elif row is None or row.get('event') in ('ticket_found', 'selection_unknown'):
            if current:
                stretches.append({'start': current['start'], 'end': ts, 'row': current['row']})
                current = None
    if current:
        stretches.append({'start': current['start'], 'end': hi, 'row': current['row']})
    out = []
    for stretch in stretches:
        kept = subtract(clip([(stretch['start'], stretch['end'])], lo, hi), lost_intervals)
        if not kept:
            continue
        row = stretch['row']
        reason = row.get('reason') if row.get('reason') in NO_TICKET_REASONS else 'mixed'
        free = int(row.get('free_slots') or 0)
        detail = row.get('detail') if isinstance(row.get('detail'), dict) else {}
        for a, b in kept:
            out.append({'start': a, 'end': b, 'hours': hours(b - a), 'free_slots': free,
                        'reason': reason, 'detail': detail})
    return out


def output_measures(records, window):
    lo, hi = window
    ready, merged = [], []
    done = failed = 0
    terminal = {}
    for task in records.tasks.values():
        for ts, pr in task.get('prs_ready', []):
            if lo <= ts < hi and isinstance(pr, str) and pr not in ready:
                ready.append(pr)
        for ts, pr in task.get('prs_merged', []):
            if lo <= ts < hi and isinstance(pr, str) and pr not in merged:
                merged.append(pr)
    for event in records.events:
        if lo <= event['ts'] < hi and event['state'] in ('done', 'failed'):
            terminal[event['task']] = event['state']
    if not records.has_ledger:
        for event in records.events:
            if lo <= event['ts'] < hi and event['state'] == 'done':
                for url in re.findall(r'https://\S+/pull/\d+|https://\S+/merge_requests/\d+', event['text']):
                    if url not in ready:
                        ready.append(url)
    for state in terminal.values():
        if state == 'done':
            done += 1
        else:
            failed += 1
    return {'prs_ready': ready, 'prs_merged': merged, 'tasks_done': done, 'tasks_failed': failed}


def blocker_line(records, window, partial, tz):
    if records.blocker_override:
        return records.blocker_override
    lo, hi = window
    per_task = {}
    for event in records.events:
        per_task.setdefault(event['task'], []).append(event)
    newest = None
    for task_id, events in per_task.items():
        for index, event in enumerate(events):
            if event['state'] not in ('blocked', 'needs-decision'):
                continue
            if close_time(event, events, index, records.held_resolutions) is not None:
                continue
            if records.tasks[task_id]['cleaned_up'] is not None and not any(
                    later['state'] == 'captain-held' and later['key'] == event['key'] and
                    held_answer_time(later, records.held_resolutions) is None
                    for later in events[index + 1:]):
                continue
            if event['ts'] >= hi:
                continue
            if newest is None or event['ts'] > newest['ts']:
                newest = event
    if newest is None:
        return None
    what = 'decision' if newest['state'] == 'needs-decision' else 'blocker'
    line = 'task %s has an open %s since %s' % (newest['task'], what, iso_local(newest['ts'], tz))
    if newest['key']:
        line += ' (%s)' % newest['key']
    return line


def working_hours_field(cfg):
    value = cfg.get('working_hours')
    if not value:
        return None
    match = re.fullmatch(r'(\d{2}):(\d{2})-(\d{2}):(\d{2})(?: ([A-Za-z,-]+))?', value)
    if not match:
        raise UsageError('working_hours must be HH:MM-HH:MM [days]')
    if any(int(match.group(i)) > (23 if i in (1, 3) else 59) for i in range(1, 5)):
        raise UsageError('working_hours must be HH:MM-HH:MM [days]')
    field = {'start': '%s:%s' % (match.group(1), match.group(2)),
             'end': '%s:%s' % (match.group(3), match.group(4))}
    if match.group(5):
        field['days'] = match.group(5)
    return field


# --- the summary --------------------------------------------------------------

def build_summary(date, records, cfg, tz_name, tz, now, partial):
    window = day_window(date, tz)
    lo, hi = window
    sample_gap = DEFAULT_SAMPLE_GAP_MINUTES * 60
    notes = list(records.notes)
    host = host_boots(records, window)
    agents = agent_measures(records, window, partial, sample_gap, host['down'] if host else [])
    notes.extend(agents['notes'])
    if host is None:
        notes.append('host uptime unknown: journalctl boot list unavailable')
    up_to = min(epoch(now), hi) if partial else hi
    observed = clip(host['up'], lo, up_to) if host else ([(lo, up_to)] if agents['has_samples'] else [])
    supervisor_down = subtract(observed, agents['supervisor_intervals'])
    items = lost_items(records, window, partial, host, supervisor_down)
    lost_intervals = union([(i['start'], i['end']) for i in items])
    stretches = no_ticket_stretches(records, window, lost_intervals, partial)
    no_ticket_total = total(union([(s['start'], s['end']) for s in stretches]))
    if not any(row.get('event') in ('no_ticket', 'ticket_found') for row in records.observations):
        notes.append('no no-ticket observations recorded: no_ticket_hours assumes none')
    if records.unstamped:
        notes.append('%d status line(s) without a time stamp ignored' % records.unstamped)
    if not records.events and not records.ledger:
        notes.append('no task records found in the home')
    out = output_measures(records, window)
    capacity = {
        'agent_hours': agents['agent_hours'],
        'agents_dispatched': agents['agents_dispatched'],
        'dispatched_by_kind': agents['dispatched_by_kind'],
        'harnesses': agents['harnesses'],
        'no_ticket_hours': hours(no_ticket_total),
        'no_ticket_stretches': [
            {'start': iso_local(s['start'], tz), 'end': iso_local(s['end'], tz), 'hours': s['hours'],
             'free_slots': s['free_slots'], 'reason': s['reason'], 'detail': s['detail']}
            for s in stretches
        ],
    }
    working = working_hours_field(cfg)
    if working:
        capacity['working_hours'] = working
    lost = []
    for item in items:
        row = {'cause': item['cause']}
        if item['cause'] == 'usage_limit':
            row['provider'] = item.get('provider')
        row['start'] = iso_local(item['start'], tz)
        row['end'] = iso_local(item['end'], tz)
        row['hours'] = hours(item['end'] - item['start'])
        if 'task' in item:
            row['task'] = item['task']
        lost.append(row)
    uptime = {
        'host_up_hours': hours(total(host['up'])) if host else None,
        'supervisor_up_hours': hours(total(agents['supervisor_intervals'])) if agents['has_samples'] else None,
        'boots': host['boots'] if host else None,
    }
    return {
        'schema': SCHEMA,
        'box': cfg.get('box') or socket.gethostname().split('.')[0],
        'developer': cfg.get('developer') or None,
        'date': date.isoformat(),
        'tz': tz_name,
        'window': {'start': iso_local(lo, tz), 'end': iso_local(hi, tz)},
        'generated_at': iso_utc(now),
        'partial': partial,
        'capacity': capacity,
        'output': out,
        'lost': {'hours_total': hours(total(lost_intervals)), 'items': lost},
        'uptime': uptime,
        'blocker': blocker_line(records, window, partial, tz),
        'data_quality': {
            'ledger': records.has_ledger,
            'sampler_gaps_minutes': agents['sampler_gaps_minutes'],
            'notes': notes,
        },
    }


def write_atomic(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, indent=2, sort_keys=False) + '\n'
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def prune(daily_dir, today, keep_days):
    if keep_days <= 0 or not daily_dir.is_dir():
        return
    cutoff = today - dt.timedelta(days=keep_days)
    for path in daily_dir.iterdir():
        match = DATE_FILE_RE.match(path.name)
        if not match:
            continue
        try:
            file_date = dt.date.fromisoformat(match.group(1))
        except ValueError:
            continue
        if file_date < cutoff:
            try:
                path.unlink()
            except OSError:
                pass


def cmd_generate(args):
    home = resolve_home(args.home)
    state, config_dir, data = home_dirs(home)
    cfg = read_config(config_dir)
    out = resolve_out(args.out, cfg)
    tz_name, tz = resolve_tz()
    now = parse_now()
    today = now.astimezone(tz).date()
    records = Records(home, state, data, out, cfg, epoch(now))
    daily = out / 'daily'
    jobs = []
    if args.date:
        try:
            date = dt.date.fromisoformat(args.date)
        except ValueError:
            raise UsageError('--date must be YYYY-MM-DD, got %r' % args.date)
        jobs.append((date, date >= today, [daily / ('%s.json' % date.isoformat())]))
    elif args.today:
        jobs.append((today, True, [daily / 'today.json']))
    else:
        yesterday = today - dt.timedelta(days=1)
        jobs.append((yesterday, False, [daily / ('%s.json' % yesterday.isoformat()), daily / 'latest.json']))
        jobs.append((today, True, [daily / 'today.json']))
    for date, partial, targets in jobs:
        summary = build_summary(date, records, cfg, tz_name, tz, now, partial)
        for target in targets:
            write_atomic(target, summary)
    if not args.date and not args.today:
        prune(daily, today, DEFAULT_KEEP_DAYS)
    return 0


def cmd_sample(args):
    home = resolve_home(args.home)
    state, config_dir, _data = home_dirs(home)
    cfg = read_config(config_dir)
    out = resolve_out(args.out, cfg)
    now = parse_now()
    resident = []
    live_ships = {}
    if state.is_dir():
        for path in sorted(state.iterdir()):
            if path.name.endswith('.meta') and not path.name.startswith('.') and TASK_RE.match(path.name[:-5]):
                task_id = path.name[:-5]
                meta = path.read_text(encoding='utf-8', errors='replace')
                if re.search(r'^remote_host=.+$', meta, re.M):
                    probe = subprocess.run([str(repo_root() / 'bin/fm-crew-state.sh'), task_id],
                                           env=dict(os.environ, FM_HOME=str(home)), capture_output=True, text=True)
                    live = probe.returncode == 0 and (
                        'remote endpoint alive on ' in probe.stdout or
                        ('source: remote-endpoint' in probe.stdout and 'alive on ' in probe.stdout))
                else:
                    probe = subprocess.run(
                        ['bash', '-c', '. "$1"; fm_backend_agent_state "$(fm_backend_of_meta "$2")" "$(fm_backend_target_of_meta "$2")"',
                         'endpoint', str(repo_root() / 'bin/fm-backend.sh'), str(path)],
                        env=dict(os.environ, FM_HOME=str(home)), capture_output=True, text=True)
                    live = probe.returncode == 0 and probe.stdout.strip() == 'alive'
                if live:
                    resident.append(task_id)
                    if re.search(r'^kind=ship$', meta, re.M) or not re.search(r'^kind=', meta, re.M):
                        project_match = re.search(r'^project=(.+)$', meta, re.M)
                        project = Path(project_match.group(1).rstrip('/')).name if project_match else ''
                        live_ships[project] = live_ships.get(project, 0) + 1
    beat_age = None
    beat = state / '.last-watcher-beat'
    try:
        beat_age = max(0, int(epoch(now) - beat.stat().st_mtime))
    except OSError:
        beat_age = None
    probes = []
    missing = []
    for command in (['herdr', 'status', '--json'], ['no-mistakes', 'daemon', 'status']):
        if shutil.which(command[0]):
            try:
                probes.append(subprocess.run(command, stdout=subprocess.DEVNULL,
                                             stderr=subprocess.DEVNULL, timeout=10).returncode == 0)
            except subprocess.TimeoutExpired:
                probes.append(False)
        else:
            missing.append(command[0])
    row = {'v': 1, 'ts': int(epoch(now)), 'resident': resident,
           'supervisor_up': beat_age is not None and beat_age < DEFAULT_BEAT_STALE_SECONDS and all(probes),
           'beat_age_s': beat_age, 'probe_missing': missing}
    capacities = {}
    capacity_file = config_dir / 'project-capacity'
    if capacity_file.exists() or capacity_file.is_symlink():
        check = subprocess.run(
            ['bash', '-c', '. "$1"; fm_project_capacity_lookup "$2" ""',
             'capacity', str(repo_root() / 'bin/fm-project-capacity-lib.sh'), str(config_dir)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if check.returncode:
            row['selection_note'] = 'project capacity unreadable: no automatic ticket observation'
        else:
            try:
                capacity_lines = capacity_file.read_text(encoding='utf-8', errors='replace').splitlines()
            except OSError:
                row['selection_note'] = 'project capacity unreadable: no automatic ticket observation'
            else:
                for line in capacity_lines:
                    line = line.strip()
                    if not line or line == '#' or re.match(r'^#\s', line) or (
                            line.startswith('#') and not re.fullmatch(r'[0-9]+', line.rsplit(None, 1)[-1])):
                        continue
                    name, limit = line.rsplit(None, 1)
                    capacities[name] = int(limit)
    if 'selection_note' not in row:
        home_env = dict(os.environ, FM_HOME=str(home))
        groups = []
        for command in (('ready',), ('list', '--state', 'held', '--fields', 'id,state,kind,repo,title'),
                        ('list', '--state', 'queued', '--blocked', '--fields', 'id,state,kind,repo,title')):
            result = subprocess.run([str(repo_root() / 'bin/fm-tasks-axi.sh'), *command],
                                    env=home_env, capture_output=True, text=True)
            if result.returncode:
                row['selection_note'] = 'backlog selection unavailable: no automatic ticket observation'
                break
            groups.append(re.findall(r'^  [^,\n]+,[^,\n]+,ship,([^,\n]+),', result.stdout, re.M))
        if len(groups) == 3:
            ready, held, blocked = groups
            projects = set(capacities) | set(live_ships) | set(ready) | set(held) | set(blocked)
            if not projects:
                projects.add('')
            free_slots = sum(max(0, capacities.get(project, 1) - live_ships.get(project, 0))
                             for project in projects)
            if free_slots and not ready:
                detail = {'assigned_open': len(held) + len(blocked), 'held': len(held), 'blocked': len(blocked)}
                reason = ('mixed' if held and blocked else 'awaiting_ruling' if held else
                          'all_blocked' if blocked else 'empty_queue')
                observation = {'v': 1, 'ts': int(epoch(now)), 'event': 'no_ticket',
                               'free_slots': free_slots, 'reason': reason, 'detail': detail}
            else:
                observation = {'v': 1, 'ts': int(epoch(now)), 'event': 'ticket_found'}
            state.mkdir(parents=True, exist_ok=True)
            append_line(state / 'no-ticket.jsonl', observation)
    if 'selection_note' in row:
        state.mkdir(parents=True, exist_ok=True)
        append_line(state / 'no-ticket.jsonl',
                    {'v': 1, 'ts': int(epoch(now)), 'event': 'selection_unknown'})
    out.mkdir(parents=True, exist_ok=True)
    append_line(out / 'samples.jsonl', row)
    return 0


def append_line(path, row):
    line = json.dumps(row, separators=(',', ':')) + '\n'
    fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line.encode('utf-8'))
    finally:
        os.close(fd)


def build_parser():
    parser = argparse.ArgumentParser(prog='fm-daily-summary', description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command')
    sub.required = True

    def common(p):
        p.add_argument('--home', help='Firstmate operational home (default FM_HOME or this repo)')

    gen = sub.add_parser('generate', help='write the daily summary files')
    common(gen)
    gen.add_argument('--out', help='output directory (default FM_DAILY_SUMMARY_OUT, config out=, or ~/agent-summary)')
    which = gen.add_mutually_exclusive_group()
    which.add_argument('--date', help='write only this local day (YYYY-MM-DD)')
    which.add_argument('--today', action='store_true', help='write only daily/today.json')
    gen.set_defaults(func=cmd_generate)

    smp = sub.add_parser('sample', help='append one sample to <out>/samples.jsonl')
    common(smp)
    smp.add_argument('--out', help='output directory')
    smp.set_defaults(func=cmd_sample)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except UsageError as exc:
        sys.stderr.write('fm-daily-summary: %s\n' % exc)
        return 2
    except OSError as exc:
        sys.stderr.write('fm-daily-summary: %s\n' % exc)
        return 1


if __name__ == '__main__':
    sys.exit(main())
