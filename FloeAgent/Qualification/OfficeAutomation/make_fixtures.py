#!/usr/bin/env python3
"""Deterministic OOXML fixtures for the Office automation qualification host.

Synthetic, content-free packages: no user data, no engine binaries. Written
with fixed ZIP timestamps so the bytes are reproducible.
"""
import pathlib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent / "Fixtures"

WORKBOOK = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>'
)
RELS = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
    'Target="worksheets/sheet1.xml"/>'
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
    'Target="styles.xml"/></Relationships>'
)
STYLES = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<cellXfs count="1"><xf numFmtId="0"/></cellXfs></styleSheet>'
)
CONTENT_TYPES = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/xl/workbook.xml" '
    'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    '<Override PartName="/xl/worksheets/sheet1.xml" '
    'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/styles.xml" '
    'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    "</Types>"
)


def worksheet(sheet_data: str) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        f"<sheetData>{sheet_data}</sheetData></worksheet>"
    )


def write(name: str, sheet_data: str) -> None:
    path = ROOT / name
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for member, body in sorted({
            "[Content_Types].xml": CONTENT_TYPES,
            "xl/workbook.xml": WORKBOOK,
            "xl/_rels/workbook.xml.rels": RELS,
            "xl/styles.xml": STYLES,
            "xl/worksheets/sheet1.xml": worksheet(sheet_data),
        }.items()):
            info = zipfile.ZipInfo(member, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, body)
    print("wrote", path)


ROOT.mkdir(parents=True, exist_ok=True)
# One data row.
write("sheet-source.xlsx", '<row r="1"><c r="A1"><v>1</v></c></row>')
# The same workbook plus one inserted row (the verified automatic copy).
write("sheet-after-two-rows.xlsx",
      '<row r="1"><c r="A1"><v>1</v></c></row><row r="2"><c r="A2"><v>2</v></c></row>')
# A stale SUM cache: the engine would have to recalculate to 6.
write("calc-stale.xlsx",
      '<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>SUM(A1:A3)</f><v>5</v></c></row>'
      '<row r="2"><c r="A2"><v>2</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>')
# The recalculated result.
write("calc-recalculated.xlsx",
      '<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>SUM(A1:A3)</f><v>6</v></c></row>'
      '<row r="2"><c r="A2"><v>2</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>')
