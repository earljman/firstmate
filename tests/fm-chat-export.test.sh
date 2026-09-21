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
    assert {s: v['files'] for s,v in manifest['sources'].items()} == dict(claude=1,codex=1,cursor=2,grok=2,pi=1)
    assert manifest['sources']['cursor']['sessions'] == 1
    assert manifest['sources']['cursor']['artifact_files'] == 1
    assert manifest['sources']['grok']['sessions'] == 1
    assert manifest['sources']['claude']['sessions'] == 1
    assert manifest['sources']['claude']['exported_sessions'] == 2
    assert manifest['sources']['claude']['turns'] == 5
    all_rows = [json.loads(l) for l in (out / 'all.jsonl').open()]
    assert [r['timestamp'] for r in all_rows] == sorted(r['timestamp'] for r in all_rows)
    assert any(r['timestamp'] == '2026-01-02T10:00:00.000000Z' for r in all_rows)
    assert all(set(r) == {'source','session_id','project','timestamp','role','content','tool_name','tool_input','tool_output','raw_type'} for r in all_rows)
    rows = [json.loads(l) for l in (out / 'claude.jsonl').open()]
    assert [r['content'].get('uuid') for r in rows if r['session_id']=='tree' and r['content'].get('uuid')] == ['a','b','c']
    assert next(r for r in rows if r['content'].get('uuid')=='b')['role'] == 'tool'
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
    # A corrupt source cannot replace any existing output.
    bad = roots['pi'] / 'bad.jsonl'
    bad.write_text('{invalid\n')
    run(success=False)
    assert outputs == {p.name:p.read_bytes() for p in out.glob('*') if p.is_file()}
    bad.unlink()
    missing = run(['--source','pi','--root','pi=' + str(root / 'missing'),'--dry-run'])
    assert json.loads(missing.stdout)['sources']['pi']['sessions'] == 0
    # Refuse publishing within source logs.
    run(['--output',str(roots['pi'] / 'export')], success=False)
print('PASS: five formats, full content, tree ordering, secrets, dry-run, atomic failures and idempotence')
PY
