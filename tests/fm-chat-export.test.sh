#!/usr/bin/env bash
# Exercise all five export formats, branching, secret scrubbing, order and safety.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='fm-chat-export-test-') as tmp:
    root = Path(tmp)
    home = root / 'home'
    home.mkdir()
    (home / '.env').write_text('CUSTOM_API_KEY=uniqueLiteral987654\nMULTI_SECRET="firstSecretLine\nsecondSecretLine"\nAUTH_PATH=/tmp/long-auth-config-path\nACCESS_TOKEN_TTL=12345678901234\nLOG_LEVEL=INFO\nSECRET_STORE_AWS_PREFIX=projects/secret-store/config\nFLAG=1\n')
    roots = {s: root / s for s in ('claude', 'codex', 'cursor', 'grok', 'pi')}
    def write(source, name, rows):
        path = roots[source] / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps(r) + '\n' for r in rows))
    ts = '2026-01-02T12:00:00+02:00'
    write('claude', 'tree.jsonl', [
        {'type':'assistant','uuid':'c','parentUuid':'b','sessionId':'tree','timestamp':ts,'message':{'role':'assistant','content':[{'type':'tool_use','name':'Read','input':{'path':'/client/file'}}]}},
        {'type':'user','uuid':'a','parentUuid':None,'sessionId':'tree','timestamp':ts,'message':{'role':'user','content':'keep person@example.com TICKET-42 /client/file uniqueLiteral987654'}},
        {'type':'assistant','uuid':'old','parentUuid':'a','sessionId':'tree','timestamp':ts,'message':{'role':'assistant','content':'alternative retained'}},
        {'type':'user','uuid':'b','parentUuid':'a','sessionId':'tree','timestamp':ts,'message':{'role':'user','content':[{'type':'tool_result','content':'file contents sk-abcdefghijklm1234567890'}]}},
        {'type':'last-prompt','leafUuid':'c','sessionId':'tree'},
    ])
    write('claude', 'duplicate.jsonl', [
        {'type':'user','uuid':'root','parentUuid':None,'sessionId':'duplicate','timestamp':ts,'message':{'role':'user','content':'duplicate session root'}},
        {'type':'assistant','uuid':'reply','parentUuid':'root','sessionId':'duplicate','timestamp':ts,'message':{'role':'assistant','content':'superseded first reply'}},
        {'type':'assistant','uuid':'reply','parentUuid':'root','sessionId':'duplicate','timestamp':ts,'message':{'role':'assistant','content':'superseded second reply'}},
        {'type':'assistant','uuid':'reply','parentUuid':'root','sessionId':'duplicate','timestamp':ts,'message':{'role':'assistant','content':'latest reply wins'}},
        {'type':'last-prompt','leafUuid':'reply','sessionId':'duplicate'},
    ])
    write('codex', 'codex.jsonl', [
        {'type':'session_meta','timestamp':ts,'payload':{'id':'cx','cwd':str(home)}},
        {'type':'response_item','timestamp':ts,'payload':{'type':'function_call','name':'read','arguments':'{"path":"/client/file"}'}},
        {'type':'response_item','timestamp':ts,'payload':{'type':'function_call_output','output':'full file\nJIRA_API_TOKEN=abc123secret\nAWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP\nBearer abc.def123'}},
        {'type':'future_event','timestamp':ts,'payload':{'escaped':r'line\nBearer nestedFixtureToken123\nJIRA_API_TOKEN=nestedFixturePassword123\nsk-fixtureNested123456', 'custom':'retain me; key: ordinary_field; projects/secret-store/config; <X key={item.id}>; /tmp/long-auth-config-path; 12345678901234; INFO; firstSecretLine\nsecondSecretLine'}},
    ])
    write('cursor', 'project/agent-transcripts/cu/cu.jsonl', [
        {'role':'user','message':{'content':[{'type':'text','text':'question'}]}},
        {'role':'assistant','message':{'content':[{'type':'tool_use','name':'Read','input':{'password':'hunter-secret','path':'/client/file'}},{'type':'tool_result','content':'all file contents ghp_abcdefghijklmnop'}]}},
    ])
    write('grok', 'project/gr/chat_history.jsonl', [
        {'type':'user','content':'hello'},
        {'type':'assistant','content':'answer','tool_calls':[{'function':{'name':'read_file','arguments':'{"path":"/client/file"}'}}]},
        {'type':'tool_result','content':'xoxb-123456-abcdef full result'},
    ])
    write('grok', 'project/gr/updates.jsonl', [
        {'timestamp':ts,'params':{'sessionId':'gr','update':{'sessionUpdate':'tool_call_update','title':'read_file','content':[{'type':'text','text':'file remains'}]}}},
    ])
    write('pi', 'pi.jsonl', [
        {'type':'session','id':'pi','timestamp':ts,'cwd':str(home)},
        {'type':'message','id':'a','timestamp':ts,'message':{'role':'assistant','content':[{'type':'toolCall','name':'read','arguments':{'path':'/client/file'}}]}},
        {'type':'message','id':'b','parentId':'a','timestamp':ts,'message':{'role':'toolResult','toolName':'read','content':[{'type':'text','text':'-----BEGIN PRIVATE KEY-----\nabcdef\n-----END PRIVATE KEY-----\nfull file'}]}},
    ])
    artifact = roots['cursor'] / 'project/agent-tools/result.txt'
    artifact.parent.mkdir(parents=True)
    artifact.write_text('persisted file contents\n' + 'line of content\n' * 5000 + '-----BEGIN PRIVATE KEY-----\nsecretmaterial\n-----END PRIVATE KEY-----\n')
    paths = list(root.rglob('*.jsonl')) + [artifact]
    before = {p:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    out = root / 'out'
    command = [str(repo / 'bin/fm-chat-export.sh'), '--home', str(home), '--output', str(out)]
    for source, path in roots.items():
        command += ['--root', source + '=' + str(path)]
    def run(extra=(), success=True):
        p = subprocess.run(command + list(extra), text=True, capture_output=True)
        assert (p.returncode == 0) == success, p.stderr
        return p
    dry = run(['--dry-run'])
    assert not out.exists()
    result = run()
    assert 'Unknown event retained: codex/future_event' in result.stderr
    manifest = json.loads((out / 'manifest.json').read_text())
    assert {s: v['files'] for s,v in manifest['sources'].items()} == dict(claude=2,codex=1,cursor=2,grok=2,pi=1)
    assert manifest['sources']['cursor']['sessions'] == 1
    assert manifest['sources']['cursor']['artifact_files'] == 1
    assert manifest['sources']['grok']['sessions'] == 1
    assert manifest['sources']['claude']['sessions'] == 2
    assert manifest['sources']['claude']['exported_sessions'] == 3
    assert manifest['sources']['claude']['turns'] == 8
    assert manifest['sources']['claude']['duplicate_uuids'] == 2
    assert manifest['sources']['claude']['duplicate_uuids_by_session'] == {str(roots['claude'] / 'duplicate.jsonl'): 2}
    assert all(v['skipped_sessions'] == 0 for v in manifest['sources'].values())
    all_rows = [json.loads(l) for l in (out / 'all.jsonl').open()]
    assert [r['timestamp'] for r in all_rows] == sorted(r['timestamp'] for r in all_rows)
    assert any(r['timestamp'] == '2026-01-02T10:00:00.000000Z' for r in all_rows)
    assert all(set(r) == {'source','session_id','project','timestamp','role','content','tool_name','tool_input','tool_output','raw_type'} for r in all_rows)
    rows = [json.loads(l) for l in (out / 'claude.jsonl').open()]
    assert [r['content'].get('uuid') for r in rows if r['session_id']=='tree' and r['content'].get('uuid')] == ['a','b','c']
    assert next(r for r in rows if r['content'].get('uuid')=='b')['role'] == 'tool'
    assert [r['content']['message']['content'] for r in rows if r['content'].get('uuid') == 'reply'] == ['latest reply wins']
    assert all('payload' not in r['content'] for r in all_rows if r['source']=='codex')
    text = (out / 'all.jsonl').read_text()
    for forbidden in ('uniqueLiteral987654','sk-abcdefghijklm1234567890','abc123secret','AKIAABCDEFGHIJKLMNOP','abc.def123','hunter-secret','ghp_abcdefghijklmnop','xoxb-123456-abcdef','BEGIN PRIVATE KEY','secretmaterial','firstSecretLine','secondSecretLine','nestedFixtureToken123','nestedFixturePassword123','sk-fixtureNested123456'):
        assert forbidden not in text, forbidden
    for keep in ('person@example.com','TICKET-42','/client/file','alternative retained','full file','retain me','persisted file contents','key: ordinary_field','<X key={item.id}>','/tmp/long-auth-config-path','12345678901234','INFO','projects/secret-store/config'):
        assert keep in text, keep
    assert '[REDACTED:' in text
    assert manifest['redactions']['env-value'] > 0
    assert manifest['credential_env_names'] == ['CUSTOM_API_KEY', 'MULTI_SECRET']
    outputs = {p.name:p.read_bytes() for p in out.glob('*') if p.is_file()}
    run()
    assert outputs == {p.name:p.read_bytes() for p in out.glob('*') if p.is_file()}
    assert before == {p:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    # A bad file must roll back even records staged before the failure.
    bad = roots['pi'] / 'bad.jsonl'
    bad.write_text(json.dumps({'type':'future_skipped','timestamp':ts,'content':'partial record must disappear'}) + '\n{invalid\n')
    write('claude', 'bad-cycle.jsonl', [
        {'type':'user','uuid':'cycle-a','parentUuid':'cycle-b','sessionId':'bad-cycle','timestamp':ts,'message':{'role':'user','content':'cycle'}},
        {'type':'assistant','uuid':'cycle-b','parentUuid':'cycle-a','sessionId':'bad-cycle','timestamp':ts,'message':{'role':'assistant','content':'cycle'}},
        {'type':'user','uuid':'isolated','parentUuid':None,'sessionId':'bad-cycle','timestamp':ts,'message':{'role':'user','content':'partial tree must disappear'}},
    ])
    cycle = roots['claude'] / 'bad-cycle.jsonl'
    skipped = run()
    assert str(bad) in skipped.stderr and str(cycle) in skipped.stderr
    assert 'Traceback' not in skipped.stderr
    assert 'Unknown event retained: pi/future_skipped' not in skipped.stderr
    skipped_manifest = json.loads(skipped.stdout)
    for source in ('pi','claude'):
        detail = skipped_manifest['sources'][source]
        assert detail['skipped_sessions'] == 1
        assert len(detail['skipped_session_details']) == 1
        assert detail['turns'] == manifest['sources'][source]['turns']
    assert 'line 2' in skipped_manifest['sources']['pi']['skipped_session_details'][0]['error']
    assert 'cyclic' in skipped_manifest['sources']['claude']['skipped_session_details'][0]['error']
    assert skipped_manifest['unknown_events'] == manifest['unknown_events']
    assert all((out/name).read_bytes() == value for name,value in outputs.items() if name.endswith('.jsonl'))
    verbose = run(['--verbose'])
    assert 'Traceback (most recent call last)' in verbose.stderr
    assert str(bad) in verbose.stderr and str(cycle) in verbose.stderr
    assert json.loads(verbose.stdout) == skipped_manifest
    bad.unlink()
    cycle.unlink()
    run()
    assert outputs == {p.name:p.read_bytes() for p in out.glob('*') if p.is_file()}
    # Fatal setup errors still leave the previous publication untouched.
    bad_env = root / 'broken.env'
    bad_env.write_text('AUTH_TOKEN="unterminated\n')
    fatal = run(['--env-file',str(bad_env),'--verbose'], success=False)
    assert str(bad_env) in fatal.stderr and 'Traceback' in fatal.stderr
    assert outputs == {p.name:p.read_bytes() for p in out.glob('*') if p.is_file()}
    missing = run(['--source','pi','--root','pi=' + str(root / 'missing'),'--dry-run'])
    assert json.loads(missing.stdout)['sources']['pi']['sessions'] == 0
    # Refuse publishing within source logs.
    run(['--output',str(roots['pi'] / 'export')], success=False)
print('PASS: five formats, full content, tree ordering, secrets, duplicate UUIDs, isolated skips, tracebacks, dry-run and idempotence')
PY
