#!/usr/bin/env python3
"""Shared paths and pinned facts for the real Floe-app Office simulator run.

Scope: unlike ``office_real_simulator`` (upstream Mobile host only), this
package qualifies the REAL Floe app — the generated FloeAgent.xcodeproj app
target — hosting the genuine ``FloeOfficeNative.framework`` compiled for
``iphonesimulator`` from the staged real engine. The staged engine artifact is
produced by the ``office-real-simulator`` workflow (build-stage job) and is
never rebuilt here.

Every receipt this package writes labels the host ``fullFloeAppSimulator``.
"""
from pathlib import Path
import sys

THIS_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = THIS_DIR.parent
FLOEAGENT_DIR = SCRIPTS_DIR.parent
REPO_ROOT = FLOEAGENT_DIR.parent

# Reuse the pinned deterministic-fixture facts (read-only import; the module
# is never edited here).
sys.path.insert(0, str(SCRIPTS_DIR / 'office_real_simulator'))
from sim_paths import FIXTURE_BASENAME, FIXTURE_SHA256, FIXTURE_SLIDE_COUNT  # noqa: E402,F401

LOCK_PATH = FLOEAGENT_DIR / 'ThirdParty/Collabora/engine.lock.json'

# Base-engine artifact produced by .github/workflows/office-real-simulator.yml
# (build-stage). Consumed explicitly by run ID; never rebuilt in this flow.
ENGINE_ARTIFACT_NAME = 'office-real-simulator-engine'

# Produced/consumed host layouts.
HOST_BUNDLE_NAME = 'OfficeNativeHostSimulator'
HOST_RECEIPT_NAME = 'native-host-simulator.json'
HOST_ZIP_NAME = HOST_BUNDLE_NAME + '.zip'
VARIANTS = ('kit', 'nokit')

# Receipt written into the app container by the DEBUG-only qualification
# fixture (imports the pinned synthetic PPTX through the real Notes importer).
IMPORT_RECEIPT_NAME = 'office-real-engine-import.json'

# Debug launch plumbing (app side) — gated on -ui-testing + this argument.
FIXTURE_LAUNCH_ARGUMENT = '--ui-test-office-real-engine'
FIXTURE_ENVIRONMENT_KEY = 'FLOE_OFFICE_REAL_ENGINE_FIXTURE_B64'

# The imported note title the UI test drives (file basename of the fixture).
FIXTURE_NOTE_TITLE = Path(FIXTURE_BASENAME).stem

# Native sequence actually driven by OfficeRealEngineUITests, in order. Rapid
# preview close/reopen before edit mirrors the reported device failure path
# (the second native open of the same document).
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
SCENARIO_NATIVE_SEQUENCE = (
    'import PPTX through the real Notes importer -> open preview -> '
    'enter edit -> insert slide -> present (fixture slide 1 markers, the '
    'inserted blank page, fixture slide 2 green oval, touch quit back to the '
    'same session) -> idle 120 s -> save '
    '-> leave edit -> close -> reopen -> edit again -> insert slide -> save -> close '
    '-> second remembered reopen and persisted verification -> save -> close'
)

# Scenario timings (seconds).
IDLE_SECONDS = 120
EDITOR_LOAD_TIMEOUT = 180

# Disk safety mirrors engine.lock.json.
RESERVE_GIB = 6
MINIMUM_FREE_GIB = 12
