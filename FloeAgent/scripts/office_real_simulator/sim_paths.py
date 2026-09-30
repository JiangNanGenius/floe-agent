#!/usr/bin/env python3
"""Shared paths and pinned facts for the real Office simulator qualification.

Scope boundary: this qualification builds the *upstream* Collabora iOS app
(``ios/Mobile.xcodeproj`` -> Mobile.app) against a freshly compiled
``iphonesimulator`` engine. It is a genuine native Office host, but it is NOT
the Floe app: Floe's ``project.yml`` links/embeds FloeOfficeNative only for the
iphoneos SDK (``[sdk=iphoneos*]``) and ``embed_office_host.py`` exits on the
simulator, so the full Floe app cannot host Office in the simulator without
out-of-scope changes to those files. Every receipt this package writes labels
the host as ``upstream-mobile-host-only``, never ``fullApp``.
"""
from pathlib import Path


def normalize_xcode_version(value):
    """Use one identity for multiline CLI output and retained build receipts."""
    return '; '.join(part.strip() for part in value.replace('\r', '').replace('\n', ';').split(';')
                     if part.strip())

# FloeAgent/scripts/office_real_simulator/sim_paths.py -> parents
THIS_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = THIS_DIR.parent
FLOEAGENT_DIR = SCRIPTS_DIR.parent
REPO_ROOT = FLOEAGENT_DIR.parent

LOCK_PATH = FLOEAGENT_DIR / 'ThirdParty/Collabora/engine.lock.json'
DEPLOYMENT_PATCH = FLOEAGENT_DIR / 'ThirdParty/Collabora/patches/ios-deployment-target.patch'

# Upstream app identity (distinct bundle id, clearly not Floe).
HOST_APP_NAME = 'Floe Real Simulator Qualification'
HOST_BUNDLE_ID = 'org.floeagent.office-real-simulator-qual'
HOST_VENDOR = 'Floe'
# The UI drives On My iPad -> <app container> -> TestFiles -> fixture.
FIXTURE_BASENAME = 'floe-sim-qual.pptx'
FIXTURE_SLIDE_COUNT = 2
# Pinned deterministic fixture (make_fixture.build_bytes must always reproduce it).
FIXTURE_SHA256 = '4b8ab9081859526bd019323f4b08e1d109f6a4ffa5deb43b71631f3da049fff5'

# The staged-engine artifact layout produced by build-stage and consumed by
# runtime.  ``gh run download -n NAME -D DIR`` extracts the artifact contents
# directly into DIR (no artifact-name subdirectory), so all runtime paths are
# relative to that flat staged directory.
STAGED_ENGINE_TAR = 'office-engine-iphonesimulator-arm64.tar.gz'
STAGED_PROVENANCE = 'simulator-provenance.json'
STAGED_QUALIFICATION = 'qualification.json'
STAGED_MANIFEST = 'staged-layout.json'

# The phase receipt the host writes and the persistence gate validates.
RECEIPT_ATTACHMENT_NAME = 'sim-qual-receipt'
RECEIPT_FILENAME = 'sim-qual-receipt.json'

# ---------------------------------------------------------------------------
# Completed-core checkpoint contract.
#
# The engine build (engine-configure + engine-build, ~175 min) is the only
# phase expensive enough that losing it to a downstream failure is
# unacceptable.  A checkpoint is therefore packed at the successful
# engine-build boundary, BEFORE editor-autogen/editor-configure/editor-build
# run, and uploaded as its own Actions artifact immediately.  It is a
# deliberately separate, smaller contract than the final staged engine:
#
# * it is NOT ``nativeBuildPassed`` and NOT a final qualification: the
#   embedding/browser build has not run yet and no App work has been done;
# * it binds exact source commit, deployment patch, platform/arch, SDK and
#   Xcode identity plus a per-file SHA-256 manifest;
# * a resume validates it against ``engine.lock.json`` and the current
#   runner, extracts only the engine build outputs over a freshly prepared
#   pinned checkout, and then runs editor phases only -- engine-configure and
#   engine-build are structurally excluded from a resumed phase plan.
CORE_CHECKPOINT_KIND = 'engine-build-completed'
CORE_CHECKPOINT_ARTIFACT = 'office-real-simulator-core-checkpoint'
CORE_CHECKPOINT_TAR = 'simulator-core-checkpoint.tar.gz'
CORE_CHECKPOINT_JSON = 'simulator-core-checkpoint.json'
CORE_CHECKPOINT_MANIFEST = 'core-manifest.json'
CORE_CHECKPOINT_QUALIFICATION = 'qualification.json'
CORE_RESUME_REPORT = 'core-checkpoint-restore.json'

# Exact upstream configure/ac requirement: configure.ac runs
# ``/usr/bin/env python3 -c "import lxml"`` (and polib) and hard-fails on
# Darwin.  PATH must therefore select the prepared venv for every subprocess.
CONFIGURE_PYTHON_CHECK = '/usr/bin/env python3 -c "import lxml; import polib"'
PINNED_PYTHON_PACKAGES = (('lxml', '5.4.0'), ('polib', '1.2.0'))

# Canonical phase names.  ENGINE_PHASES must never appear in a resumed plan.
ENGINE_PHASES = ('engine-configure', 'engine-build')
EDITOR_PHASES = ('editor-autogen', 'editor-configure', 'editor-build')

# Exact engine-build outputs the pinned top-level online ``configure`` reads
# after ``--with-lo-builddir`` (verified against
# online.mirror/configure.ac at engine.lock.json):
#   * ``$LOBUILDDIR/instdir/program/setuprc`` is the "is this a core build dir"
#     gate (configure.ac CHK + `test -f`);
#   * ``$LOBUILDDIR/config_host.mk`` supplies ENABLE_DBGUTIL / HAVE_LIBSTDCPP /
#     LIBCPP_DEBUG for ONLINE_MATCH_ENGINE_STDLIB_ABI;
#   * Poco and zstd headers/libs are sanity-checked by CHK_FILE_VAR.
# A completed-core checkpoint must retain all of them or resume cannot run the
# editor configure at all.
EDITOR_CONFIGURE_INPUTS = (
    'source/engine/config_host.mk',
    'source/engine/instdir/program/setuprc',
    'source/engine/workdir/UnpackedTarball/poco/include/Poco/Poco.h',
    'source/engine/workdir/LinkTarget/StaticLibrary/libPocoFoundation.a',
    'source/engine/workdir/UnpackedTarball/zstd/lib/zstd.h',
    'source/engine/workdir/LinkTarget/StaticLibrary/libzstd.a',
)

# Exact scenario phases, in order.  This is the single source of truth: the
# generated UITest scenario, the xcresult receipt extractor and the persistence
# gate all consume it, so receipt coverage can never silently drift.
SCENARIO_PHASES = (
    'preview-open',
    'preview-close',
    'reopen-before-edit',
    'enter-edit',
    'insert-slide',
    'idle-120s',
    'save',
    'leave-edit',
    'close',
    'reopen',
    'close-after-reopen',
)
# Human-readable description of the native sequence actually driven.  The
# coordinator requires rapid preview close/reopen before edit because the
# failing device path is the two-native-opens path.
SCENARIO_NATIVE_SEQUENCE = (
    'open-preview -> close (rapid) -> reopen -> enter-edit -> insert-slide -> '
    'idle-120s -> save -> leave-edit -> close -> reopen -> close'
)

# Disk safety mirrors engine.lock.json (the pin, duplicated read-only here so a
# missing environment never defaults to "unlimited").
RESERVE_GIB = 6
MINIMUM_FREE_GIB = 12

# Runtime scenario timings.
IDLE_SECONDS = 120
EDITOR_LOAD_TIMEOUT = 180
