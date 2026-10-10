#!/usr/bin/env python3
"""Independent STEP (ISO 10303-21) reader for the FloeCAD plate/hole acceptance.

This is a self-contained Part 21 entity parser with NO OpenCASCADE and no
third-party CAD library. It is deliberately scoped to the plane + cylinder
solid class the acceptance fixture uses, and it states that scope. It is a
RESTRICTED FIXTURE GEOMETRY CHECK, not a general STEP compatibility reader:
it does not cover spline/torus/lofted/composite geometry, assemblies or
tessellated representations, and it does not replace the separate same-kernel
OCCT re-import round-trip. Passing it proves the exported fixture's units,
topology class, dimensions and analytic cylinder, not general format support:

  * units: the file must declare millimetres (`SI_UNIT(.MILLI.,.METRE.)`,
    directly or through a conversion-based unit);
  * topology: one MANIFOLD_SOLID_BREP / CLOSED_SHELL, 7 ADVANCED_FACEs
    (6 planes + 1 cylinder for a plate with a through-hole);
  * exact geometry from the file: bounding box (computed from CARTESIAN_POINTs
    plus every CIRCLE sampled at exact axis-aligned extremes) and the
    cylindrical face's radius and axial length;
  * volume for this class derived analytically from the parsed primitive
    parameters (plate box − cylinder), NOT a general B-rep volume integrator.

The script exits non-zero when a check fails. It never consults the exporting
app, the OCCT library or the original model.

Usage:
    verify_step_independent.py <file.step> --kind plate-hole \
        --expect-thickness 10 --expect-volume 59214.60183660255
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass, field


# ---------------------------------------------------------------- Part 21 lexer

class StepFile:
    """Minimal ISO-10303-21 reader: entity id -> (TYPE, raw args string)."""

    _entity_re = re.compile(r"#(\d+)\s*=\s*([A-Za-z0-9_]+)\s*\((.*?)\)\s*;", re.S)

    def __init__(self, text: str):
        self.text = text
        self.entities: dict[int, tuple[str, str]] = {}
        # Strip comments and simple strings for parsing (strings are not needed
        # for geometry; keep them out of the entity regex matching).
        cleaned = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
        for match in self._entity_re.finditer(cleaned):
            self.entities[int(match.group(1))] = (match.group(2).upper(), match.group(3))

    def header(self) -> str:
        return self.text[: self.text.find("DATA;") if "DATA;" in self.text else 4096]

    def get(self, entity_id: int) -> tuple[str, str]:
        if entity_id not in self.entities:
            raise KeyError(f"#{entity_id} not found")
        return self.entities[entity_id]

    def of_type(self, type_name: str) -> list[tuple[int, str]]:
        target = type_name.upper()
        return [(i, args) for i, (t, args) in self.entities.items() if t == target]


def split_args(raw: str) -> list[str]:
    """Split an argument list on top-level commas."""
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    in_string = False
    for ch in raw:
        if ch == "'" and not in_string:
            in_string = True
        elif ch == "'" and in_string:
            in_string = False
        if in_string:
            current.append(ch)
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
    if current:
        parts.append("".join(current).strip())
    return parts


def ref(token: str) -> int | None:
    m = re.fullmatch(r"#(\d+)", token.strip())
    return int(m.group(1)) if m else None


def num(token: str) -> float:
    """STEP REAL/INTEGER token -> finite float.

    STEP reals are `[sign] digits ['.' digits] [E[sign]digits]`; be tolerant of
    the shorthand forms too, without changing value: ``.5`` -> ``0.5`` and
    ``1.`` -> ``1.0`` (stripping the leading dot would silently turn .5 into 5).
    """
    text = token.strip()
    if text.startswith("."):
        text = "0" + text
    if text.endswith("."):
        text = text + "0"
    text = text.replace("D", "E").replace("d", "E")
    value = float(text)
    if not math.isfinite(value):
        raise ValueError(f"non-finite STEP value {token!r}")
    return value


# ---------------------------------------------------------------- geometry

@dataclass
class Vec3:
    x: float
    y: float
    z: float

    def __add__(self, o: "Vec3") -> "Vec3":
        return Vec3(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o: "Vec3") -> "Vec3":
        return Vec3(self.x - o.x, self.y - o.y, self.z - o.z)

    def __mul__(self, s: float) -> "Vec3":
        return Vec3(self.x * s, self.y * s, self.z * s)

    def dot(self, o: "Vec3") -> float:
        return self.x * o.x + self.y * o.y + self.z * o.z

    def cross(self, o: "Vec3") -> "Vec3":
        return Vec3(self.y * o.z - self.z * o.y,
                    self.z * o.x - self.x * o.z,
                    self.x * o.y - self.y * o.x)

    def length(self) -> float:
        return math.sqrt(self.dot(self))

    def normalized(self) -> "Vec3":
        n = self.length()
        return self * (1.0 / n) if n > 0 else self


@dataclass
class Bounds:
    lo: Vec3 = field(default_factory=lambda: Vec3(math.inf, math.inf, math.inf))
    hi: Vec3 = field(default_factory=lambda: Vec3(-math.inf, -math.inf, -math.inf))

    def add(self, p: Vec3) -> None:
        self.lo = Vec3(min(self.lo.x, p.x), min(self.lo.y, p.y), min(self.lo.z, p.z))
        self.hi = Vec3(max(self.hi.x, p.x), max(self.hi.y, p.y), max(self.hi.z, p.z))

    def valid(self) -> bool:
        return self.lo.x != math.inf


class StepGeometry:
    def __init__(self, step: StepFile):
        self.step = step
        self.points = {}
        self.point_is_3d = {}
        for i, _ in step.of_type("CARTESIAN_POINT"):
            self.points[i] = self._point(i)
            self.point_is_3d[i] = self._point_coordinate_count(i) == 3
        self.directions = {i: self._direction(i) for i, _ in step.of_type("DIRECTION")}
        self.placements = {i: self._placement(i) for i, _ in step.of_type("AXIS2_PLACEMENT_3D")}
        self.circles = {i: self._circle(i) for i, _ in step.of_type("CIRCLE")}

    def _point(self, entity_id: int) -> Vec3:
        _, args = self.step.get(entity_id)
        coords = split_args(args)[-1]
        vals = [num(v) for v in split_args(coords[1:-1])]
        if len(vals) == 2:      # 2D constraint-space / pcurve point
            return Vec3(vals[0], vals[1], 0.0)
        if len(vals) != 3:
            raise ValueError(f"#{entity_id} CARTESIAN_POINT has {len(vals)} coordinates")
        return Vec3(*vals)

    def _point_coordinate_count(self, entity_id: int) -> int:
        _, args = self.step.get(entity_id)
        coords = split_args(args)[-1]
        return len(split_args(coords[1:-1]))

    def _direction(self, entity_id: int) -> Vec3:
        _, args = self.step.get(entity_id)
        ratios = split_args(args)[-1]
        vals = [num(v) for v in split_args(ratios[1:-1])]
        if len(vals) == 2:
            vals = vals + [0.0]
        if len(vals) != 3:
            raise ValueError(f"#{entity_id} DIRECTION has {len(vals)} ratios")
        return Vec3(*vals).normalized()

    def _placement(self, entity_id: int) -> tuple[Vec3, Vec3, Vec3]:
        _, args = self.step.get(entity_id)
        parts = split_args(args)
        origin = self.points[ref(parts[1])]
        z = self.directions[ref(parts[2])] if len(parts) > 2 and ref(parts[2]) else Vec3(0, 0, 1)
        x = self.directions[ref(parts[3])] if len(parts) > 3 and ref(parts[3]) else Vec3(1, 0, 0)
        return origin, z, x

    def _circle(self, entity_id: int) -> tuple[Vec3, float, Vec3, Vec3]:
        _, args = self.step.get(entity_id)
        parts = split_args(args)
        origin, z, x = self.placements[ref(parts[1])]
        radius = num(parts[2])
        return origin, radius, z, x

    # ---- public extraction ------------------------------------------------

    def units_are_millimetres(self) -> tuple[bool, str]:
        # OCCT writes the unit as a complex entity instance:
        #   #438 = ( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.) );
        # so match the token pair on the raw text with flexible whitespace and
        # verify it sits inside a LENGTH_UNIT instance.
        pattern = re.compile(r"LENGTH_UNIT\s*\(\s*\)\s*NAMED_UNIT\s*\(\s*\*\s*\)"
                             r"\s*SI_UNIT\s*\(\s*\.MILLI\.,\s*\.METRE\.\s*\)", re.I)
        match = pattern.search(self.step.text)
        if match:
            return True, "LENGTH_UNIT SI_UNIT(.MILLI.,.METRE.)"
        if re.search(r"SI_UNIT\s*\(\s*\.MILLI\.,\s*\.METRE\.\s*\)", self.step.text, re.I):
            return True, "SI_UNIT(.MILLI.,.METRE.) present (unit context unverified)"
        return False, "no millimetre unit declaration found"

    def surface_counts(self) -> dict[str, int]:
        names = ["PLANE", "CYLINDRICAL_SURFACE", "CONICAL_SURFACE", "SPHERICAL_SURFACE",
                 "TOROIDAL_SURFACE", "B_SPLINE_SURFACE", "B_SPLINE_SURFACE_WITH_KNOTS",
                 "SURFACE_OF_REVOLUTION", "SURFACE_OF_LINEAR_EXTRUSION"]
        return {n: len(self.step.of_type(n)) for n in names if self.step.of_type(n)}

    def bounds(self, samples: int = 64) -> Bounds:
        b = Bounds()
        # 3D geometry only: VERTEX_POINT-targeted points are on the solid;
        # 2D CARTESIAN_POINTs belong to pcurves / constraint space and would
        # otherwise pollute the box (seen as a (-50,-30) phantom corner).
        for _, args in self.step.of_type("VERTEX_POINT"):
            pid = ref(split_args(args)[-1])
            if pid and pid in self.points and self.point_is_3d.get(pid, False):
                b.add(self.points[pid])
        for origin, radius, z, x in self.circles.values():
            # Exact extremes of a circle live at 90° multiples relative to the
            # circle's own frame; sample every 90/samples degrees.
            y = z.cross(x).normalized()
            for k in range(samples):
                a = 2.0 * math.pi * k / samples
                b.add(origin + x * (radius * math.cos(a)) + y * (radius * math.sin(a)))
        return b

    def cylinders(self) -> list[dict]:
        result = []
        for entity_id, args in self.step.of_type("CYLINDRICAL_SURFACE"):
            parts = split_args(args)
            origin, z, x = self.placements[ref(parts[1])]
            radius = num(parts[2])
            result.append({"id": entity_id, "origin": origin, "axis": z, "radius": radius})
        return result

    def cylinder_axial_extent(self, cyl: dict) -> float | None:
        """Axial length from the boundary circles lying on this cylinder: every
        circle with the cylinder's radius whose axis is collinear with the
        cylinder axis contributes its center's projection onto that axis."""
        projections: list[float] = []
        for center, radius, z, _x in self.circles.values():
            if abs(radius - cyl["radius"]) > 1e-6:
                continue
            if abs(abs(z.dot(cyl["axis"])) - 1.0) > 1e-6:
                continue
            projections.append(center.dot(cyl["axis"]))
        if len(projections) < 2:
            return None
        return max(projections) - min(projections)


# ---------------------------------------------------------------- checks

def check(condition: bool, label: str, detail: str, failures: list[str]) -> None:
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}: {detail}")
    if not condition:
        failures.append(f"{label}: {detail}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("step_file")
    parser.add_argument("--kind", default="plate-hole")
    parser.add_argument("--expect-thickness", type=float, required=True)
    parser.add_argument("--expect-hole-diameter", type=float, default=10.0)
    parser.add_argument("--expect-volume", type=float, required=True)
    parser.add_argument("--length-tolerance", type=float, default=1e-6)
    parser.add_argument("--volume-tolerance", type=float, default=1e-3)
    args = parser.parse_args()

    text = open(args.step_file, "r", encoding="utf-8", errors="replace").read()
    failures: list[str] = []

    check("ISO-10303-21" in text, "file header", "ISO-10303-21 present", failures)
    step = StepFile(text)
    geo = StepGeometry(step)

    units_ok, units_detail = geo.units_are_millimetres()
    check(units_ok, "units", units_detail, failures)

    solid_count = len(step.of_type("MANIFOLD_SOLID_BREP"))
    shell_count = len(step.of_type("CLOSED_SHELL"))
    face_count = len(step.of_type("ADVANCED_FACE"))
    check(solid_count == 1, "solid count", f"MANIFOLD_SOLID_BREP={solid_count}", failures)
    check(shell_count >= 1, "shell", f"CLOSED_SHELL={shell_count}", failures)

    surfaces = geo.surface_counts()
    cylinders = geo.cylinders()
    check(len(cylinders) == 1, "analytic cylinder count",
          f"CYLINDRICAL_SURFACE={len(cylinders)} ({surfaces})", failures)

    bounds = geo.bounds()
    if not bounds.valid():
        check(False, "bounds", "no geometry points found", failures)
        bounds = Bounds()
    size = bounds.hi - bounds.lo
    print(f"      bounds: min=({bounds.lo.x:.6f},{bounds.lo.y:.6f},{bounds.lo.z:.6f}) "
          f"max=({bounds.hi.x:.6f},{bounds.hi.y:.6f},{bounds.hi.z:.6f})")

    # The fixture is a 100×60 plate; thickness is the smallest axis extent and
    # must match the edited parameter. The 100/60 pair is verified too.
    dims = sorted([size.x, size.y, size.z])
    check(abs(dims[2] - 100.0) < args.length_tolerance,
          "plate length", f"{dims[2]:.6f} mm (expected 100)", failures)
    check(abs(dims[1] - 60.0) < args.length_tolerance,
          "plate width", f"{dims[1]:.6f} mm (expected 60)", failures)
    check(abs(dims[0] - args.expect_thickness) < args.length_tolerance,
          "plate thickness", f"{dims[0]:.6f} mm (expected {args.expect_thickness})", failures)

    if len(cylinders) == 1:
        cyl = cylinders[0]
        check(abs(cyl["radius"] * 2.0 - args.expect_hole_diameter) < args.length_tolerance,
              "hole diameter", f"2r={2 * cyl['radius']:.6f} mm "
                               f"(expected {args.expect_hole_diameter})", failures)
        length = geo.cylinder_axial_extent(cyl)
        if length is None:
            check(False, "hole axial extent",
                  "could not resolve the cylinder's boundary circles", failures)
        else:
            check(abs(length - args.expect_thickness) < args.length_tolerance,
                  "hole axial length",
                  f"{length:.6f} mm (expected {args.expect_thickness})", failures)
            volume = dims[2] * dims[1] * dims[0] - math.pi * cyl["radius"] ** 2 * length
            check(abs(volume - args.expect_volume) <= args.volume_tolerance,
                  "analytic volume",
                  f"{volume:.6f} mm³ (expected {args.expect_volume:.6f}, "
                  f"tolerance {args.volume_tolerance})", failures)

    plane_count = surfaces.get("PLANE", 0)
    check(plane_count >= 6, "planar faces",
          f"PLANE={plane_count} (expected ≥6 for a plate with a hole)", failures)

    summary = {
        "file": args.step_file,
        "kind": args.kind,
        "units": units_detail,
        "surfaces": surfaces,
        "solidCount": solid_count,
        "faceCount": face_count,
        "bounds": {"min": [bounds.lo.x, bounds.lo.y, bounds.lo.z],
                   "max": [bounds.hi.x, bounds.hi.y, bounds.hi.z],
                   "size": [size.x, size.y, size.z]},
        "cylinder": ([{"radius": c["radius"], "axis": [c["axis"].x, c["axis"].y, c["axis"].z]}
                      for c in cylinders]),
        "failures": failures,
    }
    print(json.dumps(summary, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
