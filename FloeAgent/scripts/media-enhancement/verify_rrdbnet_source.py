#!/usr/bin/env python3
"""Verify the vendored RRDBNet architecture against its pinned upstream source.

This closes the reproducibility review gap where the vendored file named
"BasicSR tag v1.4.2" without a verifiable upstream revision or hash.

The check has three independent parts:

  1. **Source pinning** — the upstream files are fetched from an immutable
     commit (or read from a pre-fetched directory) and their SHA-256 must match
     the constants below. A tag is not enough; the commit is the pin.
  2. **AST equivalence** — every math-bearing function in the vendored file is
     compared, node for node, with the upstream file. Only the documented
     local patches may differ (dropped registry import/decorator, inlined
     `make_layer`/`pixel_unshuffle`, no-op `default_init_weights` shim).
  3. **Numeric equivalence** (with torch; skipped otherwise) — the upstream
     module (imported from the pinned file with a registry stub) and the
     vendored module are built with identical weights and must produce
     bit-identical outputs for scale 2 and scale 4.

Usage:
  python3 verify_rrdbnet_source.py \
      --upstream-dir <dir with basicsr-rrdbnet_arch.py + basicsr-arch_util.py> \
      --vendored rrdbnet_arch.py \
      --converted-copy <work>/basicsr/rrdbnet_arch.py \
      --output evidence/rrdbnet-source-verification.json

  # or fetch the pinned files itself (small, network):
  python3 verify_rrdbnet_source.py --fetch-dir <empty dir> --vendored rrdbnet_arch.py

Exit code 0 = all checks pass; non-zero = a mismatch that must be resolved
before the conversion may be called reproducible.
"""
from __future__ import annotations

import argparse
import ast
import copy
import hashlib
import json
import pathlib
import re
import shutil
import sys
import tempfile
import urllib.request

BASICSR_REPO = "XPixelGroup/BasicSR"
BASICSR_TAG = "v1.4.2"
BASICSR_COMMIT = "651835a1b9d38dbbdaf45750f56906be2364f01a"
BASICSR_RRDBNET_PATH = "basicsr/archs/rrdbnet_arch.py"
BASICSR_ARCH_UTIL_PATH = "basicsr/archs/arch_util.py"
BASICSR_RRDBNET_SHA256 = "6aa8eb3f77e918b90eeff4ebfaf8745abe0c40eb8fcc03abbc1928693d70ab58"
BASICSR_ARCH_UTIL_SHA256 = "45b322b874057c4bff382cc8f1b64554857b9aa4e0c47e73fe67e4afc0b28ac1"

RAW_URL = "https://raw.githubusercontent.com/{repo}/{commit}/{path}"

# The exact set of module-level names the vendored file is allowed to define.
VENDORED_EXPECTED_NAMES = {
    "make_layer",
    "pixel_unshuffle",
    "default_init_weights",
    "ResidualDenseBlock",
    "RRDB",
    "RRDBNet",
}
# Functions that must be node-identical to upstream after docstring removal.
# `ResidualDenseBlock.__init__` is checked separately because its single
# `default_init_weights` call is the documented no-op patch.
FUNCTION_COMPARISONS = [
    ("ResidualDenseBlock.forward", "rrdbnet"),
    ("RRDB.forward", "rrdbnet"),
    ("RRDBNet.forward", "rrdbnet"),
    ("RRDB.__init__", "rrdbnet"),
    ("RRDBNet.__init__", "rrdbnet"),
    ("make_layer", "arch_util"),
    ("pixel_unshuffle", "arch_util"),
]


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: pathlib.Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "floe-media-repro/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        destination.write_bytes(response.read())


def fetch_pinned(directory: pathlib.Path) -> dict[str, pathlib.Path]:
    directory.mkdir(parents=True, exist_ok=True)
    pinned = {
        "rrdbnet": (BASICSR_RRDBNET_PATH, BASICSR_RRDBNET_SHA256, directory / "basicsr-rrdbnet_arch.py"),
        "arch_util": (BASICSR_ARCH_UTIL_PATH, BASICSR_ARCH_UTIL_SHA256, directory / "basicsr-arch_util.py"),
    }
    resolved: dict[str, pathlib.Path] = {}
    for key, (path, expected, destination) in pinned.items():
        if not destination.exists():
            download(RAW_URL.format(repo=BASICSR_REPO, commit=BASICSR_COMMIT, path=path), destination)
        digest = sha256(destination)
        if digest != expected:
            raise SystemExit(f"pinned upstream {path} sha256 mismatch: {digest} != {expected}")
        resolved[key] = destination
    return resolved


def _function_map(tree: ast.Module) -> dict[str, ast.AST]:
    functions: dict[str, ast.AST] = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            functions[node.name] = node
        elif isinstance(node, ast.ClassDef):
            for child in node.body:
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    functions[f"{node.name}.{child.name}"] = child
    return functions


def _without_docstring(node: ast.AST) -> ast.AST:
    node = copy.deepcopy(node)
    if getattr(node, "body", None) and isinstance(node.body[0], ast.Expr):
        value = node.body[0].value
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            node.body = node.body[1:]
    return node


def _remove_default_init_call(node: ast.AST) -> tuple[ast.AST, int]:
    """Remove the single `default_init_weights([...], 0.1)` line from
    ResidualDenseBlock.__init__ (documented patch). Returns the count removed."""
    node = copy.deepcopy(node)
    kept = []
    removed = 0
    for statement in node.body:
        if (
            isinstance(statement, ast.Expr)
            and isinstance(statement.value, ast.Call)
            and isinstance(statement.value.func, ast.Name)
            and statement.value.func.id == "default_init_weights"
        ):
            removed += 1
            continue
        kept.append(statement)
    node.body = kept
    return node, removed


def _dump(node: ast.AST) -> str:
    return ast.dump(node, annotate_fields=False, include_attributes=False)


def ast_checks(vendored_source: str, upstream_rrdbnet: str, upstream_arch_util: str) -> dict:
    vendored = _function_map(ast.parse(vendored_source))
    upstream_main = _function_map(ast.parse(upstream_rrdbnet))
    upstream_util = _function_map(ast.parse(upstream_arch_util))

    results: dict[str, object] = {}
    failures: list[str] = []

    vendored_tree = ast.parse(vendored_source)
    module_names = {
        node.name for node in vendored_tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
    }
    if module_names != VENDORED_EXPECTED_NAMES:
        failures.append(f"vendored module defines unexpected names: {sorted(module_names ^ VENDORED_EXPECTED_NAMES)}")

    for name, origin in FUNCTION_COMPARISONS:
        expected = upstream_main[name] if origin == "rrdbnet" else upstream_util[name]
        actual = vendored.get(name)
        if actual is None:
            failures.append(f"{name}: missing in vendored file")
            results[name] = "missing"
            continue
        if _dump(_without_docstring(actual)) == _dump(_without_docstring(expected)):
            results[name] = "identical (docstring-insensitive AST)"
        else:
            failures.append(f"{name}: AST differs from upstream")
            results[name] = "DIFFERS"

    # The ResidualDenseBlock.__init__ patch: upstream calls the random
    # initializer once; the vendored copy drops that call (the shim is a no-op
    # because the conversion always loads the pinned checkpoint). Everything
    # else must be identical.
    block_init = vendored.get("ResidualDenseBlock.__init__")
    expected_block_init = upstream_main.get("ResidualDenseBlock.__init__")
    if block_init is None or expected_block_init is None:
        failures.append("ResidualDenseBlock.__init__: missing on one side")
        results["ResidualDenseBlock.__init__"] = "missing"
    else:
        upstream_normalized, removed = _remove_default_init_call(_without_docstring(expected_block_init))
        if removed != 1:
            failures.append(f"upstream ResidualDenseBlock.__init__ no longer has exactly 1 initializer call (found {removed})")
            results["ResidualDenseBlock.__init__"] = "unexpected upstream initializer count"
        elif _dump(_without_docstring(block_init)) == _dump(upstream_normalized):
            results["ResidualDenseBlock.__init__"] = "identical after removing the single upstream default_init_weights call"
        else:
            failures.append("ResidualDenseBlock.__init__: differs beyond the documented patch")
            results["ResidualDenseBlock.__init__"] = "DIFFERS beyond documented patch"

    # The vendored __init__ patches above are only safe because the conversion
    # always loads the pinned checkpoint. Verify the shim is a real no-op.
    shim = vendored.get("default_init_weights")
    if shim is None:
        failures.append("default_init_weights: missing in vendored file")
    else:
        calls = [n for n in ast.walk(shim) if isinstance(n, ast.Call)]
        if len(calls) != 0:
            failures.append("default_init_weights shim contains calls; expected a pure no-op")
        results["default_init_weights"] = "documented no-op shim (0 calls); upstream initializer has no effect on a loaded checkpoint"

    # Also compare the class-level structure for the two classes whose
    # __init__ bodies were compared method-wise above.
    for class_name in ("ResidualDenseBlock", "RRDB", "RRDBNet"):
        upstream_methods = {n.split(".", 1)[1] for n in upstream_main if n.startswith(class_name + ".")}
        vendored_methods = {n.split(".", 1)[1] for n in vendored if n.startswith(class_name + ".")}
        if upstream_methods != vendored_methods:
            failures.append(f"{class_name}: method set differs: {sorted(upstream_methods ^ vendored_methods)}")
    return {"results": results, "failures": failures}


def numeric_check(vendored_path: pathlib.Path, upstream: dict[str, pathlib.Path]) -> dict:
    try:
        import torch  # noqa: F401
    except Exception as error:  # pragma: no cover - exercised when torch is absent
        return {"status": "skipped", "reason": f"torch unavailable: {error}"}

    import torch

    with tempfile.TemporaryDirectory(prefix="rrdbnet-cmp-") as temporary:
        root = pathlib.Path(temporary)
        package = root
        (package / "basicsr" / "utils").mkdir(parents=True)
        (package / "basicsr" / "archs").mkdir(parents=True)
        (package / "basicsr" / "__init__.py").write_text("")
        (package / "basicsr" / "utils" / "__init__.py").write_text("")
        (package / "basicsr" / "archs" / "__init__.py").write_text("")
        (package / "basicsr" / "utils" / "registry.py").write_text(
            "class _Registry:\n"
            "    def register(self, *args, **kwargs):\n"
            "        def wrap(cls):\n"
            "            return cls\n"
            "        return wrap\n"
            "ARCH_REGISTRY = _Registry()\n"
        )
        shutil.copyfile(upstream["rrdbnet"], package / "basicsr" / "archs" / "rrdbnet_arch.py")

        # Import isolation: the upstream arch_util pulls torchvision/DCN/logging
        # that the architecture comparison does not need. Extract the three
        # hash-verified upstream functions verbatim (AST unparse) so the
        # upstream module imports exactly the pinned helper source.
        util_tree = ast.parse(upstream["arch_util"].read_text())
        wanted = {"default_init_weights", "make_layer", "pixel_unshuffle"}
        extracted = [ast.unparse(node) for node in util_tree.body
                     if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in wanted]
        if {node.name for node in util_tree.body
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))} & wanted != wanted:
            raise SystemExit("could not extract pinned arch_util helpers")
        (package / "basicsr" / "archs" / "arch_util.py").write_text(
            "# Extracted verbatim (ast.unparse) from the SHA-256-verified pinned\n"
            "# BasicSR arch_util.py for import isolation only.\n"
            "import torch\n"
            "from torch import nn as nn\n"
            "from torch.nn import init as init\n"
            "from torch.nn.modules.batchnorm import _BatchNorm\n\n"
            + "\n\n".join(extracted) + "\n"
        )
        shutil.copyfile(vendored_path, package / "floe_rrdbnet.py")

        sys.path.insert(0, str(root))
        try:
            import importlib

            upstream_module = importlib.import_module("basicsr.archs.rrdbnet_arch")
            vendored_module = importlib.import_module("floe_rrdbnet")

            comparisons: dict[str, object] = {}
            failures: list[str] = []
            for scale in (2, 4):
                torch.manual_seed(1234 + scale)
                reference = upstream_module.RRDBNet(
                    num_in_ch=3, num_out_ch=3, scale=scale, num_feat=8, num_block=3, num_grow_ch=4
                ).eval()
                candidate = vendored_module.RRDBNet(
                    num_in_ch=3, num_out_ch=3, scale=scale, num_feat=8, num_block=3, num_grow_ch=4
                ).eval()
                candidate.load_state_dict(reference.state_dict())
                torch.manual_seed(7 + scale)
                sample = torch.rand(1, 3, 16, 16)
                with torch.no_grad():
                    expected = reference(sample)
                    observed = candidate(sample)
                exact = bool(torch.equal(expected, observed))
                max_diff = float((expected - observed).abs().max().item())
                comparisons[f"scale{scale}"] = {
                    "bitExact": exact,
                    "maxAbsDiff": max_diff,
                    "outputShape": list(expected.shape),
                }
                if not exact:
                    failures.append(f"scale {scale}: outputs differ (maxAbsDiff={max_diff})")
            return {"status": "pass" if not failures else "fail", "comparisons": comparisons, "failures": failures}
        finally:
            sys.path.remove(str(root))
            for name in ("basicsr.archs.rrdbnet_arch", "floe_rrdbnet",
                         "basicsr.archs.arch_util", "basicsr.archs", "basicsr.utils.registry",
                         "basicsr.utils", "basicsr"):
                sys.modules.pop(name, None)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream-dir", help="directory with basicsr-rrdbnet_arch.py and basicsr-arch_util.py")
    parser.add_argument("--fetch-dir", help="fetch the pinned upstream files into this directory")
    parser.add_argument("--vendored", required=True, help="vendored rrdbnet_arch.py to verify")
    parser.add_argument("--converted-copy", help="optional: file actually imported by the conversion run")
    parser.add_argument("--output", help="write the JSON verification result here")
    parser.add_argument("--expect-converted-copy-same", action="store_true",
                        help="fail if --converted-copy is not byte-identical to the pinned upstream file")
    args = parser.parse_args()

    if bool(args.upstream_dir) == bool(args.fetch_dir):
        parser.error("pass exactly one of --upstream-dir or --fetch-dir")

    if args.fetch_dir:
        upstream = fetch_pinned(pathlib.Path(args.fetch_dir).resolve())
    else:
        directory = pathlib.Path(args.upstream_dir).resolve()
        upstream = {
            "rrdbnet": directory / "basicsr-rrdbnet_arch.py",
            "arch_util": directory / "basicsr-arch_util.py",
        }
        for key, path in upstream.items():
            if not path.exists():
                raise SystemExit(f"missing upstream file: {path}")
    expected = {
        "rrdbnet": BASICSR_RRDBNET_SHA256,
        "arch_util": BASICSR_ARCH_UTIL_SHA256,
    }
    source_hashes = {}
    for key, path in upstream.items():
        digest = sha256(path)
        source_hashes[key] = {"path": str(path), "sha256": digest}
        if digest != expected[key]:
            raise SystemExit(f"{path} is not the pinned {BASICSR_TAG} file: {digest} != {expected[key]}")

    vendored_path = pathlib.Path(args.vendored).resolve()
    vendored_source = vendored_path.read_text()
    vendored_hash = hashlib.sha256(vendored_source.encode()).hexdigest()

    ast_result = ast_checks(vendored_source, upstream["rrdbnet"].read_text(), upstream["arch_util"].read_text())
    numeric_result = numeric_check(vendored_path, upstream)

    converted = None
    converted_failures: list[str] = []
    if args.converted_copy:
        converted_path = pathlib.Path(args.converted_copy).resolve()
        if converted_path.exists():
            converted = {"path": str(converted_path), "sha256": sha256(converted_path)}
            if sha256(converted_path) != BASICSR_RRDBNET_SHA256:
                converted_failures.append("converted copy differs from the pinned upstream file")
        else:
            converted = {"path": str(converted_path), "status": "missing"}
            if args.expect_converted_copy_same:
                converted_failures.append("converted copy missing")

    failures = ast_result["failures"] + numeric_result.get("failures", []) + converted_failures
    report = {
        "upstream": {
            "repo": BASICSR_REPO,
            "tag": BASICSR_TAG,
            "commit": BASICSR_COMMIT,
            "files": source_hashes,
        },
        "vendored": {"path": str(vendored_path), "sha256": vendored_hash},
        "convertedCopy": converted,
        "localPatches": [
            "dropped `basicsr.utils.registry` import and @ARCH_REGISTRY.register() decorator",
            "inlined make_layer and pixel_unshuffle from the pinned basicsr/archs/arch_util.py",
            "dropped the ResidualDenseBlock.__init__ initializer call and kept a documented no-op default_init_weights shim (the pinned checkpoint is always loaded, so random initialization never reaches the conversion)",
            "string quote style/docstrings normalized; no math changes",
        ],
        "ast": ast_result,
        "numeric": numeric_result,
        "failures": failures,
        "pass": not failures,
    }
    if args.output:
        output = pathlib.Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))
    if failures:
        print(f"FAILED: {len(failures)} check(s)", file=sys.stderr)
        return 1
    print("PASS: vendored RRDBNet matches pinned upstream source and math", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
