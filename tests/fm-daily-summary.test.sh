#!/usr/bin/env bash
# tests/fm-daily-summary.test.sh - the daily agent summary generator against
# fixture homes: measures from ledger, status logs, task records, samples,
# no-ticket observations, and a fake journalctl; the file set it writes; the
# sampler observations; and that no secret or raw status text reaches the output.
# docs/agent-daily-summary.md owns the file contract.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import datetime as dt
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from zoneinfo import ZoneInfo

repo = Path(sys.argv[1])
script = repo / 'bin/fm-daily-summary.sh'
tz = ZoneInfo('Australia/Sydney')
H = 3600
DAY = dt.date(2026, 10, 13)
lo = int(dt.datetime.combine(DAY, dt.time(0, 0), tzinfo=tz).timestamp())
SECRET = 'SECRETTOKEN123456'


def jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(''.join(json.dumps(r) + '\n' for r in rows))


def run(args, env=None, ok=True):
    full = dict(os.environ)
    for key in ('FM_HOME', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_DAILY_SUMMARY_OUT', 'FM_DAILY_SUMMARY_TEST_NOW'):
        full.pop(key, None)
    full.update(env or {})
    args = list(args)
    if '--now' in args:
        index = args.index('--now')
        full['FM_DAILY_SUMMARY_TEST_NOW'] = args[index + 1]
        del args[index:index + 2]
    printed = '--stdout' in args
    if printed:
        args.remove('--stdout')
    proc = subprocess.run([str(script)] + args, text=True, capture_output=True, env=full)
    assert (proc.returncode == 0) == ok, (args, proc.returncode, proc.stderr)
    if printed and proc.returncode == 0:
        out = Path(args[args.index('--out') + 1])
        day = args[args.index('--date') + 1] if '--date' in args else None
        proc.stdout = (out / 'daily' / (day + '.json' if day else 'today.json')).read_text()
    return proc


def make_home(root, ledger=True):
    home = root / 'home'
    for sub in ('state', 'config', 'data'):
        (home / sub).mkdir(parents=True)
    (home / '.env').write_text('API_TOKEN=%s\n' % SECRET)
    (home / 'config/daily-summary').write_text(
        'box=pel-dev-test\ndeveloper=Test Dev\nworking_hours=08:30-17:30 Mon-Fri\n')
    rows = [
        {'v': 1, 'ts': lo + 9 * H, 'event': 'task.dispatched', 'task': 'fix-a', 'kind': 'ship',
         'project': 'wms', 'harness': 'claude', 'model': None},
        {'v': 1, 'ts': lo + 9 * H + 600, 'event': 'task.status', 'task': 'fix-a', 'state': 'working',
         'key': None, 'text': ' setup done'},
        {'v': 1, 'ts': lo + 10 * H, 'event': 'task.status', 'task': 'fix-a', 'state': 'blocked',
         'key': 'q', 'text': ' Codex usage exhausted until tomorrow ' + SECRET},
        {'v': 1, 'ts': lo + 12 * H, 'event': 'task.status', 'task': 'fix-a', 'state': 'resolved',
         'key': 'q', 'text': ' quota back'},
        {'v': 1, 'ts': lo + 14 * H, 'event': 'task.status', 'task': 'fix-a', 'state': 'done',
         'key': None, 'text': ' PR https://github.com/x/y/pull/1 checks green'},
        {'v': 1, 'ts': lo + 14 * H + 60, 'event': 'task.pr_ready', 'task': 'fix-a',
         'pr': 'https://github.com/x/y/pull/1'},
        {'v': 1, 'ts': lo + 15 * H, 'event': 'task.merged', 'task': 'fix-a', 'via': 'pr',
         'pr': 'https://github.com/x/y/pull/1'},
        {'v': 1, 'ts': lo + 15 * H + 60, 'event': 'task.cleaned_up', 'task': 'fix-a'},
        {'v': 1, 'ts': lo + 11 * H, 'event': 'task.dispatched', 'task': 'scout-b', 'kind': 'scout',
         'project': 'wms', 'harness': 'codex', 'model': 'gpt-5'},
        {'v': 1, 'ts': lo - 2 * H, 'event': 'task.dispatched', 'task': 'old-c', 'kind': 'ship',
         'project': 'wms', 'harness': 'claude', 'model': None},
        {'v': 1, 'ts': lo + 1 * H - 60, 'event': 'task.status', 'task': 'old-c', 'state': 'failed',
         'key': None, 'text': ' gave up'},
        {'v': 1, 'ts': lo + 1 * H, 'event': 'task.cleaned_up', 'task': 'old-c'},
    ]
    if ledger:
        jsonl(home / 'state/fleet-ledger.jsonl', rows)
    (home / 'state/scout-b.meta').write_text(
        'window=firstmate:fm-scout-b\nendpoint_task_id=scout-b\nkind=scout\nharness=codex\nmodel=gpt-5\n')
    (home / 'state/scout-b.status').write_text(
        'working [at=%d]: setup done %s\n'
        'needs-decision [at=%d] [key=d1]: pick a design for /private/path\n'
        'continuation prose without a verb\n' % (lo + 11 * H + 100, SECRET, lo + 16 * H))
    samples = []
    for t in range(lo, lo + 24 * H, 300):
        if lo + 5 * H <= t < lo + 5 * H + 1800:
            continue
        resident = ['scout-b'] if t >= lo + 11 * H else []
        if t < lo + 1 * H:
            resident.append('old-c')
        if lo + 9 * H <= t < lo + 15 * H:
            resident.append('fix-a')
        if not ledger and t >= lo + 8 * H:
            resident.append('fix-d')
        samples.append({'v': 1, 'ts': t, 'resident': resident, 'supervisor_up': True, 'beat_age_s': 10})
    out = root / 'out'
    jsonl(out / 'samples.jsonl', samples)
    obs = [{'v': 1, 'ts': lo + 15 * H + 300 * i, 'event': 'no_ticket', 'free_slots': 1,
            'reason': 'all_blocked', 'detail': {'assigned_open': 4, 'blocked': 3}} for i in range(18)]
    obs.append({'v': 1, 'ts': lo + 16 * H + 1800, 'event': 'ticket_found'})
    jsonl(home / 'state/no-ticket.jsonl', obs)
    return home, out


def fake_journalctl(bindir, boots):
    bindir.mkdir(parents=True, exist_ok=True)
    lines = []
    for index, (first, last) in enumerate(boots):
        fmt = lambda ts: dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')
        lines.append('%3d %032x %s—%s' % (index - len(boots) + 1, index + 1, fmt(first), fmt(last)))
    body = '\n'.join(lines)
    path = bindir / 'journalctl'
    path.write_text('#!/usr/bin/env bash\ncase "$*" in *--list-boots*) ;; *) exit 1 ;; esac\ncat <<\'EOF\'\n%s\nEOF\n' % body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


with tempfile.TemporaryDirectory(prefix='fm-daily-summary-test-') as tmp:
    root = Path(tmp)
    home, out = make_home(root)
    fakebin = root / 'fakebin'
    fake_journalctl(fakebin, [(lo - 30 * H, lo + 3 * H), (lo + 3 * H + 1800, lo + 20 * H)])
    env = {'PATH': str(fakebin) + os.pathsep + os.environ['PATH']}
    now = '2026-10-14T01:00:00+11:00'

    # --- a finished day, printed ---------------------------------------------
    proc = run(['generate', '--home', str(home), '--out', str(out), '--date', '2026-10-13', '--now', now, '--stdout'], env)
    text = proc.stdout
    assert SECRET not in text, 'secret from a status line leaked into the summary'
    assert '/private/path' not in text and 'pick a design' not in text, 'raw status text copied'
    s = json.loads(text)
    assert s['schema'] == 'datapel-agent-daily.v1' and s['partial'] is False
    assert s['box'] == 'pel-dev-test' and s['developer'] == 'Test Dev'
    assert s['window'] == {'start': '2026-10-13T00:00:00+11:00', 'end': '2026-10-14T00:00:00+11:00'}
    assert s['generated_at'] == '2026-10-13T14:00:00Z'
    cap = s['capacity']
    # fix-a 6h + scout-b 13h + old-c 1h + sampled supervisor time outside host downtime
    assert cap['agent_hours'] == 43.17, cap['agent_hours']
    assert cap['agents_dispatched'] == 2 and cap['dispatched_by_kind'] == {'scout': 1, 'ship': 1}
    assert cap['harnesses'] == {'claude': 1, 'codex': 1}
    assert cap['working_hours'] == {'start': '08:30', 'end': '17:30', 'days': 'Mon-Fri'}
    # observations 15:00-16:25 (+ cadence), ticket found 16:30, minus the open decision from 16:00
    assert cap['no_ticket_hours'] == 1.0, cap
    assert cap['no_ticket_stretches'] == [{
        'start': '2026-10-13T15:00:00+11:00', 'end': '2026-10-13T16:00:00+11:00', 'hours': 1.0,
        'free_slots': 1, 'reason': 'all_blocked', 'detail': {'assigned_open': 4, 'blocked': 3}}], cap
    assert s['output'] == {'prs_ready': ['https://github.com/x/y/pull/1'],
                           'prs_merged': ['https://github.com/x/y/pull/1'], 'tasks_done': 1, 'tasks_failed': 1}
    causes = [(i['cause'], i['start'], i['end'], i['hours']) for i in s['lost']['items']]
    assert ('host_down', '2026-10-13T03:00:00+11:00', '2026-10-13T03:30:00+11:00', 0.5) in causes, causes
    assert ('supervisor_down', '2026-10-13T05:10:00+11:00', '2026-10-13T05:30:00+11:00', 0.33) in causes, causes
    assert ('usage_limit', '2026-10-13T10:00:00+11:00', '2026-10-13T12:00:00+11:00', 2.0) in causes, causes
    assert ('waiting_on_human', '2026-10-13T16:00:00+11:00', '2026-10-14T00:00:00+11:00', 8.0) in causes, causes
    usage = [i for i in s['lost']['items'] if i['cause'] == 'usage_limit'][0]
    assert usage['provider'] == 'codex' and usage['task'] == 'fix-a'
    assert s['lost']['hours_total'] == 10.83, s['lost']
    # host up: 00:00-03:00, 03:30-24:00 (current boot extends to the clock)
    assert s['uptime'] == {'host_up_hours': 23.5, 'supervisor_up_hours': 23.17, 'boots': 1}, s['uptime']
    assert s['blocker'] == 'task scout-b has an open decision since 2026-10-13T16:00:00+11:00 (d1)'
    assert s['data_quality']['ledger'] is True and s['data_quality']['sampler_gaps_minutes'] == 20
    assert not any('journalctl' in n for n in s['data_quality']['notes']), s['data_quality']

    # --- the developer's own blocker line wins --------------------------------
    (home / 'data/daily-blocker.txt').write_text('\nDWR-1 waiting on a carton decision\n')
    s = json.loads(run(['generate', '--home', str(home), '--out', str(out), '--date', '2026-10-13', '--now', now, '--stdout'], env).stdout)
    assert s['blocker'] == 'DWR-1 waiting on a carton decision'
    (home / 'data/daily-blocker.txt').unlink()

    # --- the scheduled run: previous day, latest, today, pruning ---------------
    daily = out / 'daily'
    daily.mkdir(parents=True, exist_ok=True)
    (daily / '2026-07-01.json').write_text('{}\n')
    (daily / '2026-10-01.json').write_text('{}\n')
    (daily / 'notes.txt').write_text('keep\n')
    run(['generate', '--home', str(home), '--out', str(out), '--now', now], env)
    names = sorted(p.name for p in daily.iterdir())
    assert names == ['2026-10-01.json', '2026-10-13.json', 'latest.json', 'notes.txt', 'today.json'], names
    final = json.loads((daily / '2026-10-13.json').read_text())
    assert final['partial'] is False and final['date'] == '2026-10-13'
    assert (daily / 'latest.json').read_text() == (daily / '2026-10-13.json').read_text()
    today = json.loads((daily / 'today.json').read_text())
    assert today['partial'] is True and today['date'] == '2026-10-14'
    assert today['window']['start'] == '2026-10-14T00:00:00+11:00'
    # one hour into the day: no worker is credited without a live sample
    assert today['capacity']['agent_hours'] == 0.0, today['capacity']
    assert today['data_quality']['sampler_gaps_minutes'] == 60, today['data_quality']
    assert any('no samples' in n for n in today['data_quality']['notes'])
    assert not [p for p in daily.iterdir() if p.name.startswith('.')], 'temp file left behind'
    assert stat.S_IMODE((daily / 'latest.json').stat().st_mode) == 0o644

    # --today only rewrites today.json; --date on a future day is partial
    (daily / 'today.json').unlink()
    run(['generate', '--home', str(home), '--out', str(out), '--today', '--now', now], env)
    assert (daily / 'today.json').exists() and not (daily / '2026-10-14.json').exists()
    run(['generate', '--home', str(home), '--out', str(out), '--date', '2026-10-14', '--now', now], env)
    assert json.loads((daily / '2026-10-14.json').read_text())['partial'] is True

    # --- environment and config output selection -----------------------------
    env_out = root / 'env-out'
    run(['generate', '--home', str(home), '--today', '--now', now], dict(env, FM_DAILY_SUMMARY_OUT=str(env_out)))
    assert (env_out / 'daily/today.json').exists()
    cfg_out = root / 'cfg-out'
    (home / 'config/daily-summary').write_text('out=%s\n' % cfg_out)
    run(['generate', '--home', str(home), '--today', '--now', now], env)
    assert (cfg_out / 'daily/today.json').exists()
    hostname_box = json.loads((cfg_out / 'daily/today.json').read_text())
    assert hostname_box['box'] and hostname_box['developer'] is None and 'working_hours' not in hostname_box['capacity']
    (home / 'config/daily-summary').write_text('working_hours=whenever\n')
    proc = run(['generate', '--home', str(home), '--out', str(out), '--today', '--now', now], env, ok=False)
    assert proc.returncode == 2 and 'working_hours' in proc.stderr
    proc = run(['generate', '--home', str(home), '--out', str(out), '--now', 'yesterday'], env, ok=False)
    assert proc.returncode == 2
    (home / 'config/daily-summary').write_text('box=pel-dev-test\n')

    # --- the override directories the shell scripts honour ---------------------
    alt = root / 'alt'
    (alt / 'state').mkdir(parents=True)
    (alt / 'state/fleet-ledger.jsonl').write_text(json.dumps(
        {'v': 1, 'ts': lo + 2 * H, 'event': 'task.dispatched', 'task': 'alt-t', 'kind': 'ship',
         'project': 'p', 'harness': 'pi', 'model': None}) + '\n')
    s = json.loads(run(['generate', '--out', str(out), '--date', '2026-10-13', '--now', now, '--stdout'],
                       dict(env, FM_HOME=str(home), FM_STATE_OVERRIDE=str(alt / 'state'))).stdout)
    assert s['capacity']['harnesses'] == {'pi': 1}, s['capacity']

    beat = home / 'state/.last-watcher-beat'
    beat.write_text('')
    beat_ts = lo + 24 * H + 10 * H
    os.utime(beat, (beat_ts, beat_ts))
    (home / 'state/.hidden.meta').write_text('kind=ship\n')
    run(['sample', '--home', str(home), '--out', str(out), '--now', '2026-10-14T10:01:00+11:00'])
    run(['sample', '--home', str(home), '--out', str(out), '--now', '2026-10-14T10:30:00+11:00'])
    rows = [json.loads(l) for l in (out / 'samples.jsonl').read_text().splitlines()]
    assert rows[-2]['resident'] == [] and rows[-2]['beat_age_s'] == 60, rows[-2]
    assert rows[-1]['supervisor_up'] is False and rows[-1]['beat_age_s'] == 1800, rows[-1]
    fresh = root / 'fresh'
    (fresh / 'state').mkdir(parents=True)
    run(['sample', '--home', str(fresh), '--out', str(root / 'fresh-out'), '--now', now],
        {'PATH': '/usr/bin:/bin'})
    row = json.loads((root / 'fresh-out/samples.jsonl').read_text())
    assert row['resident'] == [] and row['supervisor_up'] is False and row['beat_age_s'] is None

    # --- an empty home and a home without the ledger ------------------------------
    unavailable_bin = root / 'nobin'
    unavailable_bin.mkdir()
    (unavailable_bin / 'journalctl').write_text('#!/usr/bin/env bash\nexit 1\n')
    (unavailable_bin / 'journalctl').chmod(0o755)
    s = json.loads(run(['generate', '--home', str(fresh), '--out', str(root / 'fresh-out'), '--date', '2026-10-13',
                        '--now', now, '--stdout'], {'PATH': str(unavailable_bin) + os.pathsep + '/usr/bin:/bin'}).stdout)
    assert s['capacity']['agent_hours'] == 0 and s['capacity']['agents_dispatched'] == 0
    assert s['output'] == {'prs_ready': [], 'prs_merged': [], 'tasks_done': 0, 'tasks_failed': 0}
    assert s['lost'] == {'hours_total': 0, 'items': []} and s['blocker'] is None
    assert s['uptime'] == {'host_up_hours': None, 'supervisor_up_hours': None, 'boots': None}
    assert s['data_quality']['ledger'] is False and s['data_quality']['sampler_gaps_minutes'] == 1440
    notes = ' '.join(s['data_quality']['notes'])
    for expected in ('journalctl', 'no samples', 'fleet ledger off', 'no no-ticket observations', 'no task records'):
        assert expected in notes, (expected, notes)

    home2, out2 = make_home(root / 'two', ledger=False)
    (home2 / 'state/fix-d.meta').write_text('window=firstmate:fm-fix-d\nkind=ship\nharness=claude\nmodel=default\n')
    (home2 / 'state/fix-d.status').write_text(
        'working [at=%d]: setup done\nblocked [at=%d]: claude rate limit hit\n'
        'working [at=%d]: resumed\ndone [at=%d]: PR https://github.com/x/y/pull/9 checks green\n'
        % (lo + 8 * H, lo + 9 * H, lo + 9 * H + 1800, lo + 13 * H))
    (home2 / 'state/fix-d.status').write_text((home2 / 'state/fix-d.status').read_text() + 'working: unstamped line\n')
    s = json.loads(run(['generate', '--home', str(home2), '--out', str(out2), '--date', '2026-10-13', '--now', now, '--stdout'], env).stdout)
    cap = s['capacity']
    assert cap['agents_dispatched'] == 2 and cap['dispatched_by_kind'] == {'scout': 1, 'ship': 1}, cap
    # fix-d 08:00-24:00 (record still present) 16h + scout-b 12.97h + supervisor 23.17h
    assert cap['agent_hours'] == 52.14, cap
    assert s['output']['prs_ready'] == ['https://github.com/x/y/pull/9'] and s['output']['tasks_done'] == 1
    usage = [i for i in s['lost']['items'] if i['cause'] == 'usage_limit']
    assert usage and usage[0]['provider'] == 'claude' and usage[0]['hours'] == 0.5, s['lost']
    assert s['data_quality']['ledger'] is False
    notes = ' '.join(s['data_quality']['notes'])
    assert 'fleet ledger off' in notes and 'without a time stamp' in notes and 'approximated' in notes, notes
    (home2 / 'state/keyed.status').write_text(
        'blocked [at=%d]: [key=a] Codex usage limit [key=b] [at=%d]\n'
        'resolved [at=%d]: [key=other] unrelated\n'
        'resolved [at=%d]: [key=a] recovered\n'
        % (lo + 10 * H, lo + 10 * H + 1800, lo + 11 * H, lo + 12 * H))
    (home2 / 'state/header-keyed.status').write_text(
        'blocked [key=header] [at=%d]: Codex rate limit [key=prose] [at=%d]\n'
        'resolved [key=header] [at=%d]: recovered\n'
        % (lo + 13 * H, lo + 15 * H, lo + 14 * H))
    keyed = json.loads(run(['generate', '--home', str(home2), '--out', str(out2), '--date', '2026-10-13',
                            '--now', now, '--stdout'], env).stdout)
    assert any(i.get('task') == 'keyed' and i['cause'] == 'usage_limit' and i['hours'] == 2.0
               for i in keyed['lost']['items']), keyed['lost']
    assert any(i.get('task') == 'header-keyed' and i['cause'] == 'usage_limit' and i['hours'] == 1.0
               for i in keyed['lost']['items']), keyed['lost']
    (home2 / 'state/held-origin.status').write_text(
        'needs-decision [key=route] [at=%d]: choose route\n'
        'captain-held [key=route] [at=%d]: tracked by route-call\n'
        % (lo + 16 * H, lo + 17 * H))
    (home2 / 'state/parent.status').write_text(
        'resolved [key=captain-hold-route-call-1] [at=%d]: captain hold route-call: answered\n'
        % (lo + 19 * H))
    held = json.loads(run(['generate', '--home', str(home2), '--out', str(out2), '--date', '2026-10-13',
                           '--now', now, '--stdout'], env).stdout)
    assert any(i.get('task') == 'held-origin' and i['cause'] == 'waiting_on_human' and i['hours'] == 3.0
               for i in held['lost']['items']), held['lost']
    (home2 / 'state/held-multi.status').write_text(
        'needs-decision [key=choice] [at=%d]: decide\n'
        'captain-held [key=choice] [at=%d]: tracked by call-a,call-b\n'
        % (lo + 18 * H, lo + 19 * H))
    (home2 / 'state/parent.status').write_text(
        (home2 / 'state/parent.status').read_text() +
        'resolved [key=captain-hold-call-a-1] [at=%d]: captain hold call-a: answered\n'
        % (lo + 20 * H))
    waiting = json.loads(run(['generate', '--home', str(home2), '--out', str(out2), '--date', '2026-10-13',
                              '--now', now, '--stdout'], env).stdout)
    assert any(i.get('task') == 'held-multi' and i['hours'] == 6.0 for i in waiting['lost']['items']), waiting['lost']
    assert waiting['blocker'] and 'held-multi' in waiting['blocker'], waiting['blocker']
    (home2 / 'state/parent.status').write_text(
        (home2 / 'state/parent.status').read_text() +
        'resolved [key=captain-hold-call-b-1] [at=%d]: captain hold call-b: answered\n'
        % (lo + 23 * H))
    answered = json.loads(run(['generate', '--home', str(home2), '--out', str(out2), '--date', '2026-10-13',
                               '--now', now, '--stdout'], env).stdout)
    assert any(i.get('task') == 'held-multi' and i['hours'] == 5.0 for i in answered['lost']['items']), answered['lost']
    (home2 / 'state/reheld.status').write_text(
        'needs-decision [key=first] [at=%d]: first call\n'
        'captain-held [key=first] [at=%d]: tracked by repeat-call\n'
        'needs-decision [key=second] [at=%d]: second call\n'
        'captain-held [key=second] [at=%d]: tracked by repeat-call\n'
        % (lo + 7 * H, lo + 8 * H, lo + 11 * H, lo + 12 * H))
    (home2 / 'state/parent.status').write_text(
        (home2 / 'state/parent.status').read_text() +
        'resolved [key=captain-hold-repeat-call-1] [at=%d]: captain hold repeat-call: answered\n'
        'resolved [key=captain-hold-repeat-call-2] [at=%d]: captain hold repeat-call: answered\n'
        % (lo + 9 * H, lo + 13 * H))
    reheld = json.loads(run(['generate', '--home', str(home2), '--out', str(out2), '--date', '2026-10-13',
                             '--now', now, '--stdout'], env).stdout)
    waits = [i for i in reheld['lost']['items'] if i.get('task') == 'reheld']
    assert [i['hours'] for i in waits] == [2.0, 2.0], waits
    partial_home = root / 'partial'
    (partial_home / 'state').mkdir(parents=True)
    jsonl(partial_home / 'state/no-ticket.jsonl', [
        {'v': 1, 'ts': lo + 24 * H + 9 * H + 50 * 60, 'event': 'no_ticket', 'free_slots': 1,
         'reason': 'empty_queue', 'detail': {'assigned_open': 0}},
        {'v': 1, 'ts': lo + 24 * H + 9 * H + 55 * 60, 'event': 'no_ticket', 'free_slots': 2,
         'reason': 'all_blocked', 'detail': {'blocked': 2}},
    ])
    run(['generate', '--home', str(partial_home), '--out', str(root / 'partial-out'), '--today',
         '--now', '2026-10-14T10:00:00+11:00'], {'PATH': '/usr/bin:/bin'})
    stretches = json.loads((root / 'partial-out/daily/today.json').read_text())['capacity']['no_ticket_stretches']
    assert len(stretches) == 2 and stretches[0]['reason'] == 'empty_queue', stretches
    assert stretches[1]['reason'] == 'all_blocked' and stretches[1]['free_slots'] == 2, stretches
    assert stretches[1]['end'] == '2026-10-14T10:00:00+11:00', stretches
    overnight = root / 'overnight'
    (overnight / 'state').mkdir(parents=True)
    jsonl(overnight / 'state/no-ticket.jsonl', [
        {'v': 1, 'ts': lo + 22 * H, 'event': 'no_ticket', 'free_slots': 1,
         'reason': 'empty_queue', 'detail': {'assigned_open': 0}},
    ])
    jsonl(overnight / 'state/fleet-ledger.jsonl', [
        {'v': 1, 'ts': lo + 32 * H, 'event': 'task.dispatched', 'task': 'morning-ship',
         'kind': 'ship', 'harness': 'codex'},
    ])
    run(['generate', '--home', str(overnight), '--out', str(root / 'overnight-out'), '--today',
         '--now', '2026-10-14T10:00:00+11:00'], {'PATH': '/usr/bin:/bin'})
    morning = json.loads((root / 'overnight-out/daily/today.json').read_text())['capacity']
    assert morning['no_ticket_hours'] == 8.0 and morning['no_ticket_stretches'][0]['end'] == \
        '2026-10-14T08:00:00+11:00', morning
    gap_home = root / 'worker-gap'
    (gap_home / 'state').mkdir(parents=True)
    jsonl(gap_home / 'state/fleet-ledger.jsonl', [
        {'v': 1, 'ts': lo + 9 * H, 'event': 'task.dispatched', 'task': 'gap-worker',
         'kind': 'ship', 'harness': 'codex'},
        {'v': 1, 'ts': lo + 12 * H, 'event': 'task.cleaned_up', 'task': 'gap-worker'},
    ])
    jsonl(root / 'worker-gap-out/samples.jsonl', [
        {'v': 1, 'ts': lo + 9 * H, 'resident': ['gap-worker'], 'supervisor_up': False},
    ])
    run(['generate', '--home', str(gap_home), '--out', str(root / 'worker-gap-out'),
         '--date', '2026-10-13', '--now', now], {'PATH': '/usr/bin:/bin'})
    gap_cap = json.loads((root / 'worker-gap-out/daily/2026-10-13.json').read_text())['capacity']
    assert gap_cap['agent_hours'] == 0.25, gap_cap
    sample_home = root / 'sample-home'
    for sub in ('state', 'data', 'config'):
        (sample_home / sub).mkdir(parents=True)
    fake_tasks = root / 'sample-tools'
    fake_tasks.mkdir()
    fake_bash = fake_tasks / 'bash'
    fake_bash.write_text('''#!/bin/sh
if [ "$1" = -c ] && [ "$3" = endpoint ]; then printf alive; exit 0; fi
if [ "$1" = -c ] && [ "$3" = capacity ] && [ -n "${SUMMARY_CAPACITY_SWAP_FROM:-}" ]; then
  /bin/bash "$@"
  result=$?
  mv "$SUMMARY_CAPACITY_SWAP_FROM" "$SUMMARY_CAPACITY_SWAP_TARGET"
  exit "$result"
fi
exec /bin/bash "$@"
''')
    fake_bash.chmod(0o755)
    tasks_tool = fake_tasks / 'tasks-axi'
    tasks_tool.write_text('''#!/bin/sh
case "$1" in
  ready)
    if [ "${SUMMARY_READY:-0}" = 1 ]; then
      printf 'ready[1]{id,state,kind,repo,title}:\\n  next,queued,ship,alpha,Next\\n'
    else
      printf 'ready[0]{id,state,kind,repo,title}:\\n'
    fi ;;
  list)
    case " $* " in
      *' --state held '*) count=${SUMMARY_HELD:-0}; state=held ;;
      *) count=${SUMMARY_BLOCKED:-0}; state=queued ;;
    esac
    printf 'list[%s]{id,state,kind,repo,title}:\\n' "$count"
    n=1
    while [ "$n" -le "$count" ]; do
      printf '  item-%s,%s,ship,alpha,Item\\n' "$n" "$state"
      n=$((n + 1))
    done ;;
esac
''')
    tasks_tool.chmod(0o755)
    sample_env = {'PATH': str(fake_tasks) + os.pathsep + os.environ['PATH']}
    run(['sample', '--home', str(sample_home), '--out', str(root / 'sample-out'),
         '--now', '2026-10-14T09:00:00+11:00'], sample_env)
    run(['sample', '--home', str(sample_home), '--out', str(root / 'sample-out'),
         '--now', '2026-10-14T09:05:00+11:00'], dict(sample_env, SUMMARY_READY='1'))
    (sample_home / 'config/project-capacity').write_text('alpha 1\nbeta 2\n')
    (sample_home / 'state/alpha-ship.meta').write_text('kind=ship\nproject=/projects/alpha\nwindow=alpha\n')
    (sample_home / 'state/beta-ship.meta').write_text('kind=ship\nproject=/projects/beta\nwindow=beta\n')
    run(['sample', '--home', str(sample_home), '--out', str(root / 'sample-out'),
         '--now', '2026-10-14T09:10:00+11:00'],
        dict(sample_env, SUMMARY_HELD='1', SUMMARY_BLOCKED='2'))
    run(['sample', '--home', str(sample_home), '--out', str(root / 'sample-out'),
         '--now', '2026-10-14T09:15:00+11:00'], {'PATH': '/usr/bin:/bin'})
    (sample_home / 'config/project-capacity').write_text('alpha 01\nbeta 2\n')
    run(['sample', '--home', str(sample_home), '--out', str(root / 'sample-out'),
         '--now', '2026-10-14T09:20:00+11:00'], sample_env)
    (sample_home / 'config/project-capacity').write_text('alpha 1\nbeta 2\n#repo 2\n')
    run(['sample', '--home', str(sample_home), '--out', str(root / 'sample-out'),
         '--now', '2026-10-14T09:25:00+11:00'], sample_env)
    replacement = sample_home / 'config/replacement-capacity'
    replacement.write_text('alpha 1\nbeta 9\n')
    run(['sample', '--home', str(sample_home), '--out', str(root / 'sample-out'),
         '--now', '2026-10-14T09:30:00+11:00'],
        dict(sample_env, SUMMARY_CAPACITY_SWAP_FROM=str(replacement),
             SUMMARY_CAPACITY_SWAP_TARGET=str(sample_home / 'config/project-capacity')))
    automatic = [json.loads(line) for line in (sample_home / 'state/no-ticket.jsonl').read_text().splitlines()]
    assert automatic[0]['event'] == 'no_ticket' and automatic[0]['free_slots'] == 1, automatic
    assert automatic[1]['event'] == 'ticket_found', automatic
    assert automatic[2]['reason'] == 'mixed' and automatic[2]['free_slots'] == 1, automatic
    assert automatic[2]['detail'] == {'assigned_open': 3, 'held': 1, 'blocked': 2}, automatic
    assert automatic[3]['event'] == 'selection_unknown', automatic
    assert automatic[4]['event'] == 'selection_unknown', automatic
    assert automatic[5]['event'] == 'no_ticket' and automatic[5]['free_slots'] == 3, automatic
    assert automatic[6]['event'] == 'no_ticket' and automatic[6]['free_slots'] == 3, automatic
    assert '-h' and 'generate' in run(['--help']).stdout
print('ok - fm-daily-summary')
PY
