#!/usr/bin/env python3
"""Verify the durable App Office stage trace from the real Floe simulator run.

The trace (``office-stage.jsonl`` pulled from the app container) is App-observed
evidence only. Each mounted ``OfficeFileSession`` is one native open and has a
monotonic open generation that advances on every (re)mount, so this gate
validates per ``(session, generation)`` window — never per session — and fails
closed.

The real qualification scenario (``OfficeRealEngineUITests``) follows the
App's actual Notes entry policy
(``NotesOfficeView.prepare`` / ``OfficeDocumentModeStore``):

* an imported document's FIRST completed entry is a read-only preview; from
  the second entry onwards Notes remembers edit mode and ``prepare()`` itself
  drives ``open()`` (a read-only mount that is usually torn down before it can
  paint) followed by ``requestEditing()`` — there is no host Edit button to
  tap on a remembered reopen;
* the first edit cycle therefore opens the fixture as a painted preview and
  taps the real host Edit action: ONE session with a painted preview
  generation followed by its OWN editable generation (mount + paint +
  ``edit.entry readOnly=false`` + ``edit.acknowledged`` + ``save.ok``);
* the second edit cycle is a remembered reopen in a NEW session: its editable
  generation must mount, paint, be acknowledged and save on its OWN
  generation, and is accepted without a painted in-session preview ONLY
  because the immediately preceding open session saved (``save.ok``) and was
  closed by the host (``close.acked``) before this session mounted;
* the same document is then reopened a SECOND time and its editable
  generation paints again while the persisted (four-slide) document is
  verified, before another save/close.

Global requirements:

* ``engine.linked`` with ``simulator=true`` — the genuine framework was linked
  (compile/link evidence only; it never satisfies render/save requirements),
  and no ``engine.unavailable`` (a build without the engine records it);
* the qualification fixture import carrying the pinned synthetic SHA-256;
* at least three distinct mounted/painted native open sessions;
* at least two editable generations, EACH with mount + paint + edit
  acknowledgement + save on its OWN ``(session, generation)`` — a
  preview-generation paint can never satisfy the edited generation;
* at least one explicit painted preview -> edit handoff inside one session;
* every remembered/auto edit session (no painted preview in its session)
  proves the prior save -> close -> reopen lifecycle across sessions;
* every edit session ends with ``close.acked`` AFTER its ``save.ok`` and
  every preview-only session with a close/release receipt after its mount;
* no failure stage anywhere (runtime death, visible-render failure,
  unverified render, staging failure, save/close failure, ...).

The accompanying UITest receipt is required: exact phase coverage, in order,
no duplicates, all ok, and ``idle-120s`` that actually lasted. A malformed or
empty trace, a missing receipt, or missing/duplicate/out-of-order phases all
fail closed.
"""
import argparse
import json
from pathlib import Path

FAILURE_STAGES = (
    'runtime.failed',
    'engine.visibleRenderFailed',
    'render.unverified',
    'host.webContent.terminated',
    'engine.runtime.prepare.failed',
    'engine.unavailable',
    'open.watchdog',
    'save.failed',
    'notes.open.failed',
    'notes.staging.failed',
    'notes.exit.saveFailed',
    'notes.exit.commitFailed',
    'workingCopy.failed',
    'edit.fallback.preview',
    'close.failed',
    'close.timedOut',
    'session.failed',
    'engine.closed.unexpected',
)

# Single source of truth shared with OfficeRealEngineUITests.expectedPhases.
SCENARIO_PHASES = (
    'import',
    'preview-open',
    'enter-edit',
    'insert-slide',
    'slideshow-start',
    'slideshow-page1',
    'slideshow-blank-page',
    'slideshow-page2',
    'slideshow-exit',
    'idle-120s',
    'save',
    'leave-edit',
    'close',
    'reopen',
    'edit-again',
    'insert-slide-again',
    'save-again',
    'close-after-reopen',
    'reopen-2',
    'verify-persisted',
    'save-final',
    'close-final',
)

# Main-document chain: the explicit preview -> edit handoff session plus the
# same document's save/close/reopen twice.
REQUIRED_MAIN_CHAIN_OPENS = 3
REQUIRED_MAIN_CHAIN_EDITS = 3
# Remembered reopen edit sessions chained after the handoff session.
REQUIRED_CHAINED_REOPENS = 2

# Process-level sessions that are never a document/native open.
NON_DOCUMENT_SESSIONS = ('app-launch', 'qualification')

# A terminal release receipt for a preview-only open.
TERMINAL_RELEASE_STAGES = ('session.release',)


class TraceGateError(ValueError):
    pass


def load_events(path):
    path = Path(path)
    if not path.is_file():
        raise TraceGateError(f'trace file missing: {path}')
    raw_lines = path.read_text().splitlines()
    if not any(line.strip() for line in raw_lines):
        raise TraceGateError('trace file is empty')
    events, malformed = [], 0
    for line in raw_lines:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            malformed += 1
            continue
        if (isinstance(event, dict) and isinstance(event.get('session'), str)
                and isinstance(event.get('stage'), str)
                and isinstance(event.get('generation'), int)):
            events.append(event)
        else:
            malformed += 1
    if not events:
        raise TraceGateError('trace has no usable events (malformed or empty)')
    return events, malformed


def generation_windows(events):
    """Group events by (session, generation), ordered by first appearance."""
    order, windows = [], {}
    for event in events:
        key = (event['session'], event['generation'])
        if key not in windows:
            windows[key] = []
            order.append(key)
        windows[key].append(event)
    return [(key, windows[key]) for key in order]


def detail(event, key):
    value = event.get('detail') or {}
    if not isinstance(value, dict):
        return None
    return str(value[key]) if key in value else None


def at_value(event):
    """Comparable event time. The real recorder persists Foundation Date as
    seconds-since-reference-date (a JSON number); anything unparseable is
    None and ordering checks fail closed on it."""
    value = event.get('at')
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value))
    except (TypeError, ValueError):
        return None


def decoded_tiles(event):
    try:
        return int(detail(event, 'decodedTiles') or 0)
    except ValueError:
        return 0


def _first_at(window, predicate):
    for event in window:
        if predicate(event):
            value = at_value(event)
            if value is not None:
                return value
    return None


def _revision(event, key='revision'):
    raw = detail(event, key)
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def window_summary(window):
    stages = [event['stage'] for event in window]
    visible = [event for event in window if event['stage'] == 'engine.visibleRender']
    edits = [event for event in window
             if event['stage'] == 'edit.entry' and detail(event, 'readOnly') == 'false']
    acknowledged = [event for event in window
                    if event['stage'] == 'edit.acknowledged'
                    and detail(event, 'readOnly') == 'false']
    auto_requested = [event for event in window
                      if event['stage'] == 'notes.edit.requested'
                      and detail(event, 'entered') == 'true']
    saves = [event for event in window if event['stage'] == 'save.ok']
    mounts = [event for event in window if event['stage'] == 'controller.mounted']
    staged = [event for event in window if event['stage'] == 'notes.staged']
    committed = [event for event in window if event['stage'] == 'notes.commit.ok']
    mount_times = [at_value(event) for event in mounts]
    mount_times = [value for value in mount_times if value is not None]
    staged_revisions = [value for value in (_revision(event) for event in staged)
                        if value is not None]
    commit_revisions = [value for value in (_revision(event) for event in committed)
                        if value is not None]
    return {
        'stages': stages,
        'painted': bool(visible) and all(decoded_tiles(event) > 0 for event in visible),
        'editAck': bool(edits),
        'editConfirmed': bool(acknowledged) or bool(auto_requested),
        'saved': bool(saves),
        'mounted': bool(mounts),
        'readOnlyMount': any(detail(event, 'readOnly') == 'true' for event in mounts),
        'firstAt': at_value(window[0]),
        'lastAt': at_value(window[-1]),
        'mountAt': min(mount_times) if mount_times else None,
        'editAt': _first_at(
            window, lambda e: e['stage'] == 'edit.entry'
            and detail(e, 'readOnly') == 'false'),
        'saveAt': _first_at(window, lambda e: e['stage'] == 'save.ok'),
        'closeStartedAt': _first_at(window, lambda e: e['stage'] == 'close.started'),
        'closeAckedAt': _first_at(window, lambda e: e['stage'] == 'close.acked'),
        'releasedAt': _first_at(window, lambda e: e['stage'] in TERMINAL_RELEASE_STAGES),
        'stagedRevision': min(staged_revisions) if staged_revisions else None,
        'commitRevision': max(commit_revisions) if commit_revisions else None,
        'visibleTiles': [decoded_tiles(event) for event in visible],
    }


def verify(trace_path, receipt_path=None, fixture_sha256=None,
           idle_seconds=120,
           min_main_chain_opens=REQUIRED_MAIN_CHAIN_OPENS,
           min_main_chain_edits=REQUIRED_MAIN_CHAIN_EDITS,
           min_chained_reopens=REQUIRED_CHAINED_REOPENS):
    failures = []
    try:
        events, malformed = load_events(trace_path)
    except TraceGateError as error:
        return {'traceEvents': 0, 'failures': [str(error)], 'tracePassed': False,
                'checkKind': 'durable-app-stage-trace', 'hostKind': 'fullFloeAppSimulator'}
    if malformed:
        failures.append(f'trace contained {malformed} malformed line(s)')

    linked = [event for event in events if event['stage'] == 'engine.linked']
    if not linked:
        failures.append('engine.linked stage missing (real framework link unproven)')
    elif not any(detail(event, 'simulator') == 'true' for event in linked):
        failures.append('engine.linked did not record simulator=true')

    imports = [event for event in events
               if event['stage'] == 'qualification.fixture.imported']
    if not imports:
        failures.append('qualification fixture import stage missing')
    elif fixture_sha256 and not any(detail(event, 'sha256') == fixture_sha256
                                    for event in imports):
        failures.append('imported fixture SHA-256 does not match the pinned synthetic fixture')

    windows = [(key, window_summary(window)) for key, window in generation_windows(events)]

    # Document sessions (real native opens) are the sessions that mounted a
    # controller; process-level sessions (engine.linked/fixture import) never
    # count as an open.
    session_order = []
    session_windows = {}
    for (session, _generation), summary in windows:
        if session in NON_DOCUMENT_SESSIONS or not summary['mounted']:
            continue
        if session not in session_windows:
            session_windows[session] = []
            session_order.append(session)
        session_windows[session].append(((session, _generation), summary))
    session_order.sort(key=lambda sess: min(
        (summary['mountAt'] for _, summary in session_windows[sess]
         if summary['mountAt'] is not None),
        default=float('inf')))

    # Notes records notes.staged in prepare() BEFORE the first controller
    # mount, so it lands on the session's unmounted generation 0 window. Gather
    # the staged revision (content-free continuity fact) per session across ALL
    # of its windows; the main-document chain uses it to prove a reopen staged
    # the exact revision the predecessor edit session committed.
    session_staged_revision = {}
    for (session, _generation), summary in windows:
        if session in NON_DOCUMENT_SESSIONS or summary['stagedRevision'] is None:
            continue
        session_staged_revision.setdefault(session, summary['stagedRevision'])
        session_staged_revision[session] = min(
            session_staged_revision[session], summary['stagedRevision'])

    native_open_sessions = [
        sess for sess in session_order
        if any(summary['mounted'] and summary['painted']
               for _, summary in session_windows[sess])]

    def is_edit_window(entry):
        _, summary = entry
        return (summary['mounted'] and summary['painted'] and summary['editAck']
                and summary['editConfirmed'] and summary['saved'])

    def is_preview_window(entry):
        _, summary = entry
        # A painted editable mount that never sent edit.entry is a failed/
        # refused edit, not a read-only preview: it must never grant handoff.
        return (summary['mounted'] and summary['painted'] and summary['readOnlyMount']
                and not summary['editAck'])

    def session_has_edit(sess):
        return any(is_edit_window(entry) for entry in session_windows[sess])

    def session_edit_window(sess):
        for entry in session_windows[sess]:
            if is_edit_window(entry):
                return entry
        return None

    def session_last_close(sess):
        return max((summary['closeAckedAt'] for _, summary in session_windows[sess]
                    if summary['closeAckedAt'] is not None), default=None)

    def terminal_after_mount(summary):
        terminal = max([value for value in (summary['closeAckedAt'],)
                        if value is not None]
                       + ([summary['releasedAt']] if summary['releasedAt'] is not None else []),
                       default=None)
        return terminal is not None and summary['mountAt'] is not None \
            and terminal >= summary['mountAt']

    # Terminal receipts: an edit session must be closed by the host AFTER its
    # save; a preview-only session needs close.acked or session.release after
    # its mount. A missing close can never be inferred from the next open.
    for sess in session_order:
        entries = session_windows[sess]
        edit_entry = session_edit_window(sess)
        mounts = [summary['mountAt'] for _, summary in entries
                  if summary['mountAt'] is not None]
        last_mount = max(mounts) if mounts else None
        if edit_entry is not None:
            _, edit_summary = edit_entry
            last_save = edit_summary['saveAt']
            close_ack = session_last_close(sess)
            if last_save is None or close_ack is None or last_mount is None:
                failures.append(
                    f'edit session {sess} lacks the save.ok -> close.acked terminal receipts')
            elif close_ack < last_save:
                failures.append(
                    f'edit session {sess} close.acked precedes its save.ok '
                    '(no saved reopen lifecycle)')
            elif close_ack < last_mount:
                failures.append(
                    f'edit session {sess} close.acked precedes its editable mount')
        else:
            if not all(terminal_after_mount(summary) for _, summary in entries):
                failures.append(
                    f'preview-only session {sess} has no close/release receipt after its mount')

    edit_windows = [entry for entry in windows if is_edit_window(entry)]
    preview_windows = [entry for entry in windows if is_preview_window(entry)]

    # --- Main-document chain ---------------------------------------------
    # The chain is one imported document driven across three distinct native
    # open sessions:
    #   chain[0]  explicit painted preview -> host Edit handoff in ONE session;
    #   chain[1]  remembered reopen, auto-driven editable generation;
    #   chain[2]  remembered reopen #2 painting its OWN editable generation and
    #             verifying the persisted document.
    # The UITest selects the same pinned fixture card for every reopen.
    # This trace checks its content-free Notes revision continuity as an
    # additional contract; revision numbers alone are not document identity:
    # the staged revision of each reopen session equals the revision the
    # predecessor session committed (notes.staged revision -> notes.commit.ok).
    explicit_handoff_sessions = set()
    for (session, generation), summary in edit_windows:
        for (preview_session, preview_generation), preview in preview_windows:
            if (preview_session == session and preview_generation < generation
                    and preview['mountAt'] is not None and summary['mountAt'] is not None
                    and preview['mountAt'] <= summary['mountAt']):
                explicit_handoff_sessions.add(session)

    handoff_sessions = [sess for sess in session_order
                        if sess in explicit_handoff_sessions]
    if not handoff_sessions:
        failures.append(
            'no explicit painted preview -> edit handoff session: every edit would be an '
            'unverified direct editable open')
    elif len(handoff_sessions) > 1:
        failures.append(
            f'{len(handoff_sessions)} explicit preview -> edit handoff sessions '
            f'{handoff_sessions}: the scenario drives ONE imported document, so a second '
            'handoff document cannot be part of acceptance')
    chain = handoff_sessions[:1]
    remembered_edit_windows = []
    chain_failure = not handoff_sessions
    while len(chain) < min_main_chain_opens and not chain_failure:
        predecessor = chain[-1]
        index = session_order.index(predecessor)
        candidate = session_order[index + 1] if index + 1 < len(session_order) else None
        if candidate is None or not session_has_edit(candidate):
            failures.append(
                f'main-document chain stops after session {predecessor}: the same '
                'document needs another mounted editable reopen session')
            chain_failure = True
            break
        _, candidate_summary = session_edit_window(candidate)
        prior_edit = session_edit_window(predecessor)
        prior_close = session_last_close(predecessor)
        prior_commit = prior_edit[1]['commitRevision'] if prior_edit else None
        if (candidate_summary['mountAt'] is None or prior_edit is None
                or prior_edit[1]['saveAt'] is None or prior_close is None
                or prior_close < prior_edit[1]['saveAt']
                or prior_close >= candidate_summary['mountAt']):
            failures.append(
                f"reopen session {candidate} does not resume predecessor {predecessor}: "
                'need save.ok -> close.acked before this editable mount')
            chain_failure = True
            break
        staged_revision = session_staged_revision.get(candidate)
        if prior_commit is None or staged_revision is None:
            failures.append(
                f'reopen session {candidate} lacks staged/committed revision continuity')
            chain_failure = True
            break
        if staged_revision != prior_commit:
            failures.append(
                f'reopen session {candidate} stages revision {staged_revision} but the '
                f'predecessor edit session committed revision {prior_commit} (not the same '
                'saved document)')
            chain_failure = True
            break
        # A chained reopen must paint its OWN editable generation; an in-session
        # painted preview is not required (prepare() auto-drives the edit), but
        # the edit window itself is already proven painted+acked+saved.
        remembered_edit_windows.append(
            f"{candidate}/g{session_edit_window(candidate)[0][1]}")
        chain.append(candidate)

    if not chain_failure and len(chain) < min_main_chain_opens:
        failures.append(
            f'main-document chain has {len(chain)} open session(s) '
            f'(need {min_main_chain_opens}: handoff + two same-document reopens)')
    if not chain_failure and len(edit_windows) < min_main_chain_edits:
        failures.append(
            f'only {len(edit_windows)} edit generation(s) with mount+paint+editack+save '
            f'on the same (session, generation) (need {min_main_chain_edits})')
    if not chain_failure and len(remembered_edit_windows) < min_chained_reopens:
        failures.append(
            f'only {len(remembered_edit_windows)} chained remembered reopen edit(s) '
            f'(need {min_chained_reopens}: save/close/reopen twice on the same document)')
    # Any edit session that is neither the handoff session nor a proven chain
    # member must not exist: a stray direct editable open elsewhere cannot be
    # counted (e.g. an edit parked on the rapid second document).
    chain_set = set(chain)
    for sess in session_order:
        if not session_has_edit(sess) or sess in chain_set:
            continue
        if sess not in explicit_handoff_sessions:
            failures.append(
                f'edit session {sess} is outside the main-document chain with no painted '
                'preview handoff (an auxiliary document edit cannot satisfy acceptance)')



    # Zero-tile paints anywhere are a render failure signal, not just in the
    # counted windows.
    for (session, generation), window in generation_windows(events):
        for event in window:
            if event['stage'] == 'engine.visibleRender' and decoded_tiles(event) <= 0:
                failures.append(
                    f'engine.visibleRender with decodedTiles=0 at session={session} '
                    f'generation={generation}')

    for event in events:
        if event['stage'] in FAILURE_STAGES:
            failures.append(f"failure stage present: {event['stage']}")

    receipt_facts = None
    if receipt_path is None:
        failures.append('UITest receipt path not provided')
    else:
        receipt_file = Path(receipt_path)
        if not receipt_file.is_file():
            failures.append(f'UITest receipt missing: {receipt_file}')
        else:
            try:
                receipt = json.loads(receipt_file.read_text())
            except json.JSONDecodeError as error:
                receipt = None
                failures.append(f'UITest receipt malformed: {error}')
            if receipt is not None:
                phases = receipt.get('phases')
                if not isinstance(phases, list) or not phases:
                    failures.append('UITest receipt phases missing or empty')
                else:
                    seen, order_index, duplicates = [], [], set()
                    bad_entries = False
                    for phase in phases:
                        if not isinstance(phase, dict) or not isinstance(phase.get('phase'), str):
                            failures.append('malformed phase entry in receipt')
                            bad_entries = True
                            continue
                        name = phase['phase']
                        if name in seen:
                            duplicates.add(name)
                        seen.append(name)
                        if name not in SCENARIO_PHASES:
                            order_index.append(-1)
                        else:
                            order_index.append(SCENARIO_PHASES.index(name))
                    missing = [name for name in SCENARIO_PHASES if name not in seen]
                    extra = sorted({name for name in seen if name not in SCENARIO_PHASES})
                    not_ok = [phase['phase'] for phase in phases
                              if isinstance(phase, dict) and not phase.get('ok')]
                    if missing:
                        failures.append(f'UITest receipt missing phases: {missing}')
                    if extra:
                        failures.append(f'UITest receipt unexpected phases: {extra}')
                    if duplicates:
                        failures.append(f'UITest receipt duplicate phases: {sorted(duplicates)}')
                    if not_ok:
                        failures.append(f'UITest receipt phases not ok: {not_ok}')
                    if not bad_entries and not missing and any(
                            order_index[i] > order_index[i + 1]
                            for i in range(len(order_index) - 1) if order_index[i] >= 0
                            and order_index[i + 1] >= 0):
                        failures.append('UITest receipt phases out of order')
                    idle = next((phase for phase in phases
                                 if isinstance(phase, dict)
                                 and phase.get('phase') == 'idle-120s'), None)
                    if idle is None:
                        failures.append('UITest receipt lacks idle-120s')
                    else:
                        started = idle.get('startedAt')
                        finished = idle.get('finishedAt')
                        if not isinstance(started, (int, float)) \
                                or not isinstance(finished, (int, float)) \
                                or finished - started < idle_seconds:
                            failures.append('idle-120s phase did not last the required 120 s')
                    receipt_facts = {'phases': len(seen), 'allOk': not not_ok and not missing
                                     and not duplicates and not extra}

    result = {'traceEvents': len(events), 'malformedLines': malformed,
              'nativeOpenSessions': native_open_sessions,
              'mainChain': chain,
              'editWindows': [f'{s}/g{g}' for (s, g), _ in edit_windows],
              'previewWindows': [f'{s}/g{g}' for (s, g), _ in preview_windows],
              'explicitHandoffSessions': sorted(explicit_handoff_sessions),
              'rememberedEditWindows': remembered_edit_windows,
              'failures': failures, 'receipt': receipt_facts,
              'tracePassed': not failures, 'checkKind': 'durable-app-stage-trace',
              'hostKind': 'fullFloeAppSimulator'}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path, help='office-stage.jsonl from the app container')
    parser.add_argument('--receipt', type=Path, default=None,
                        help='office-real-engine-receipt.json (UITest runner copy)')
    parser.add_argument('--fixture-sha256', default=None)
    parser.add_argument('--idle-seconds', type=int, default=120)
    parser.add_argument('--output', type=Path, default=None)
    args = parser.parse_args()
    result = verify(args.trace, args.receipt, args.fixture_sha256, args.idle_seconds)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if not result['tracePassed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
