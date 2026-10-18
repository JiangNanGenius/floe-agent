#!/usr/bin/env python3
"""G01 on-device navigation smoke. Every tap comes from the current UI tree.

Requires explicit serial/package; install APKs separately. Captures only the opened
Floe app. It never enters credentials, changes system settings or clears device logs.

Labels below are the exact string resources of the iPad-style foundation shell
(FloeAndroid/app/src/main/res*/strings.xml): persistent/drawer sidebar with the
five fixed routes, settings as a sheet opened from the footer gear, and
Diagnostics & About as the sheet section that owns the real JNI handshake and
the debug-only component preview entry.

Adaptive idioms (source: FloeShell.kt, FloeDetailColumn.kt, SettingsSheet.kt):
- Compact (<600dp) keeps the sidebar in a drawer that closes on every route
  selection. Every non-home fixed route must still expose the 48dp drawer
  opener in its own toolbar; this runner checks Task Center, Notes, Creative
  and Plugins on the current tree and fails if the control is missing (it must
  not be "worked around" with system Back alone).
- Wide keeps the sidebar persistent; the runner verifies the route through the
  persistent list instead of demanding a drawer opener.
- Compact settings starts on the section list; General is pushed as a detail
  and the sheet's Back control returns to the list before Diagnostics can be
  opened. Wide settings shows list + detail side by side with the sheet title,
  Done and column toggle inside the 320dp section column.
- The component preview must appear after ONE tap on its button (the settings
  sheet is closed first); Back then returns to an explicit page instead of
  revealing a hidden dialog.
"""
import argparse
import json
import re
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--serial", required=True)
parser.add_argument("--package", required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--adb", default="adb")
args = parser.parse_args()
if args.package not in {"com.floe.agent.full.dev", "com.floe.agent.dev"}:
    parser.error("This smoke runner only launches Floe development packages")
args.output.mkdir(parents=True, exist_ok=True)

HOME_LABELS = {"今天想让 Floe 完成什么？", "What should Floe get done today?"}
NEW_TASK_LABELS = {"新建任务", "New task"}
TASK_CENTER_LABELS = {"任务中心", "Task Center"}
NOTES_LABELS = {"手记", "Notes"}
CREATIVE_LABELS = {"创意模式", "Creative"}
PLUGINS_LABELS = {"插件", "Plugins"}
SETTINGS_LABELS = {"设置", "Settings"}
GENERAL_LABELS = {"通用", "General"}
GENERAL_DETAIL_LABELS = {"日间与夜间主题", "Day & Night Theme"}
DIAGNOSTICS_LABELS = {"诊断与关于", "Diagnostics & About"}
PREVIEW_OPEN_LABELS = {"打开组件预览", "Open component preview"}
PREVIEW_TITLE_LABELS = {"组件预览", "Component preview"}
PREVIEW_BANNER_LABELS = {
    "合成演示数据 —— 并非您的历史;这里的任何内容都未被发送。",
    "Synthetic demo data — not your history. Nothing here was sent anywhere.",
}
BACK_LABELS = {"返回", "Back"}
CONNECTED_LABELS = {"已连接", "Connected"}
TASK_CENTER_EMPTY_LABELS = {"暂无任务", "No tasks yet"}
WORKSPACE_PENDING_LABELS = {
    "该工作区将在后续更新中提供。",
    "This workspace will become available in a future update.",
}
# Compact drawer and the collapsed wide sidebar expose different controls; both
# restore the sidebar from the current (already navigated) detail tree.
SIDEBAR_OPENERS = (
    {"打开任务列表", "Open task list"},
    {"展开任务列表", "Expand task list"},
)
NON_HOME_ROUTES = (
    ("task-center", TASK_CENTER_LABELS, TASK_CENTER_EMPTY_LABELS),
    ("notes", NOTES_LABELS, WORKSPACE_PENDING_LABELS),
    ("creative", CREATIVE_LABELS, WORKSPACE_PENDING_LABELS),
    ("plugins", PLUGINS_LABELS, WORKSPACE_PENDING_LABELS),
)


def adb(*command, binary=False):
    return subprocess.check_output([args.adb, "-s", args.serial, *command], text=not binary, timeout=35)


def snapshot(name):
    raw = adb("exec-out", "uiautomator", "dump", "/dev/tty")
    start = raw.find("<?xml")
    end = raw.find("</hierarchy>")
    if start < 0 or end < 0:
        raise RuntimeError("UI hierarchy unavailable; inspect device lock/foreground state")
    xml = raw[start:end + len("</hierarchy>")]
    (args.output / f"{name}.xml").write_text(xml)
    (args.output / f"{name}.png").write_bytes(adb("exec-out", "screencap", "-p", binary=True))
    return ET.fromstring(xml)


def find(tree, labels):
    for node in tree.iter("node"):
        if node.get("text") in labels or node.get("content-desc") in labels:
            return node
    return None


def tap(tree, labels):
    node = find(tree, labels)
    if node is None:
        raise RuntimeError(f"Expected UI control missing: {labels}")
    bounds = [int(n) for n in re.findall(r"\d+", node.get("bounds", ""))]
    if len(bounds) != 4:
        raise RuntimeError("Missing UI-derived tap bounds")
    x1, y1, x2, y2 = bounds
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
    time.sleep(0.35)


def wait_for(labels, seconds):
    deadline = time.monotonic() + seconds
    tree = snapshot("diagnostics-wait")
    while find(tree, labels) is None and time.monotonic() < deadline:
        time.sleep(0.4)
        tree = snapshot("diagnostics-wait")
    return tree


def press_back():
    adb("shell", "input", "keyevent", "4")
    time.sleep(0.4)


def ensure_sidebar_target(tree, labels, name):
    """Return a tree where `labels` is visible, opening the sidebar if hidden.

    A compact drawer closes after every route selection; the wide sidebar only
    hides when collapsed. Both are reopened from the control in the current
    detail toolbar, never from a stale pre-navigation snapshot.
    """
    if find(tree, labels) is not None:
        return tree
    for opener in SIDEBAR_OPENERS:
        if find(tree, opener) is None:
            continue
        tap(tree, opener)
        tree = snapshot(name)
        if find(tree, labels) is not None:
            return tree
        raise RuntimeError(f"Sidebar reopened but target still missing: {labels}")
    raise RuntimeError(f"Expected sidebar target hidden with no visible opener: {labels}")


component = adb("shell", "cmd", "package", "resolve-activity", "--brief", args.package).strip().splitlines()[-1]
if "/" not in component:
    raise RuntimeError("Package has no launchable activity")
adb("shell", "am", "start", "-W", "-n", component)
tree = snapshot("01-home")
assert find(tree, HOME_LABELS) is not None, "New-task home (welcome + composer) missing"
# Composer controls are part of the home acceptance: the two 48dp trailing
# targets must be laid out in the first row, not pushed outside the chrome.
assert find(tree, {"语音输入", "Voice input"}) is not None, "Composer voice target missing on home"
assert find(tree, {"发送", "Send"}) is not None, "Composer send target missing on home"

# Adaptive idiom: a compact phone shows the drawer opener; a tablet keeps the
# sidebar visible and therefore has no drawer opener on the home toolbar.
compact = find(tree, {"打开任务列表", "Open task list"}) is not None
persistent_sidebar = not compact

route_checks = []
for route_id, route_labels, empty_labels in NON_HOME_ROUTES:
    tree = ensure_sidebar_target(tree, route_labels, f"02-{route_id}-sidebar")
    tap(tree, route_labels)
    tree = snapshot(f"03-{route_id}")
    assert find(tree, empty_labels) is not None, f"{route_id} honest empty state missing"
    if compact:
        opener = find(tree, {"打开任务列表", "Open task list"})
        if opener is None:
            raise RuntimeError(
                f"Compact {route_id} detail is missing the visible drawer opener; "
                "system Back is not an acceptable substitute"
            )
        tap(tree, {"打开任务列表", "Open task list"})
        tree = snapshot(f"04-{route_id}-drawer")
        assert find(tree, route_labels) is not None, f"{route_id} drawer did not reopen"
        press_back()
        tree = snapshot(f"05-{route_id}-drawer-closed")
        assert find(tree, empty_labels) is not None, f"{route_id} screen changed when the drawer closed"
        press_back()
        tree = snapshot(f"06-{route_id}-home")
        assert find(tree, HOME_LABELS) is not None, f"System Back from {route_id} did not return home"
        route_checks.append({"route": route_id, "drawerOpener": True, "backHome": True})
    else:
        assert find(tree, route_labels) is not None, f"{route_id} persistent sidebar lost its label"
        tap(tree, NEW_TASK_LABELS)
        tree = snapshot(f"04-{route_id}-home")
        assert find(tree, HOME_LABELS) is not None, f"Could not return home from {route_id}"
        route_checks.append({"route": route_id, "persistentSidebar": True, "backHome": True})
    if persistent_sidebar:
        assert find(tree, SETTINGS_LABELS) is not None, "Persistent sidebar footer gear missing"

# Settings is the footer-gear SHEET, not a sidebar route. Gear and sheet share
# the "设置/Settings" label; open from the sidebar footer. On compact the gear
# lives in the drawer, which the last route selection closed.
tree = ensure_sidebar_target(tree, SETTINGS_LABELS, "07-sidebar-for-settings")
tap(tree, SETTINGS_LABELS)
tree = snapshot("07-settings-sheet")
assert find(tree, GENERAL_LABELS | GENERAL_DETAIL_LABELS) is not None, \
    "Settings sheet General entry/page chrome missing"

# Compact settings opens on the section list: enter General to inspect its
# detail, then use the sheet Back control to return to the list before choosing
# Diagnostics. Wide settings already shows General's detail next to the list.
compact_settings = find(tree, GENERAL_DETAIL_LABELS) is None
if compact_settings:
    tap(tree, GENERAL_LABELS)
    tree = snapshot("08-settings-general")
    assert find(tree, GENERAL_DETAIL_LABELS) is not None, "General detail (Day & Night Theme) missing"
    tap(tree, BACK_LABELS)
    tree = snapshot("09-settings-sections")
assert find(tree, DIAGNOSTICS_LABELS) is not None, "Diagnostics & About section missing"
tap(tree, DIAGNOSTICS_LABELS)
tree = snapshot("10-diagnostics")
tree = wait_for(CONNECTED_LABELS, 8)
assert find(tree, CONNECTED_LABELS) is not None, "Real shared-core handshake not connected"

# One tap on the preview button must reveal the preview itself: the settings
# sheet is a Dialog window, so it is dismissed before the shell-hosted preview
# is shown. Closing the preview must land on an explicit page, not a hidden
# dialog underneath.
assert find(tree, PREVIEW_OPEN_LABELS) is not None, "Component preview entry missing"
tap(tree, PREVIEW_OPEN_LABELS)
tree = snapshot("11-preview-one-click")
assert find(tree, PREVIEW_TITLE_LABELS) is not None, "Single tap did not reveal the component preview"
assert find(tree, PREVIEW_BANNER_LABELS) is not None, "Preview opened without its synthetic-data banner"
press_back()
tree = snapshot("12-preview-closed")
assert find(tree, PREVIEW_TITLE_LABELS) is None, "Preview did not close on system Back"
assert find(tree, HOME_LABELS) is not None, \
    "Closing the preview did not land on an explicit page (home expected, no hidden sheet)"
assert find(tree, GENERAL_LABELS | DIAGNOSTICS_LABELS) is None, \
    "Settings sheet stayed composed after the preview closed"

# System back must close the sheet before navigation changes. A compact detail
# page may consume the first back to return to its section list; if so, the
# second back dismisses the sheet. The final state must be New-task home.
tree = ensure_sidebar_target(tree, SETTINGS_LABELS, "13-sidebar-for-back")
tap(tree, SETTINGS_LABELS)
tree = snapshot("13-settings-before-back")
back_presses = 0
while back_presses < 2:
    press_back()
    back_presses += 1
    tree = snapshot("14-home-after-sheet" if back_presses == 1 else "14-home-after-sheet-2")
    if find(tree, HOME_LABELS) is not None:
        break
assert find(tree, HOME_LABELS) is not None, "Back did not return from settings sheet to home"
assert find(tree, GENERAL_LABELS | DIAGNOSTICS_LABELS) is None, \
    "Back left a settings section on screen instead of dismissing the sheet"

# Stop/relaunch this development package only; durable task recovery belongs to G02.
# G01 drafts live in RAM, so relaunching starts from the honest empty composer.
adb("shell", "am", "force-stop", args.package)
adb("shell", "am", "start", "-W", "-n", component)
tree = snapshot("15-relaunched")
assert find(tree, HOME_LABELS) is not None
result = {
    "package": args.package,
    "sdk": adb("shell", "getprop", "ro.build.version.sdk").strip(),
    "abi": adb("shell", "getprop", "ro.product.cpu.abi").strip(),
    "pageSize": adb("shell", "getconf", "PAGE_SIZE").strip(),
    "navigation": {
        "compactDrawer": compact,
        "persistentSidebar": persistent_sidebar,
        "compactSettingsSectionList": compact_settings,
        "sheetBackPresses": back_presses,
        "drawerRoutes": route_checks,
        "previewOneClick": True,
        "previewBackHome": True,
        "composerTargetsVisible": True,
    },
    "checks": [
        "launch",
        "composer voice/send targets laid out",
        "home/sidebar responsive navigation",
        "task center truthful empty state",
        "notes/creative/plugins truthful empty states",
        "drawer opener on all four non-home routes (compact)",
        "drawer/sidebar reopen from current UI tree",
        "settings sheet",
        "compact section list and General detail",
        "real Swift handshake",
        "component preview opens on one tap",
        "preview Back returns to explicit home",
        "system back closes sheet",
        "relaunch",
    ],
    "scope": "G01 foundation only; no claim of whole-product functional parity",
}
(args.output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(result, ensure_ascii=False))
