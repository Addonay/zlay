#!/usr/bin/env python3
"""Static public-surface audit: pinned Taffy (Rust) vs the extracted Zig port.

This is deliberately heuristic. It extracts declaration names from Rust and Zig
sources without a full parser and diffs them per source-mapped file. It is a
navigation aid for the human audit (report.md), not a semantic equivalence
proof. Every "missing" row must be confirmed by reading the code.

Usage:
    python3 tools/api_audit.py [--json] [--write FILE]

Exit status is 0 even when gaps are found; gaps are expected. A non-zero exit
means the audit itself failed (e.g. missing reference checkout).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ZIG_SRC = ROOT / "src"
TAFFY_SRC = ROOT / ".references" / "taffy" / "src"

# ---------------------------------------------------------------------------
# Rust extraction
# ---------------------------------------------------------------------------

RE_RUST_ITEM = re.compile(
    r"^\s*pub\s+(?:const\s+|unsafe\s+|async\s+|extern\s+\"[^\"]*\"\s+)*"
    r"(fn|struct|enum|trait|type|mod|const|static)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
# `pub use foo::Bar;` / `pub use foo::{a, b};`
RE_RUST_USE = re.compile(r"^\s*pub\s+use\s+(.+?);")
RE_RUST_FN = re.compile(
    r"^\s*pub\s+(?:const\s+|unsafe\s+|async\s+|extern\s+\"[^\"]*\"\s+)*fn\s+([A-Za-z_][A-Za-z0-9_]*)"
)
RE_RUST_ANY_FN = re.compile(
    r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:const\s+|unsafe\s+|async\s+|extern\s+\"[^\"]*\"\s+)*fn\s+([A-Za-z_][A-Za-z0-9_]*)"
)
RE_RUST_VARIANT = re.compile(r"^\s*([A-Z][A-Za-z0-9_]*)\s*(?:[({=,]|$)")
RE_RUST_FIELD = re.compile(r"^\s*pub\s+([a-z_][A-Za-z0-9_]*)\s*:")


def strip_rust_comments(text: str) -> str:
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        out.append(line)
    return "\n".join(out)


def rust_block(text: str, start: int) -> tuple[str, int]:
    """Return (block_body, index_after_closing_brace) starting at the first `{`."""
    brace = text.find("{", start)
    if brace == -1:
        return "", len(text)
    depth = 0
    i = brace
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : i], i + 1
        i += 1
    return text[brace + 1 :], len(text)


def extract_rust(path: Path) -> dict:
    raw = strip_rust_comments(path.read_text(errors="replace"))
    # Unit tests live at the bottom of most Taffy modules behind `#[cfg(test)]`.
    # They are not part of the ported production surface; count them separately.
    production = raw.split("#[cfg(test)]", 1)[0]
    test_fn_count = len(re.findall(r"#\[test\]\s*\n\s*fn\s", raw))
    text = production
    lines = text.splitlines()
    items: list[str] = []
    all_fns: list[str] = []
    types: dict[str, dict] = {}
    uses: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = RE_RUST_ITEM.match(line)
        if m and m.group(1) in ("fn", "struct", "enum", "trait", "type", "mod", "const", "static"):
            kind, name = m.group(1), m.group(2)
            if kind in ("struct", "enum"):
                body, end = rust_block(text, text.index(line) + len(line))
                members: list[str] = []
                for body_line in body.splitlines():
                    if kind == "enum":
                        vm = RE_RUST_VARIANT.match(body_line)
                        if vm:
                            members.append(vm.group(1))
                    else:
                        fm = RE_RUST_FIELD.match(body_line)
                        if fm:
                            members.append(fm.group(1))
                types[name] = {"kind": kind, "members": members}
                line = text[end:].split("\n", 1)[0] if end < len(text) else ""
                lines = text.splitlines()
                # continue scanning from the line after the block
                consumed = text[:end].count("\n")
                i = consumed + 1
                items.append(f"{kind} {name}")
                continue
            items.append(f"{kind} {name}")
            if kind == "fn" and name not in items:
                pass
        fm = RE_RUST_FN.match(line)
        if fm:
            items.append(f"fn {fm.group(1)}")
        afm = RE_RUST_ANY_FN.match(line)
        if afm:
            all_fns.append(afm.group(1))
        um = RE_RUST_USE.match(line)
        if um:
            uses.append(um.group(1).strip())
        i += 1
    # `impl` blocks: collect public methods and associated items.
    for im in re.finditer(r"^impl(?:<[^>]*>)?\s+([A-Za-z_][A-Za-z0-9_:]*)", text, re.M):
        pass
    return {
        "items": sorted(set(items)),
        "all_fns": sorted(set(all_fns)),
        "types": types,
        "uses": sorted(set(uses)),
        "test_fns": test_fn_count,
    }


# ---------------------------------------------------------------------------
# Zig extraction
# ---------------------------------------------------------------------------

RE_ZIG_FN = re.compile(r"^\s*pub\s+(?:inline\s+|export\s+|extern\s+)*fn\s+([A-Za-z_][A-Za-z0-9_]*)")
RE_ZIG_ANY_FN = re.compile(r"^\s*(?:pub\s+)?(?:inline\s+|export\s+|extern\s+)*fn\s+([A-Za-z_][A-Za-z0-9_]*)")
RE_ZIG_CONST = re.compile(r"^\s*pub\s+const\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::|=)")
RE_ZIG_VAR = re.compile(r"^\s*pub\s+var\s+([A-Za-z_][A-Za-z0-9_]*)")
RE_ZIG_USING = re.compile(r"^\s*pub\s+usingnamespace\s+([A-Za-z_][A-Za-z0-9_.]*)")


def zig_block(text: str, brace: int) -> tuple[str, int]:
    depth = 0
    i = brace
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : i], i + 1
        i += 1
    return text[brace + 1 :], len(text)


def extract_zig(path: Path) -> dict:
    text = path.read_text(errors="replace")
    items: list[str] = []
    all_fns: list[str] = []
    types: dict[str, dict] = {}
    # Find `pub const Name = struct|enum|union|opaque {`.
    for m in re.finditer(
        r"pub\s+const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(struct|enum|union|opaque)\s*(\([^)]*\))?\s*\{",
        text,
    ):
        name, kind = m.group(1), m.group(2)
        body, _ = zig_block(text, m.end() - 1)
        members: list[str] = []
        for body_line in body.splitlines():
            stripped = body_line.strip()
            if not stripped or stripped.startswith("//"):
                continue
            if stripped.startswith(("pub ", "const ", "var ", "fn ", "comptime", "test ", "_ =", "switch", "if ", "for ", "return", "}", "usingnamespace")):
                continue
            if "=>" in stripped or stripped.startswith("."):
                continue
            mm = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(?::|,|=)", stripped)
            if mm and mm.group(1) not in ("orelse",):
                members.append(mm.group(1))
        types[name] = {"kind": kind, "members": members}
        items.append(f"type {name}")
    for line in text.splitlines():
        fm = RE_ZIG_FN.match(line)
        any_fm = RE_ZIG_ANY_FN.match(line)
        if any_fm:
            all_fns.append(any_fm.group(1))
        if fm:
            items.append(f"fn {fm.group(1)}")
            continue
        cm = RE_ZIG_CONST.match(line)
        if cm:
            items.append(f"const {cm.group(1)}")
            continue
        vm = RE_ZIG_VAR.match(line)
        if vm:
            items.append(f"var {vm.group(1)}")
        um = RE_ZIG_USING.match(line)
        if um:
            items.append(f"use {um.group(1)}")
    return {
        "items": sorted(set(items)),
        "all_fns": sorted(set(all_fns)),
        "types": types,
        "test_fns": len(re.findall(r"(?m)^test\b", text)),
    }


# ---------------------------------------------------------------------------
# Mapping + diff
# ---------------------------------------------------------------------------


def rust_to_zig(rel: Path) -> Path:
    if rel.name == "lib.rs":
        return ZIG_SRC / "root.zig"
    if rel.name == "prelude.rs":
        return ZIG_SRC / "prelude.zig"
    if rel.name == "mod.rs":
        return ZIG_SRC / rel.parent / "mod.zig"
    return ZIG_SRC / rel.with_suffix(".zig")


def normalize_rust_item(item: str) -> str:
    return item


def diff_file(rust: dict, zig: dict) -> dict:
    rust_types = rust["types"]
    zig_types = zig["types"]
    zig_items = set(zig["items"])
    zig_item_names = {re.sub(r"^(fn|const|var|type|enum|struct)\s+", "", i) for i in zig_items}

    missing_types = []
    type_gaps = []
    for name, info in sorted(rust_types.items()):
        if name not in zig_types:
            missing_types.append(f"{info['kind']} {name}")
            continue
        zig_members = set(zig_types[name]["members"])
        missing_members = [m for m in info["members"] if m not in zig_members]
        if missing_members:
            type_gaps.append(
                {
                    "type": name,
                    "kind": info["kind"],
                    "missing_members": missing_members,
                    "rust_member_count": len(info["members"]),
                    "zig_member_count": len(zig_types[name]["members"]),
                }
            )

    missing_items = []
    for item in rust["items"]:
        if item.startswith(("struct ", "enum ")):
            continue  # handled by type comparison
        kind, _, name = item.partition(" ")
        if name in zig_item_names:
            continue
        # Rust `mod x` maps to `pub const x = @import(...)`.
        missing_items.append(item)

    zig_all_fns = set(zig["all_fns"])
    missing_fns = [f for f in rust["all_fns"] if f not in zig_all_fns]

    extra_zig = sorted(
        i
        for i in zig["items"]
        if i.startswith("fn ")
        and i.removeprefix("fn ") not in {r.partition(" ")[2] for r in rust["items"]}
    )

    return {
        "missing_items": missing_items,
        "missing_types": missing_types,
        "missing_all_fns": missing_fns,
        "type_gaps": type_gaps,
        "extra_zig_functions": extra_zig,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--write", metavar="FILE")
    args = parser.parse_args()

    if not TAFFY_SRC.is_dir():
        print(f"error: missing Taffy reference at {TAFFY_SRC}", file=sys.stderr)
        print("run tools/fetch-reference.sh first", file=sys.stderr)
        return 2

    report: dict = {
        "taffy_src": str(TAFFY_SRC),
        "zig_src": str(ZIG_SRC),
        "files": [],
        "totals": {
            "rust_files": 0,
            "zig_files": 0,
            "rust_lines": 0,
            "zig_lines": 0,
            "missing_items": 0,
            "missing_types": 0,
            "missing_members": 0,
            "missing_functions": 0,
            "rust_test_fns": 0,
            "zig_test_fns": 0,
        },
    }

    rust_files = sorted(TAFFY_SRC.rglob("*.rs"))
    for rust_path in rust_files:
        rel = rust_path.relative_to(TAFFY_SRC)
        zig_path = rust_to_zig(rel)
        entry: dict = {
            "rust": str(rel),
            "zig": str(zig_path.relative_to(ROOT)),
        }
        rust_lines = len(rust_path.read_text(errors="replace").splitlines())
        entry["rust_lines"] = rust_lines
        report["totals"]["rust_files"] += 1
        report["totals"]["rust_lines"] += rust_lines
        if not zig_path.exists():
            entry["status"] = "missing-file"
            report["files"].append(entry)
            continue
        entry["status"] = "present"
        zig_lines = len(zig_path.read_text(errors="replace").splitlines())
        entry["zig_lines"] = zig_lines
        report["totals"]["zig_files"] += 1
        report["totals"]["zig_lines"] += zig_lines

        rust = extract_rust(rust_path)
        zig = extract_zig(zig_path)
        entry["rust_items"] = len(rust["items"])
        entry["zig_items"] = len(zig["items"])
        entry["rust_test_fns"] = rust["test_fns"]
        entry["zig_test_fns"] = zig["test_fns"]
        report["totals"]["rust_test_fns"] += rust["test_fns"]
        report["totals"]["zig_test_fns"] += zig["test_fns"]
        d = diff_file(rust, zig)
        entry.update(d)
        report["totals"]["missing_items"] += len(d["missing_items"])
        report["totals"]["missing_types"] += len(d["missing_types"])
        report["totals"]["missing_members"] += sum(
            len(g["missing_members"]) for g in d["type_gaps"]
        )
        report["totals"]["missing_functions"] += len(d["missing_all_fns"])
        report["files"].append(entry)

    if args.json:
        output = json.dumps(report, indent=2)
    else:
        lines = []
        lines.append("# Static public-surface audit")
        lines.append("")
        lines.append(
            f"Pinned Taffy: `{TAFFY_SRC}`; port: `{ZIG_SRC}`. "
            f"Rust: {report['totals']['rust_files']} files / {report['totals']['rust_lines']} lines. "
            f"Zig: {report['totals']['zig_files']} files / {report['totals']['zig_lines']} lines."
        )
        lines.append("")
        lines.append(
            f"Names absent from Zig (production code only): {report['totals']['missing_items']} items, "
            f"{report['totals']['missing_types']} types, "
            f"{report['totals']['missing_members']} type members (fields/variants), "
            f"{report['totals']['missing_functions']} functions (public or private)."
        )
        lines.append("")
        lines.append(
            f"Unit tests in the same files: Taffy {report['totals']['rust_test_fns']} `#[test]` fns vs "
            f"port {report['totals']['zig_test_fns']} `test` blocks "
            "(the port also has tests in files Taffy keeps untested)."
        )
        lines.append("")
        for entry in report["files"]:
            if entry["status"] == "missing-file":
                lines.append(f"## `{entry['rust']}` -> MISSING FILE")
                lines.append("")
                continue
            if (
                not entry["missing_items"]
                and not entry["missing_types"]
                and not entry["type_gaps"]
                and not entry["missing_all_fns"]
            ):
                continue
            lines.append(
                f"## `{entry['rust']}` -> `{entry['zig']}` "
                f"({entry['rust_lines']} Rust / {entry['zig_lines']} Zig lines; "
                f"tests {entry.get('rust_test_fns', 0)}/{entry.get('zig_test_fns', 0)})"
            )
            lines.append("")
            if entry["missing_types"]:
                lines.append("**Types not found in Zig**")
                lines.append("")
                for t in entry["missing_types"]:
                    lines.append(f"- `{t}`")
                lines.append("")
            if entry["type_gaps"]:
                lines.append("**Types with missing members (fields/variants)**")
                lines.append("")
                for gap in entry["type_gaps"]:
                    members = ", ".join(f"`{m}`" for m in gap["missing_members"])
                    lines.append(
                        f"- `{gap['type']}` ({gap['kind']}): {members} "
                        f"[Rust {gap['rust_member_count']} / Zig {gap['zig_member_count']}]"
                    )
                lines.append("")
            if entry["missing_items"]:
                lines.append("**Declarations not found in Zig**")
                lines.append("")
                for item in entry["missing_items"]:
                    lines.append(f"- `{item}`")
                lines.append("")
            if entry["missing_all_fns"]:
                lines.append("**Functions not found in Zig**")
                lines.append("")
                for fn in entry["missing_all_fns"]:
                    lines.append(f"- `{fn}`")
                lines.append("")
        output = "\n".join(lines)

    if args.write:
        Path(args.write).write_text(output)
    else:
        print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
