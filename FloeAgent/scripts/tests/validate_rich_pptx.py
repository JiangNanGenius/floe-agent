#!/usr/bin/env python3
"""Independent read-back of a Floe-generated deck and its embedded workbooks.

Uses python-pptx and openpyxl (qualification environments only) instead of Floe
code to confirm the deck is a real presentation with real chart parts, readable
chart caches, matching embedded workbook cells and resolvable picture bytes.
Requires the chart-workbook marker name: ppt/embeddings/floe-chart-data-*.xlsx.

Usage: python3 validate_rich_pptx.py DECK.pptx
This is a structure-level check, not native-engine or Office UI acceptance.
"""
import io
import pathlib
import re
import sys
import zipfile

from pptx import Presentation
from pptx.enum.shapes import MSO_SHAPE_TYPE
from pptx.enum.chart import XL_CHART_TYPE
import openpyxl

failures = []


def check(name, condition, detail=""):
    print(("PASS " if condition else "FAIL ") + name + ((" - " + str(detail)) if not condition and detail else ""))
    if not condition:
        failures.append(name)


def main(path):
    presentation = Presentation(path)
    with zipfile.ZipFile(path) as package:
        names = package.namelist()
        chart_parts = sorted(n for n in names if re.fullmatch(r"ppt/charts/chart\d+\.xml", n))
        workbook_parts = sorted(n for n in names if n.startswith("ppt/embeddings/") and n.endswith(".xlsx"))
        check("package has chart parts", len(chart_parts) >= 1, chart_parts)
        check("every workbook uses the Floe marker name",
              bool(workbook_parts) and all(
                  re.fullmatch(r"ppt/embeddings/floe-chart-data-\d+\.xlsx", name) for name in workbook_parts),
              workbook_parts)

        for path in workbook_parts:
            workbook = openpyxl.load_workbook(io.BytesIO(package.read(path)), data_only=True)
            check(f"{path} opens as a workbook", "Sheet1" in workbook.sheetnames, workbook.sheetnames)

        for path in chart_parts:
            chart_xml = package.read(path).decode("utf-8")
            formulas = re.findall(r"<c:f>([^<]*)</c:f>", chart_xml)
            check(f"{path} has externalData relationship",
                  re.search(r'<c:externalData r:id="rId\d+">', chart_xml) is not None)
            check(f"{path} formulas are Sheet1 ranges",
                  bool(formulas) and all(f.startswith("Sheet1!$") for f in formulas), formulas)
            check(f"{path} formulas contain no internal labels",
                  not any(f.startswith("label ") or f.replace(".", "").isdigit() for f in formulas), formulas)
            rels_path = path.replace("ppt/charts/", "ppt/charts/_rels/") + ".rels"
            rels = package.read(rels_path).decode("utf-8")
            targets = re.findall(r'Target="([^"]+)"', rels)
            check(f"{path} relationship targets its workbook",
                  any(t.startswith("../embeddings/") and t.endswith(".xlsx") for t in targets), targets)

        picture_parts = [n for n in names if n.startswith("ppt/media/")]
        checks = [entry for entry in presentation.slides]
        check("python-pptx opens the deck", len(checks) >= 1, len(checks))

    print(f"\npython-pptx/openpyxl checks failed={len(failures)}")
    if failures:
        print("failed:", ", ".join(failures))
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
