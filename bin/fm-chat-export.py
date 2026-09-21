#!/usr/bin/env python3
"""Export local agent session logs using only the Python 3 standard library.

Usage: fm-chat-export.py [--source SOURCE] [--root SOURCE=PATH] [--output DIR]
                        [--home PATH] [--env-file PATH] [--dry-run] [--verbose]

Defaults: ~/.claude/projects, ~/.codex/sessions, ~/.cursor/projects,
~/.grok/sessions, ~/.pi. Missing roots are empty sources.
--home is the Firstmate operational home (default FM_HOME or this repo).
Secrets include credential values from its .env, projects/**/.env, and .env
files beneath Git project roots found in session working directories;
--env-file adds more. Only env names matching secret/token/password/key/
credential/auth/private contribute literals, with values at least 12 characters
and not purely numeric or paths. Contributing names are reported, never values.

Schema keys: source, session_id, project, timestamp, role, content, tool_name,
tool_input, tool_output, raw_type. Roles: user, assistant, tool, system.
Every native record becomes one JSONL turn, including metadata (system role).
content retains the complete native body; Codex's payload is unwrapped.
Tool columns are scalars for one tool or ordered arrays for multiple tools.
Claude's latest leaf is traversed by parentUuid; other branches are retained
as separate session IDs suffixed #branch:<leaf>, without copying shared turns.
Non-tree records remain in native order around the ordered tree records.
Grok chat_history, updates, events, rewinds, hunks and prompt history are kept;
raw_type includes the stream name, so consumers can distinguish replay copies.
Cursor agent-tools/*.txt result artifacts are retained in bounded chunks as
artifact:<id> streams because the files carry no session association.
Cursor records absent from both transcripts and artifacts cannot be reconstructed.
Timestamps missing in native records inherit the previous timestamp, or the
file mtime for an undated stream; the manifest counts these fallbacks.
Source files preserve session order; all.jsonl sorts UTC timestamps stably.
SQLite stages events and sorts on disk; memory is bounded by one event, tree
identifiers, and the literal-secret set, not the size of transcript files.
Output files are individually atomically replaced, with manifest.json last.
Bad session files are skipped atomically, with their paths and reasons reported
in stderr and the manifest; --verbose also prints tracebacks.
Repeated Claude UUIDs keep the latest event and are counted per session file.
Storage and publication failures still abort the run.
Dry-run uses temporary staging only.
Manifest sessions count native sessions; exported_sessions also counts branch
and artifact streams. Redaction totals count occurrences in source exports,
including repeated tool columns, without counting all.jsonl a second time.
"""
import argparse
import collections
import datetime
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import sys
import tempfile
import traceback
from urllib.parse import unquote

SOURCES = ('claude', 'codex', 'cursor', 'grok', 'pi')
DEFAULTS = ('.claude/projects', '.codex/sessions', '.cursor/projects',
            '.grok/sessions', '.pi')
UTC = datetime.timezone.utc
KNOWN = {
    'claude': set('user assistant attachment system last-prompt mode permission-mode '
                  'queue-operation ai-title custom-title agent-name atis-latch '
                  'file-history-snapshot file-history-delta bridge-session pr-link '
                  'history-suppression frame-link artifact-autoreact-ledger '
                  'artifact-comment-monitor relocated progress summary'.split()),
    'codex': set('session_meta event_msg response_item world_state turn_context '
                 'compacted token_usage_record'.split()),
    'cursor': {'message', 'turn_ended', 'tool_output_file'},
    'grok': set('system user assistant reasoning tool_result backend_tool_call '
                'mcp_config_resolved turn_started loop_started phase_changed '
                'mcp_server_starting mcp_server_failed mcp_server_connected '
                'mcp_init_completed first_token tool_started permission_requested '
                'permission_resolved tool_completed turn_ended hook_execution '
                'user_message_chunk agent_thought_chunk agent_message_chunk '
                'tool_call tool_call_update plan turn_completed task_backgrounded '
                'task_completed retry_state prompt_history rewind_points hunk_records'.split()),
    'pi': set('session message model_change thinking_level_change custom_message '
              'compaction branch_summary custom label session_info'.split()),
}
CODEX_INNER = set('message reasoning function_call function_call_output custom_tool_call '
                  'custom_tool_call_output task_started task_complete item_completed '
                  'token_count thread_settings_applied turn_aborted user_message '
                  'agent_message agent_reasoning context_compacted web_search_call '
                  'image_generation_call local_shell_call'.split())
SECRET_KEY = re.compile(r'secret|token|password|passwd|credential|api[_-]?key|private[_-]?key|access[_-]?key', re.I)
ASSIGN_KEY = r'(?=[A-Za-z0-9_.-]*(?:secret|token|password|passwd|key|credential))[A-Za-z_][A-Za-z0-9_.-]*'
TOKEN_START = r'(?:(?<!\w)|(?<=\\n)|(?<=\\r)|(?<=\\t))'
PLACEHOLDER = re.compile(r'\[REDACTED:[a-z-]+\]')


def dump(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def stamp(value):
    if isinstance(value, (float, int)):
        return datetime.datetime.fromtimestamp(value / 1000 if value > 1e11 else value, UTC).isoformat(timespec='microseconds').replace('+00:00', 'Z')
    if isinstance(value, str):
        try:
            d = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
            if d.tzinfo is None:
                d = d.replace(tzinfo=UTC)
            return d.astimezone(UTC).isoformat(timespec='microseconds').replace('+00:00', 'Z')
        except ValueError:
            pass
    return None


def artifact_events(path):
    # Cursor's persisted large tool results have no session association.
    chunk, size, part, private_key = [], 0, 0, False
    with path.open(encoding='utf-8') as stream:
        for line in stream:
            chunk.append(line)
            size += len(line)
            if re.search(r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----', line):
                private_key = True
            if re.search(r'-----END [A-Z0-9 ]*PRIVATE KEY-----', line):
                private_key = False
            if size >= 65536 and not private_key:
                yield part, dict(type='tool_output_file', role='tool', path=str(path), part=part, content=''.join(chunk))
                part += 1
                chunk, size = [], 0
        if chunk:
            yield part, dict(type='tool_output_file', role='tool', path=str(path), part=part, content=''.join(chunk))


def events(path):
    if path.suffix == '.txt':
        yield from artifact_events(path)
        return
    # A bounded snapshot ignores new appends but never reads a file wholesale.
    with path.open('rb') as stream:
        end = os.fstat(stream.fileno()).st_size
        index = 0
        while stream.tell() < end:
            offset = stream.tell()
            line = stream.readline(end - offset)
            index += 1
            if not line.strip():
                continue
            try:
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise ValueError('record is not an object')
            except (ValueError, UnicodeError) as error:
                raise ValueError('invalid JSON record in %s at line %d' % (path, index)) from error
            yield offset, event


def discover(source, root):
    if not root.exists():
        return []
    if source == 'cursor':
        return sorted(list(root.glob('**/agent-transcripts/**/*.jsonl')) + list(root.glob('*/agent-tools/*.txt')))
    return sorted(root.rglob('*.jsonl'))


def project_envs(directory):
    # Working directories can be a whole home; recurse only inside Git projects.
    if not directory.is_dir():
        return
    for current, children, files in os.walk(str(directory)):
        children[:] = [c for c in children if c not in {'.git', 'node_modules', '.venv', 'venv', '__pycache__', '.cache'}]
        if '.env' in files:
            yield Path(current) / '.env'


ENV_NAME = re.compile(r'secret|token|password|key|credential|auth|private', re.I)
CONFIG_NAME = re.compile(r'(?:^|_)(?:TTL|COUNT|LENGTH|MINUTES|SECONDS|TIMEOUT|COOLDOWN|ATTEMPTS|LEVEL|PATH|DIR|DIRECTORY|FILE|ENABLED|PORT|HOST|URL|ENDPOINT|PREFIX|SUFFIX|PROVIDER|REGION|MODE|ALGORITHM|FORMAT|SCOPE|ISSUER|AUDIENCE|METHOD|NAME|TYPE|BACKEND)(?:_|$)', re.I)


def credential_literal(name, value):
    return (bool(ENV_NAME.search(name)) and not CONFIG_NAME.search(name)
            and len(value) >= 12 and not value.isnumeric()
            and not value.startswith(('/', '~/','./','../'))
            and not re.match(r'^[A-Za-z]:[\\/]', value))


def env_values(paths, names=None):
    values = set()
    count = 0
    for path in sorted(paths):
        if not path.is_file():
            continue
        count += 1
        with path.open(encoding='utf-8') as stream:
            lines = iter(stream)
            for line in lines:
                match = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)', line)
                if not match:
                    continue
                name, value = match.group(1), match.group(2).strip()
                variants = set()
                if value.startswith(('"', "'")):
                    quote, tail = value[0], value[1:]
                    pieces, escaped, closed = [], False, False
                    while not closed:
                        for char in tail:
                            if char == quote and not escaped:
                                closed = True
                                break
                            pieces.append(char)
                            escaped = char == chr(92) and not escaped
                        if not closed:
                            pieces.append('\n')
                            try:
                                tail = next(lines).rstrip('\n')
                            except StopIteration as error:
                                raise ValueError('unterminated quoted value in env file %s' % path) from error
                    value = ''.join(pieces)
                    if quote == '"':
                        if value:
                            variants.add(value)
                        replacements = {'n': '\n', 'r': '\r', 't': '\t', '"': '"', chr(92): chr(92)}
                        value = re.sub(r'\\([nrt"\\])', lambda m: replacements[m.group(1)], value)
                else:
                    value = re.split(r'\s+#', value, maxsplit=1)[0].rstrip()
                variants.add(value)
                for variant in variants:
                    if credential_literal(name, variant):
                        values.add(variant)
                        if names is not None:
                            names.add(name)
    return values, count


class Scrubber:
    def __init__(self, literals):
        self.counts = collections.Counter()
        self.literals = re.compile('|'.join(re.escape(v) for v in sorted(literals, key=lambda v: (-len(v), v)))) if literals else None
        self.patterns = [
            ('private-key', re.compile(r'-----BEGIN (?:[A-Z0-9 ]*PRIVATE KEY)-----.*?-----END (?:[A-Z0-9 ]*PRIVATE KEY)-----', re.S)),
            ('api-key', re.compile(TOKEN_START + r'(?:sk-[A-Za-z0-9_-]{8,}|AIza[A-Za-z0-9_-]{20,})')),
            ('github-token', re.compile(TOKEN_START + r'(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)')),
            ('slack-token', re.compile(TOKEN_START + r'xox[baprs]-[A-Za-z0-9-]+')),
            ('aws-key', re.compile(TOKEN_START + r'(?:AKIA|ASIA|AIDA|AROA)[A-Z0-9]{16}\b')),
            ('bearer-token', re.compile(r'(?i)' + TOKEN_START + r'Bearer\s+(?!\[REDACTED:)[A-Za-z0-9._~+/=-]+')),
            ('jwt', re.compile(TOKEN_START + r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+')),
        ]
        self.markers = (('-----BEGIN ',), ('sk-', 'AIza'), ('gh', 'github_pat_'), ('xox',), ('AKIA', 'ASIA', 'AIDA', 'AROA'), ('bearer',), ('eyJ',))
        value_pattern = r'("(?:\\.|[^"\n])*"|\x27[^\x27\n]*\x27|(?:(?!\\[nrt])[^\s,;\}\]\["\x27])+)'
        self.assignment = re.compile(r'(?im)((?:^|(?<=\\n)|(?<=\\r))[ \t]*(?:export[ \t]+)?(?:' + ASSIGN_KEY + r')[ \t]*=[ \t]*)' + value_pattern)
        field_key = r'[A-Za-z_][A-Za-z0-9_.-]*(?:password|passwd|secret|token|credential|api[_-]?key|private[_-]?key|access[_-]?key)|password|passwd|secret|token|credential|api[_-]?key'
        self.inline_assignment = re.compile(r'(?i)(' + TOKEN_START + r'(?:' + field_key + r')[ \t]*=[ \t]*)' + value_pattern)
        self.json_field = re.compile(r'(?i)(["\x27](?:' + field_key + r')["\x27]\s*:\s*)("(?:\\.|[^"\n])*"|\x27[^\x27\n]*\x27)')

    def replacement(self, kind):
        self.counts[kind] += 1
        return '[REDACTED:%s]' % kind

    def text(self, text):
        # Never process placeholders again, including short .env literals.
        parts = PLACEHOLDER.split(text)
        marks = PLACEHOLDER.findall(text)
        result = []
        for i, part in enumerate(parts):
            for (kind, pattern), markers in zip(self.patterns, self.markers):
                haystack = part.lower() if kind == 'bearer-token' else part
                if any(marker in haystack for marker in markers):
                    part = pattern.sub(lambda m, k=kind: self.replacement(k), part)
            for pattern in (self.json_field, self.assignment, self.inline_assignment):
                def hide(match):
                    value = match.group(2)
                    field = re.search(r'[A-Za-z_][A-Za-z0-9_.-]*', match.group(1)).group(0)
                    if field.lower() == 'export':
                        field = match.group(1).split()[1].split('=')[0]
                    if CONFIG_NAME.search(field) or PLACEHOLDER.fullmatch(value.strip(chr(34) + chr(39))):
                        return match.group(0)
                    quoted = value[0] in ('"', "'")
                    return match.group(1) + (value[0] if quoted else '') + self.replacement('credential') + (value[-1] if quoted else '')
                part = pattern.sub(hide, part)
            if self.literals:
                chunks = PLACEHOLDER.split(part)
                placeholders = PLACEHOLDER.findall(part)
                part = ''.join(self.literals.sub(lambda m: self.replacement('env-value'), chunk) + (placeholders[j] if j < len(placeholders) else '') for j, chunk in enumerate(chunks))
            result.append(part)
            if i < len(marks):
                result.append(marks[i])
        return ''.join(result)

    def scrub(self, value):
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, list):
            return [self.scrub(v) for v in value]
        if isinstance(value, dict):
            result = {}
            for key, item in value.items():
                # Typed token counts and token identifiers are not credentials.
                secret = SECRET_KEY.search(key) and not CONFIG_NAME.search(key) and isinstance(item, str) and item and not key.endswith(('_id', '_type'))
                result[self.text(key)] = self.replacement('credential') if secret and not PLACEHOLDER.fullmatch(item) else self.scrub(item)
            return result
        return value


def tools_in(body):
    names, inputs, outputs = [], [], []
    blocks = body.get('content', [])
    if isinstance(blocks, list):
        for block in blocks:
            if not isinstance(block, dict):
                continue
            kind = block.get('type')
            if kind in ('tool_use', 'toolCall'):
                names.append(block.get('name'))
                inputs.append(block.get('input', block.get('arguments')))
            elif kind in ('tool_result', 'toolResult'):
                outputs.append(block.get('content'))
    for call in body.get('tool_calls', []) or []:
        call = call.get('function', call)
        names.append(call.get('name'))
        inputs.append(call.get('arguments', call.get('input')))
    kind = body.get('sessionUpdate', body.get('type', ''))
    if kind in ('function_call', 'custom_tool_call', 'tool_call'):
        names.append(body.get('name', body.get('title')))
        inputs.append(body.get('arguments', body.get('input', body.get('rawInput'))))
    if kind in ('function_call_output', 'custom_tool_call_output', 'tool_call_update', 'tool_result', 'tool_output_file') or body.get('role') == 'toolResult':
        outputs.append(body.get('output', body.get('content')))
    if body.get('toolName') or body.get('tool_name'):
        names.append(body.get('toolName', body.get('tool_name')))
    def packed(items):
        return (items[0] if len(items) == 1 else items) if items else None
    return packed(names), packed(inputs), packed(outputs)


def claude_order(path, db, stats):
    db.execute('CREATE TEMP TABLE IF NOT EXISTS tree (id TEXT PRIMARY KEY, parent TEXT, off INTEGER)')
    db.execute('DELETE FROM tree')
    loose = []
    latest = None
    selected = None
    uuid_events = 0
    for off, e in events(path):
        if e.get('uuid'):
            if not isinstance(e['uuid'], str) or (e.get('parentUuid') is not None and not isinstance(e['parentUuid'], str)):
                raise ValueError('Claude uuid and parentUuid must be strings')
            uuid_events += 1
            db.execute('INSERT OR REPLACE INTO tree VALUES (?,?,?)', (e['uuid'], e.get('parentUuid'), off))
            latest = e['uuid']
        else:
            loose.append(off)
        if e.get('leafUuid'):
            selected = e['leafUuid']
    stats['duplicate_uuids'] = uuid_events - db.execute('SELECT count(*) FROM tree').fetchone()[0]
    # A last-prompt leaf often denotes the last user prompt, preceding its reply.
    def ancestors(leaf):
        seen = set()
        while leaf:
            if leaf in seen:
                raise ValueError('cycle in Claude session %s' % path)
            seen.add(leaf)
            row = db.execute('SELECT parent,off FROM tree WHERE id=?', (leaf,)).fetchone()
            if not row:
                break
            yield leaf, row[1]
            leaf = row[0]
    last_path = list(ancestors(latest))
    if selected is None or selected in {x[0] for x in last_path}:
        selected = latest
    primary = list(ancestors(selected))
    if not primary:
        primary = last_path
    used = set()
    # Preserve branch-only turns as additional sessions rather than dropping them.
    leaves = [row[0] for row in db.execute('SELECT id FROM tree WHERE id NOT IN (SELECT parent FROM tree WHERE parent IS NOT NULL) ORDER BY off')]
    paths = [(None, primary)] + [(leaf, list(ancestors(leaf))) for leaf in leaves if leaf != selected]
    for suffix, chain in paths:
        ordered = [(ident, off) for ident, off in reversed(chain) if ident not in used]
        used.update(ident for ident, _ in ordered)
        offsets = [off for _, off in ordered]
        if suffix is None:
            # Metadata has no parent relation; keep its original position.
            pending = iter(loose)
            current = next(pending, None)
            merged = []
            for off in offsets:
                while current is not None and current < off:
                    merged.append(current)
                    current = next(pending, None)
                merged.append(off)
            if current is not None:
                merged.append(current)
            merged.extend(pending)
            offsets = merged
        if offsets:
            yield suffix, offsets
    if len(used) != db.execute('SELECT count(*) FROM tree').fetchone()[0]:
        raise ValueError('unreachable or cyclic Claude tree records in %s' % path)


def ingest_file(db, source, path, stats, projects, unknown):
    fallback = stamp(path.stat().st_mtime)
    project = str(path.parent)
    session = path.stem
    stream_name = path.stem
    if source == 'grok':
        session = path.parent.name if path.name != 'prompt_history.jsonl' else 'prompt-history:' + path.parent.name
        project = unquote(path.parent.parent.name if path.name != 'prompt_history.jsonl' else path.parent.name)
    if source == 'grok' and Path(project).is_absolute():
        projects.add(project)
    if source == 'cursor':
        project = re.split(r'/(?:agent-transcripts|agent-tools)/', str(path))[0].rsplit('/', 1)[-1]
        if path.suffix == '.txt':
            session = 'artifact:' + path.stem
            stats['artifact_files'] = stats.get('artifact_files', 0) + 1
    call_names = {}
    branches = claude_order(path, db, stats) if source == 'claude' else [(None, None)]
    with path.open('rb') as reader:
        for branch, offsets in branches:
            previous = None
            def ordered():
                if offsets is None:
                    for _, item in events(path):
                        yield item
                else:
                    for off in offsets:
                        reader.seek(off)
                        yield json.loads(reader.readline())
            for e in ordered():
                outer = e.get('type', 'message')
                body = e
                if source == 'codex':
                    body = e.get('payload', e)
                elif source in ('claude', 'cursor', 'pi'):
                    body = e.get('message', e)
                elif source == 'grok' and 'params' in e:
                    body = e['params'].get('update', e['params'])
                if not isinstance(body, dict):
                    body = {'content': body}
                kind = body.get('sessionUpdate', body.get('type', outer))
                if source == 'grok' and 'type' not in e and 'params' not in e:
                    kind = stream_name
                unknown_kind = kind if source == 'grok' else outer
                if unknown_kind not in KNOWN[source] or (source == 'codex' and outer in ('event_msg', 'response_item') and kind not in CODEX_INNER):
                    key = (source, outer, kind)
                    unknown[key] += 1
                cwd = e.get('cwd', body.get('cwd'))
                if isinstance(cwd, str):
                    project = cwd
                    projects.add(cwd)
                if source == 'claude':
                    session = e.get('sessionId', session)
                elif source == 'codex' and outer == 'session_meta':
                    session = body.get('id', body.get('session_id', session))
                elif source == 'pi' and outer == 'session':
                    session = e.get('id', session)
                elif source == 'grok':
                    session = e.get('session_id', e.get('sessionId', e.get('params', {}).get('sessionId', session)))
                when = stamp(e.get('timestamp', e.get('ts', e.get('created_at', body.get('timestamp')))))
                if when is None:
                    stats['inferred_timestamps'] += 1
                when = when or previous or fallback
                previous = when
                role = body.get('role', e.get('role', outer))
                if role in ('toolResult', 'tool_result') or kind in ('function_call_output', 'custom_tool_call_output', 'tool_call_update', 'tool_result'):
                    role = 'tool'
                elif kind in ('reasoning', 'function_call', 'custom_tool_call', 'tool_call', 'agent_thought_chunk', 'agent_message_chunk'):
                    role = 'assistant'
                elif kind in ('user_message_chunk', 'prompt_history'):
                    role = 'user'
                if role not in ('user', 'assistant', 'tool', 'system'):
                    role = 'system'
                tool_name, tool_input, tool_output = tools_in(body)
                call_id = body.get('call_id', body.get('tool_call_id', body.get('toolCallId')))
                if call_id and tool_name:
                    call_names[call_id] = tool_name
                if call_id and tool_name is None:
                    tool_name = call_names.get(call_id)
                if source == 'claude' and tool_output is not None and tool_input is None:
                    role = 'tool'
                # Retain wrapper-only fields too, without leaving Codex wrapped.
                content = body if source == 'codex' else e
                raw_type = outer + (':' + kind if kind != outer else '')
                if source == 'grok':
                    raw_type = stream_name + ':' + kind
                sid = str(session)
                if source == 'claude' and 'subagents' in path.parts:
                    sid += '#agent:' + path.stem
                sid += '#branch:' + branch if branch else ''
                row = dict(source=source, session_id=sid, project=project,
                           timestamp=when, role=role, content=content,
                           tool_name=tool_name, tool_input=tool_input,
                           tool_output=tool_output, raw_type=raw_type)
                db.execute('INSERT INTO turns(source,session,stamp,body) VALUES (?,?,?,?)', (source, sid, when, dump(row)))
                stats['turns'] += 1


def ingest(db, source, paths, stats, projects, unknown, verbose=False):
    for path in paths:
        file_stats = dict(turns=0, inferred_timestamps=0, duplicate_uuids=0)
        file_projects, file_unknown = set(), collections.Counter()
        db.execute('SAVEPOINT session_file')
        try:
            ingest_file(db, source, path, file_stats, file_projects, file_unknown)
        except (OSError, ValueError, TypeError, KeyError, AttributeError,
                OverflowError, sqlite3.IntegrityError) as error:
            db.execute('ROLLBACK TO SAVEPOINT session_file')
            db.execute('RELEASE SAVEPOINT session_file')
            reason = '%s: %s' % (type(error).__name__, error)
            print('Skipped session %s: %s' % (path, reason), file=sys.stderr)
            if verbose:
                traceback.print_exc()
            stats['skipped_sessions'] += 1
            stats['skipped_session_details'].append(dict(file=str(path), error=reason))
        else:
            db.execute('RELEASE SAVEPOINT session_file')
            for key in ('turns', 'inferred_timestamps', 'artifact_files'):
                if key in file_stats:
                    stats[key] = stats.get(key, 0) + file_stats[key]
            stats['files'] += 1
            projects.update(file_projects)
            for key in file_unknown:
                if key not in unknown:
                    print('Unknown event retained: %s/%s/%s' % key, file=sys.stderr)
            unknown.update(file_unknown)
        if file_stats['duplicate_uuids']:
            stats['duplicate_uuids'] += file_stats['duplicate_uuids']
            stats['duplicate_uuids_by_session'][str(path)] = file_stats['duplicate_uuids']
        db.commit()
    stats['exported_sessions'] = db.execute('SELECT count(DISTINCT session) FROM turns WHERE source=?', (source,)).fetchone()[0]
    stats['sessions'] = db.execute("SELECT count(DISTINCT CASE WHEN instr(session,'#branch:')>0 THEN substr(session,1,instr(session,'#branch:')-1) ELSE session END) FROM turns WHERE source=? AND session NOT LIKE 'artifact:%'", (source,)).fetchone()[0]
    dates = db.execute('SELECT min(stamp),max(stamp) FROM turns WHERE source=?', (source,)).fetchone()
    stats['date_range'] = {'start': dates[0], 'end': dates[1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--source', choices=SOURCES, action='append', help='repeat to select multiple sources')
    parser.add_argument('--root', action='append', default=[], metavar='SOURCE=PATH')
    parser.add_argument('--output', type=Path, default=Path.home() / 'Documents/llm-chat-export' / socket.gethostname())
    parser.add_argument('--home', type=Path, default=Path(os.environ.get('FM_HOME', Path(__file__).resolve().parent.parent)))
    parser.add_argument('--env-file', type=Path, action='append', default=[])
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--verbose', action='store_true', help='print tracebacks for skipped sessions and fatal errors')
    args = parser.parse_args()
    roots = {s: Path.home() / p for s, p in zip(SOURCES, DEFAULTS)}
    for override in args.root:
        source, sep, path = override.partition('=')
        if not sep or source not in SOURCES or not path:
            parser.error('--root requires SOURCE=PATH')
        roots[source] = Path(path).expanduser()
    selected = [s for s in SOURCES if not args.source or s in args.source]
    out = args.output.expanduser().resolve()
    for root in roots.values():
        if out == root.resolve() or root.resolve() in out.parents:
            parser.error('output cannot be inside a source directory')
    old_umask = os.umask(0o077)
    try:
        with tempfile.TemporaryDirectory(prefix='fm-chat-export-') as temporary:
            db = sqlite3.connect(str(Path(temporary) / 'stage.sqlite'))
            db.execute('PRAGMA temp_store=FILE')
            db.execute('PRAGMA cache_size=-8192')
            db.execute('CREATE TABLE turns (seq INTEGER PRIMARY KEY, source TEXT, session TEXT, stamp TEXT, body TEXT)')
            stats = {}
            projects, unknown = set(), collections.Counter()
            for source in selected:
                stats[source] = dict(files=0, sessions=0, turns=0, inferred_timestamps=0,
                                     duplicate_uuids=0, duplicate_uuids_by_session={},
                                     skipped_sessions=0, skipped_session_details=[])
                paths = discover(source, roots[source])
                print('%s: reading %d files' % (source, len(paths)), file=sys.stderr)
                ingest(db, source, paths, stats[source], projects, unknown, args.verbose)
            envs = {p.expanduser().resolve() for p in args.env_file}
            envs.add(args.home.expanduser().resolve() / '.env')
            project_root = args.home.expanduser() / 'projects'
            envs.update(project_envs(project_root))
            scanned_projects = set()
            for project in sorted(projects):
                directory = Path(project)
                if directory.is_absolute():
                    for parent in (directory, *directory.parents):
                        envs.add(parent / '.env')
                        if (parent / '.git').exists():
                            if parent not in scanned_projects:
                                envs.update(project_envs(parent))
                                scanned_projects.add(parent)
                            break
            env_names = set()
            values, env_count = env_values(envs, env_names)
            print('Credential env names: ' + ', '.join(sorted(env_names)), file=sys.stderr)
            scrubber = Scrubber(values)
            print('Scrubbing %d literal values from %d env files' % (len(values), env_count), file=sys.stderr)
            for seq, encoded in db.execute('SELECT seq,body FROM turns ORDER BY seq'):
                row = json.loads(encoded)
                # Preserve schema keys and enums; scrub every user-controlled value.
                for key in ('session_id', 'project', 'content', 'tool_name', 'tool_input', 'tool_output', 'raw_type'):
                    row[key] = scrubber.scrub(row[key])
                db.execute('UPDATE turns SET body=? WHERE seq=?', (dump(row), seq))
                if seq % 50000 == 0:
                    print('Scrubbed %d turns' % seq, file=sys.stderr)
            db.commit()
            dates = db.execute('SELECT min(stamp),max(stamp) FROM turns').fetchone()
            manifest = dict(schema_version=1, hostname=socket.gethostname(), sources=stats,
                            date_range=dict(start=dates[0], end=dates[1]),
                            redactions=dict(sorted(scrubber.counts.items())), env_files=env_count,
                            credential_env_names=sorted(env_names),
                            unknown_events=[dict(source=k[0], raw_type=k[1], inner_type=k[2], count=v) for k, v in sorted(unknown.items())],
                            notes=['Counts include metadata and replay streams; no cross-stream deduplication.',
                                   'Claude branch-only turns use #branch:<leaf> session IDs.',
                                   'Missing timestamps use prior timestamp or source file mtime.',
                                   'Cursor includes transcript records and unassociated agent-tools result artifacts.'])
            if not args.dry_run:
                out.mkdir(parents=True, exist_ok=True)
                with tempfile.TemporaryDirectory(prefix='.staging-', dir=str(out)) as stage:
                    stage = Path(stage)
                    for source in SOURCES:
                        with (stage / (source + '.jsonl')).open('w', encoding='utf-8') as stream:
                            for (body,) in db.execute('SELECT body FROM turns WHERE source=? ORDER BY seq', (source,)):
                                stream.write(body + '\n')
                    with (stage / 'all.jsonl').open('w', encoding='utf-8') as stream:
                        for (body,) in db.execute('SELECT body FROM turns ORDER BY stamp,seq'):
                            stream.write(body + '\n')
                    (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
                    for name in [s + '.jsonl' for s in SOURCES] + ['all.jsonl', 'manifest.json']:
                        os.replace(str(stage / name), str(out / name))
            db.close()
            print(json.dumps(manifest, indent=2))
            print('Redactions: ' + json.dumps(manifest['redactions'], sort_keys=True), file=sys.stderr)
    finally:
        os.umask(old_umask)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, sqlite3.Error) as error:
        print('Export failed: %s' % error, file=sys.stderr)
        if '--verbose' in sys.argv[1:]:
            traceback.print_exc()
        sys.exit(1)
