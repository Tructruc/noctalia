#!/usr/bin/env python3
"""
Build settings search index from QML source files.

Parses settings tab QML files to extract searchable metadata
(i18n keys, widget types, tab/sub-tab locations, visibility conditions).

Output: Assets/settings-search-index.json

Usage:
  python Scripts/dev/build-settings-search-index.py          # regenerate
  python Scripts/dev/build-settings-search-index.py --check  # fail if stale
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SETTINGS_DIR = ROOT / "Modules" / "Panels" / "Settings"
TABS_DIR = SETTINGS_DIR / "Tabs"
OUTPUT = ROOT / "Assets" / "settings-search-index.json"

# Widget types that have searchable label/description
WIDGET_TYPES = (
    "NToggle",
    "NComboBox",
    "NValueSlider",
    "NSpinBox",
    "NSearchableComboBox",
    "NTextInputButton",
    "NTextInput",
    "NCheckbox",
    "NLabel",
    "NColorChoice",
    "HookRow",
)

# Section headings: NText widgets use text: instead of label:, and only
# "-heading" keys are searchable section titles (the other NTexts are prose).
HEADING_TYPES = ("NText",)

# Regex patterns
RE_WIDGET_OPEN = re.compile(
    r"^\s*(" + "|".join(WIDGET_TYPES + HEADING_TYPES) + r")\s*\{", re.MULTILINE
)
RE_LABEL = re.compile(r'label:\s*I18n\.tr\("([^"]+)"')
RE_TEXT = re.compile(r'text:\s*I18n\.tr\("([^"]+)"')
RE_VISIBLE = re.compile(r'^\s*visible:\s*(.+?)(?:\s*;)?\s*$')
RE_COMPONENT_OPEN = re.compile(r"^\s*([A-Z]\w*)\s*\{", re.MULTILINE)
RE_DESCRIPTION_LINE = re.compile(r"description:\s*([^\n]+)")
HELPER_EXCLUDE_SUFFIXES = ("Popup", "Dialog", "Window", "Menu")

# Prefixes that indicate externally-resolvable conditions (singleton services or globals).
# Conditions referencing local variables (root., parent., model, index, etc.) are skipped.
RESOLVABLE_PREFIXES = (
    "CompositorService.",
    "Settings.data.",
    "Quickshell.",
    "IdleService.",
    "SystemStatService.",
    "SoundService.",
    "BluetoothService.",
    "LocationService.",
    "false",
)


def parse_component_declarations(content: str) -> dict[str, str]:
    """
    Parse Component declarations from SettingsContent.qml.

    Returns: component_id -> QML type name (e.g. "generalTab" -> "GeneralTab")
    """
    components = {}
    # Match patterns like:
    #   Component {
    #     id: generalTab
    #     GeneralTab {}
    #   }
    pattern = re.compile(
        r"Component\s*\{\s*\n\s*id:\s*(\w+)\s*\n\s*(\w+)\s*\{",
        re.MULTILINE,
    )
    for m in pattern.finditer(content):
        comp_id = m.group(1)
        type_name = m.group(2)
        components[comp_id] = type_name

    return components


def parse_tabs_model_order(content: str) -> list[tuple[str, str]]:
    """
    Parse updateTabsModel() to get the ordered list of (source_id, label_key) pairs.

    Returns: list of (component_id, i18n_label_key) in display order.
    """
    # Find the updateTabsModel function body
    match = re.search(r"function updateTabsModel\(\)\s*\{", content)
    if not match:
        return []

    func_body = content[match.end():]

    # Extract tab entries: each has "label" and "source" fields
    entries = []
    for m in re.finditer(
        r'"label":\s*"([^"]+)"[^}]*?"source":\s*(\w+)',
        func_body,
        re.DOTALL,
    ):
        entries.append((m.group(2), m.group(1)))

    return entries


def build_tab_mappings(content: str) -> tuple[dict[str, int], dict[str, str]]:
    """
    Build mappings from QML type name to tabsModel index and label key.

    Parses Component declarations and updateTabsModel() order.
    Returns: (type_to_index, type_to_label)
      - type_to_index: e.g. {"GeneralTab": 0, ...}
      - type_to_label: e.g. {"GeneralTab": "common.general", ...}
    """
    components = parse_component_declarations(content)
    entries = parse_tabs_model_order(content)

    type_to_index = {}
    type_to_label = {}
    for idx, (source_id, label_key) in enumerate(entries):
        type_name = components.get(source_id)
        if type_name:
            type_to_index[type_name] = idx
            type_to_label[type_name] = label_key

    return type_to_index, type_to_label


def get_subtab_info(parent_tab_file: Path) -> tuple[list[str], list[str | None]]:
    """
    Parse a parent tab file to get subtab order and labels.

    Returns: (subtab_type_names, subtab_label_keys)
      - subtab_type_names: list of component names like ["VolumesSubTab", ...]
      - subtab_label_keys: list of i18n keys like ["common.volumes", ...] (same order)
    """
    content = parent_tab_file.read_text()

    # Extract NTabButton labels in order from NTabBar
    labels = []
    in_tabbar = False
    tabbar_depth = 0

    for line in content.splitlines():
        stripped = line.strip()

        if not in_tabbar:
            if re.match(r"NTabBar\s*\{", stripped):
                in_tabbar = True
                tabbar_depth = 1
                continue
            continue

        tabbar_depth += stripped.count("{") - stripped.count("}")

        if tabbar_depth <= 0:
            break

        # Match text: I18n.tr("...") inside NTabButton
        m = re.search(r'text:\s*I18n\.tr\("([^"]+)"', stripped)
        if m:
            labels.append(m.group(1))

    # Extract subtab component names from NTabView
    subtabs = []
    in_tabview = False
    tabview_depth = 0

    for line in content.splitlines():
        stripped = line.strip()

        if not in_tabview:
            if re.match(r"NTabView\s*\{", stripped):
                in_tabview = True
                tabview_depth = 1
                continue
            continue

        tabview_depth += stripped.count("{") - stripped.count("}")

        if tabview_depth <= 0:
            break

        # Match component instantiations like "VolumesSubTab {}" or "VolumesSubTab {"
        m = re.match(r"(\w+SubTab)\s*\{", stripped)
        if m:
            subtabs.append(m.group(1))

    # Pad labels list if shorter than subtabs (shouldn't happen, but safety)
    while len(labels) < len(subtabs):
        labels.append(None)

    return subtabs, labels[:len(subtabs)]


def resolve_tab_info(
    qml_file: Path,
    type_to_index: dict[str, int],
    type_to_label: dict[str, str],
) -> tuple[int | None, str | None, int | None, str | None]:
    """
    Determine the tab index, tab label, sub-tab index, and sub-tab label for a QML file.

    Returns (tab_index, tab_label_key, sub_tab_index, sub_tab_label_key)
    """
    parent = qml_file.parent
    stem = qml_file.stem

    # Top-level tab files (directly in Tabs/)
    if parent == TABS_DIR:
        tab_index = type_to_index.get(stem)
        tab_label = type_to_label.get(stem)
        return tab_index, tab_label, None, None

    # Sub-directory files
    dir_name = parent.name  # e.g. "Audio", "Bar"
    parent_type = f"{dir_name}Tab"  # e.g. "AudioTab"
    tab_index = type_to_index.get(parent_type)
    tab_label = type_to_label.get(parent_type)

    if tab_index is None:
        return None, None, None, None

    # Skip the parent tab file itself (e.g. AudioTab.qml) — still scan for widgets
    if stem.endswith("Tab") and not stem.endswith("SubTab"):
        return tab_index, tab_label, None, None

    # Determine sub-tab index and label from parent tab's NTabBar/NTabView
    parent_tab_file = parent / f"{dir_name}Tab.qml"
    if not parent_tab_file.exists():
        return tab_index, tab_label, None, None

    subtab_names, subtab_labels = get_subtab_info(parent_tab_file)
    try:
        idx = subtab_names.index(stem)
        sub_label = subtab_labels[idx] if idx < len(subtab_labels) else None
        return tab_index, tab_label, idx, sub_label
    except ValueError:
        # File doesn't map to any subtab (e.g. a dialog). If the parent tab
        # has subtabs, the focus ring can't reach widgets inside dialogs, so
        # exclude them from the index.
        if subtab_names:
            return None, None, None, None
        return tab_index, tab_label, None, None


def is_resolvable_condition(cond: str) -> bool:
    """Check if a visibility condition can be resolved at runtime by the shell."""
    # Strip negation for prefix checking
    check = cond.lstrip("!").lstrip(" ").lstrip("(").lstrip(" ")
    return any(check.startswith(p) for p in RESOLVABLE_PREFIXES)


def build_scope_visibility(content: str) -> dict[int, list[str]]:
    """
    For each line number, compute the list of inherited visibility conditions
    from all enclosing QML scopes.

    Tracks brace-depth to maintain a scope stack. When a ``visible:`` property
    is found, it is associated with the innermost scope. The conditions are
    inherited by all lines within that scope.

    Returns: line_number -> list of condition strings
    """
    lines = content.splitlines()
    # Each entry: visibility condition string or None
    scope_stack: list[str | None] = []
    result: dict[int, list[str]] = {}

    for line_num, raw_line in enumerate(lines):
        stripped = raw_line.strip()

        # Record inherited conditions BEFORE processing this line's braces.
        # This means a widget opening on this line inherits from parent scopes,
        # not from its own scope (which hasn't been populated yet).
        result[line_num] = [c for c in scope_stack if c is not None]

        # Process opening braces — push new scopes
        n_opens = stripped.count("{")
        for _ in range(n_opens):
            scope_stack.append(None)

        # Check for visible: property — assign to the innermost scope
        vis_match = RE_VISIBLE.match(stripped)
        if vis_match and scope_stack:
            cond = vis_match.group(1).strip()
            if cond != "true":
                scope_stack[-1] = cond

        # Process closing braces — pop scopes
        n_closes = stripped.count("}")
        for _ in range(n_closes):
            if scope_stack:
                scope_stack.pop()

    return result


def extract_widget_blocks(content: str) -> list[tuple[str, str, int]]:
    """
    Extract (widget_type, block_text, start_line) tuples from QML content.

    Uses brace-depth tracking to capture the full widget block.
    """
    results = []
    lines = content.splitlines()
    i = 0

    while i < len(lines):
        m = RE_WIDGET_OPEN.match(lines[i])
        if m:
            widget_type = m.group(1)
            depth = 0
            block_lines = []
            start_line = i
            j = i

            while j < len(lines):
                line = lines[j]
                block_lines.append(line)
                depth += line.count("{") - line.count("}")
                if depth <= 0:
                    break
                j += 1

            block_text = "\n".join(block_lines)
            results.append((widget_type, block_text, start_line))
            i = j + 1
        else:
            i += 1

    return results


def build_component_file_map() -> dict[str, Path]:
    """Map QML type name -> file for every file under Tabs/."""
    return {path.stem: path for path in TABS_DIR.rglob("*.qml")}


def referenced_components(qml_file: Path, component_files: dict[str, Path]) -> list[Path]:
    """
    Helper components instantiated by qml_file (same directory/subtree).

    Popups and dialogs are skipped on purpose: their fields live in a transient
    overlay the settings focus ring cannot reach, so indexing them produces
    results that cannot be focused.
    """
    refs = []
    content = qml_file.read_text()
    for match in RE_COMPONENT_OPEN.finditer(content):
        type_name = match.group(1)
        if type_name.endswith(HELPER_EXCLUDE_SUFFIXES):
            continue
        ref = component_files.get(type_name)
        if ref is None or ref == qml_file:
            continue
        if ref.parent == qml_file.parent or qml_file.parent in ref.parents:
            refs.append(ref)
    return refs


def build_context_map(
    type_to_index: dict[str, int],
    type_to_label: dict[str, str],
    component_files: dict[str, Path],
) -> dict[Path, tuple[int | None, str | None, int | None, str | None]]:
    """
    Resolve a tab/sub-tab context for helper components too.

    A subtab such as DisplaysSubTab instantiates DisplayOutputInspector; that
    helper has no "SubTab" name of its own, so it inherits the subtab context
    instead of being skipped.
    """
    contexts = {}
    for qml_file in sorted(TABS_DIR.rglob("*.qml")):
        context = resolve_tab_info(qml_file, type_to_index, type_to_label)
        if context[0] is not None:
            contexts[qml_file] = context

    # Prefer sub-tab contexts over parent-tab contexts, then propagate until
    # every referenced helper has a context.
    changed = True
    while changed:
        changed = False
        for qml_file, context in sorted(
            contexts.items(), key=lambda item: item[1][2] is None
        ):
            for ref in referenced_components(qml_file, component_files):
                if ref not in contexts:
                    contexts[ref] = context
                    changed = True
    return contexts


def extract_entries(
    qml_file: Path,
    type_to_index: dict[str, int],
    type_to_label: dict[str, str],
    context_map: dict[Path, tuple[int | None, str | None, int | None, str | None]],
) -> list[dict]:
    """Extract all searchable settings entries from a QML file."""
    context = context_map.get(qml_file)
    if context is None:
        context = resolve_tab_info(qml_file, type_to_index, type_to_label)
    tab_index, tab_label, sub_tab, sub_tab_label = context
    if tab_index is None:
        return []

    content = qml_file.read_text()
    scope_vis = build_scope_visibility(content)
    blocks = extract_widget_blocks(content)
    entries = []

    # Resolve every block's label/text first: a heading is paired with the
    # description text rendered immediately below it.
    block_keys = []
    for widget_type, block, _start_line in blocks:
        match = RE_TEXT.search(block) if widget_type in HEADING_TYPES else RE_LABEL.search(block)
        block_keys.append(match.group(1) if match else None)

    for block_index, (widget_type, block, start_line) in enumerate(blocks):
        if widget_type in HEADING_TYPES:
            label_key = block_keys[block_index]
            if not label_key or not label_key.endswith("-heading"):
                continue
            desc_key = None
            if (
                block_index + 1 < len(blocks)
                and blocks[block_index + 1][0] in HEADING_TYPES
            ):
                candidate = block_keys[block_index + 1]
                if candidate and candidate in (
                    label_key + "-desc",
                    label_key.replace("-heading", "-desc"),
                ):
                    desc_key = candidate
        else:
            label_key = block_keys[block_index]
            if not label_key:
                continue
            desc_key = None
            desc_line = RE_DESCRIPTION_LINE.search(block)
            if desc_line:
                desc_expr = desc_line.group(1)
                # Only the default branch of a conditional describes the
                # control; a state-only branch (e.g. "scanning") or an empty
                # one must not become the search description.
                if "?" in desc_expr and ":" in desc_expr:
                    desc_expr = desc_expr.rsplit(":", 1)[-1]
                tr_keys = re.findall(r'I18n\.tr\("([^"]+)"', desc_expr)
                if tr_keys:
                    desc_key = tr_keys[-1]

        # Collect visibility conditions: ancestor scopes + widget's own visible:
        conditions = list(scope_vis.get(start_line, []))
        widget_vis = re.search(
            r'^\s*visible:\s*(.+?)(?:\s*;)?\s*$', block, re.MULTILINE
        )
        if widget_vis:
            cond = widget_vis.group(1).strip()
            if cond != "true" and cond not in conditions:
                conditions.append(cond)

        # Keep only externally-resolvable conditions
        conditions = [c for c in conditions if is_resolvable_condition(c)]

        entry = {
            "labelKey": label_key,
            "descriptionKey": desc_key,
            "widget": widget_type,
            "tab": tab_index,
            "tabLabel": tab_label,
            "subTab": sub_tab,
        }
        if sub_tab_label is not None:
            entry["subTabLabel"] = sub_tab_label
        if conditions:
            entry["visibleWhen"] = conditions

        entries.append(entry)

    return entries


def main():
    if not TABS_DIR.exists():
        print(f"Error: Tabs directory not found: {TABS_DIR}", file=sys.stderr)
        sys.exit(1)

    settings_content = SETTINGS_DIR / "SettingsContent.qml"
    if not settings_content.exists():
        print(f"Error: SettingsContent.qml not found: {settings_content}", file=sys.stderr)
        sys.exit(1)

    # Build type -> tabsModel index/label mappings from SettingsContent.qml
    content = settings_content.read_text()
    type_to_index, type_to_label = build_tab_mappings(content)

    if not type_to_index:
        print("Error: Could not parse tab model from SettingsContent.qml", file=sys.stderr)
        sys.exit(1)

    print(f"Parsed {len(type_to_index)} tab types from SettingsContent.qml")

    component_files = build_component_file_map()
    context_map = build_context_map(type_to_index, type_to_label, component_files)

    all_entries = []
    seen_labels = set()

    # Scan all QML files in Tabs/ (recursive)
    for qml_file in sorted(TABS_DIR.rglob("*.qml")):
        entries = extract_entries(qml_file, type_to_index, type_to_label, context_map)
        for entry in entries:
            if entry["labelKey"] not in seen_labels:
                seen_labels.add(entry["labelKey"])
                all_entries.append(entry)

    output = json.dumps(all_entries, indent=2)

    if "--check" in sys.argv[1:]:
        current = OUTPUT.read_text() if OUTPUT.exists() else ""
        if current != output:
            print(
                "Settings search index is out of date; run "
                "Scripts/dev/build-settings-search-index.py",
                file=sys.stderr,
            )
            sys.exit(1)
        print(f"Settings search index is up to date ({len(all_entries)} entries)")
        return

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(output)
    print(f"Generated {len(all_entries)} entries -> {OUTPUT}")

if __name__ == "__main__":
    main()
