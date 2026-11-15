#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Blender-side helper for floe-blender.

Run only through the guest Blender binary:

    blender --background --factory-startup --disable-autoexec \
        --python-exit-code 7 --python blender_ops.py -- <phase> ...

The helper prints machine-readable records on stdout with the prefix
``FLOE_BLENDER_JSON ``.  It never invents results: a phase that cannot do
real work raises, and the wrapper treats a missing completion record as a
failure.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import resource
import struct
import sys
import time
import traceback
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

sys.dont_write_bytecode = True

JSON_PREFIX = "FLOE_BLENDER_JSON "
SOFTWARE_RENDER_MARKERS = ("llvmpipe", "softpipe", "swrast", "swiftshader", "lavapipe")
EEVEE_NAMES = ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE")


def emit(**data: Any) -> None:
    print(JSON_PREFIX + json.dumps(data, sort_keys=True, default=str), flush=True)


def now() -> float:
    return time.perf_counter()


def timed(label: str, call):
    emit(begin=label)
    began = now()
    value = call()
    emit(operation=label, seconds=now() - began)
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_software_renderer(renderer: Optional[str]) -> Optional[bool]:
    if not renderer:
        return None
    lowered = renderer.lower()
    return any(marker in lowered for marker in SOFTWARE_RENDER_MARKERS)


# ---------------------------------------------------------------------------
# Scene inspection and deterministic test scene


def gpu_details() -> Dict[str, Any]:
    try:
        import gpu

        result: Dict[str, Any] = {}
        for name in ("vendor_get", "renderer_get", "version_get", "backend_type_get"):
            getter = getattr(gpu.platform, name, None)
            if getter is not None:
                result[name[:-4]] = getter()
        return result
    except BaseException as error:  # GPU context is optional in background mode.
        return {"error": repr(error)}


def build_options() -> Dict[str, Any]:
    options = getattr(__import__("bpy").app, "build_options", None)
    if options is None:
        return {}
    names = ("cycles", "cuda", "optix", "hip", "oneapi", "metal", "openmp",
             "python", "ffmpeg", "sdl", "xr_openxr", "freestyle")
    return {name: bool(getattr(options, name, False)) for name in names}


def available_engines() -> List[Dict[str, str]]:
    import bpy

    try:
        prop = bpy.types.RenderSettings.bl_rna.properties["engine"]
        return [{"id": item.identifier, "name": item.name} for item in prop.enum_items]
    except BaseException:
        return []


def cycles_devices() -> Dict[str, Any]:
    import bpy

    try:
        addon = bpy.context.preferences.addons.get("cycles")
        if addon is None:
            return {"available": False, "reason": "Cycles add-on is not present",
                    "compiledBackends": [], "devices": [], "gpuDevices": []}
        prefs = addon.preferences
        try:
            prefs.refresh_devices()
        except BaseException:
            pass
        types: List[str] = []
        try:
            types = [str(item[0]) for item in prefs.get_device_types(bpy.context)]
        except BaseException:
            try:
                types = [str(item.identifier) for item in prefs.get_device_types(bpy.context)]
            except BaseException:
                types = []
        try:
            prefs.get_devices()
        except BaseException:
            pass
        devices = []
        for device in getattr(prefs, "devices", []):
            devices.append({
                "name": str(getattr(device, "name", "")),
                "type": str(getattr(device, "type", "")),
                "id": str(getattr(device, "id", "")),
            })
        return {
            "available": True,
            "compiledBackends": types,
            "devices": devices,
            "gpuDevices": [item for item in devices if item["type"] != "CPU"],
            "computeDeviceType": str(getattr(prefs, "compute_device_type", "")),
        }
    except BaseException as error:
        return {"available": False, "reason": repr(error), "compiledBackends": [],
                "devices": [], "gpuDevices": []}


def probe_payload() -> Dict[str, Any]:
    import bpy

    return {
        "phase": "probe",
        "completed": True,
        "blenderVersion": bpy.app.version_string,
        "versionTuple": list(bpy.app.version),
        "background": bool(bpy.app.background),
        "pythonVersion": sys.version.split()[0],
        "platform": sys.platform,
        "buildOptions": build_options(),
        "engines": available_engines(),
        "cycles": cycles_devices(),
        "gpuContext": gpu_details(),
        "display": os.environ.get("DISPLAY"),
    }


def material(name: str, color: Tuple[float, float, float], metal: float = 0.0):
    import bpy

    result = bpy.data.materials.new(name)
    result.use_nodes = True
    shader = result.node_tree.nodes.get("Principled BSDF")
    if shader is None:
        raise RuntimeError("Principled BSDF node is missing")
    shader.inputs["Base Color"].default_value = (*color, 1.0)
    shader.inputs["Metallic"].default_value = metal
    shader.inputs["Roughness"].default_value = 0.32
    return result


def create_demo_housing() -> None:
    """Deterministic 4-hole housing used by the smoke recipe.

    This is a real mesh/boolean/bevel/subdivision edit, not a synthetic
    render fixture.  It mirrors the previously prepared blender_baseline.py
    scene so old and new evidence stay comparable.
    """
    import bpy
    from mathutils import Vector

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    body_mat = material("Blue housing", (0.025, 0.16, 0.5), 0.35)
    ring_mat = material("Warm metal", (0.55, 0.22, 0.035), 0.7)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0.45))
    body = bpy.context.object
    body.name = "Four-hole housing"
    body.dimensions = (4, 3, 0.8)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    body.data.materials.append(body_mat)

    for x in (-1.3, 1.3):
        for y in (-0.85, 0.85):
            bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=0.32, depth=1.6,
                                                location=(x, y, 0.45))
            cutter = bpy.context.object
            bpy.context.view_layer.objects.active = body
            operation = body.modifiers.new("Through hole", "BOOLEAN")
            operation.operation = "DIFFERENCE"
            operation.solver = "EXACT"
            operation.object = cutter
            bpy.ops.object.modifier_apply(modifier=operation.name)
            bpy.data.objects.remove(cutter, do_unlink=True)
    bevel = body.modifiers.new("Machined edge", "BEVEL")
    bevel.width = 0.065
    bevel.segments = 3
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.modifier_apply(modifier=bevel.name)

    bpy.ops.mesh.primitive_torus_add(major_segments=48, minor_segments=12, location=(0, 0, 1.05),
                                     major_radius=0.8, minor_radius=0.12)
    ring = bpy.context.object
    ring.name = "Subdivision ring"
    ring.data.materials.append(ring_mat)
    modifier = ring.modifiers.new("Surface refinement", "SUBSURF")
    modifier.levels = 2
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    for polygon in ring.data.polygons:
        polygon.use_smooth = True
    for number in range(1, 12):
        duplicate = ring.copy()
        duplicate.data = ring.data
        duplicate.location = (-2.5 + (number % 4) * 1.7, -2.5 + (number // 4) * 1.7, 0.3)
        duplicate.scale = (0.35, 0.35, 0.35)
        bpy.context.collection.objects.link(duplicate)

    bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, 0))
    floor = bpy.context.object
    floor.name = "Floor"
    floor.data.materials.append(material("Floor", (0.12, 0.12, 0.12)))
    bpy.ops.object.camera_add(location=(8, -10, 8))
    camera = bpy.context.object
    camera.rotation_euler = (Vector((0, 0, 0.5)) - camera.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = camera
    bpy.ops.object.light_add(type="AREA", location=(1, -2, 7))
    light = bpy.context.object
    light.data.energy = 1200
    light.data.shape = "DISK"
    light.data.size = 5
    bpy.context.scene.world.color = (0.1, 0.1, 0.1)
    bpy.context.view_layer.update()


def geometry_counts() -> Dict[str, Any]:
    import bpy

    vertices = 0
    triangles = 0
    graph = bpy.context.evaluated_depsgraph_get()
    objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    for obj in objects:
        evaluated = obj.evaluated_get(graph)
        mesh = evaluated.to_mesh()
        try:
            mesh.calc_loop_triangles()
            vertices += len(mesh.vertices)
            triangles += len(mesh.loop_triangles)
        finally:
            evaluated.to_mesh_clear()
    return {"meshObjects": len(objects), "evaluatedVertices": vertices,
            "evaluatedTriangles": triangles}


def load_scene(path: str) -> None:
    import bpy

    source = Path(path)
    if not source.is_file():
        raise RuntimeError("scene file does not exist: %s" % source)
    result = bpy.ops.wm.open_mainfile(filepath=str(source))
    if "FINISHED" not in result:
        raise RuntimeError("Blender did not open the scene: %r" % (result,))


def reset_scene() -> None:
    import bpy

    bpy.ops.wm.read_factory_settings(use_empty=False)
    bpy.context.view_layer.update()


def targets_from_args(names: Sequence[str]):
    import bpy

    if names:
        targets = []
        for name in names:
            obj = bpy.data.objects.get(name)
            if obj is None:
                raise RuntimeError("object not found: %s" % name)
            if obj.type != "MESH":
                raise RuntimeError("object is not a mesh: %s" % name)
            targets.append(obj)
        return targets
    active = bpy.context.view_layer.objects.active
    if active is None or active.type != "MESH":
        raise RuntimeError("no active mesh object; pass --object NAME")
    return [active]


def select_only(targets) -> None:
    import bpy

    bpy.ops.object.select_all(action="DESELECT")
    for obj in targets:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = targets[0]


def apply_boolean(target, cutter_name: str, delete_cutter: bool) -> None:
    import bpy

    cutter = bpy.data.objects.get(cutter_name)
    if cutter is None:
        raise RuntimeError("boolean cutter not found: %s" % cutter_name)
    if cutter is target:
        raise RuntimeError("boolean cutter and target must differ")
    select_only([target])
    modifier = target.modifiers.new("Floe boolean difference", "BOOLEAN")
    modifier.operation = "DIFFERENCE"
    modifier.solver = "EXACT"
    modifier.object = cutter
    result = bpy.ops.object.modifier_apply(modifier=modifier.name)
    if "FINISHED" not in result:
        raise RuntimeError("boolean apply failed: %r" % (result,))
    bpy.context.view_layer.update()
    if delete_cutter:
        bpy.data.objects.remove(cutter, do_unlink=True)


def apply_bevel(target, width: float, segments: int) -> None:
    import bpy

    if width <= 0:
        raise RuntimeError("bevel width must be positive")
    if segments < 1 or segments > 64:
        raise RuntimeError("bevel segments must be 1..64")
    select_only([target])
    modifier = target.modifiers.new("Floe bevel", "BEVEL")
    modifier.width = width
    modifier.segments = segments
    result = bpy.ops.object.modifier_apply(modifier=modifier.name)
    if "FINISHED" not in result:
        raise RuntimeError("bevel apply failed: %r" % (result,))
    bpy.context.view_layer.update()


def apply_subdivision(target, levels: int) -> None:
    import bpy

    if levels < 1 or levels > 6:
        raise RuntimeError("subdivision levels must be 1..6")
    select_only([target])
    modifier = target.modifiers.new("Floe subdivision", "SUBSURF")
    modifier.levels = levels
    modifier.render_levels = levels
    result = bpy.ops.object.modifier_apply(modifier=modifier.name)
    if "FINISHED" not in result:
        raise RuntimeError("subdivision apply failed: %r" % (result,))
    bpy.context.view_layer.update()


def run_user_script(path: str) -> None:
    import runpy

    script = Path(path)
    if not script.is_file():
        raise RuntimeError("user script does not exist: %s" % script)
    inserted = str(script.parent)
    sys.path.insert(0, inserted)
    try:
        try:
            runpy.run_path(str(script), run_name="__main__")
        except SystemExit as error:
            if error.code not in (None, 0):
                raise RuntimeError("user script exited with %r" % (error.code,))
    finally:
        try:
            sys.path.remove(inserted)
        except ValueError:
            pass


def validate_png(path: Path, minimum_colors: int = 4) -> Dict[str, Any]:
    import bpy

    if not path.is_file():
        raise RuntimeError("render output is missing: %s" % path)
    image = bpy.data.images.load(str(path), check_existing=False)
    try:
        width, height = image.size
        if width < 1 or height < 1:
            raise RuntimeError("render output has invalid dimensions")
        values = []
        step_x = max(1, width // 16)
        step_y = max(1, height // 16)
        for y in range(height // 8, max(height // 8 + 1, height * 7 // 8), step_y):
            for x in range(width // 8, max(width // 8 + 1, width * 7 // 8), step_x):
                offset = (y * width + x) * image.channels
                rgb = tuple(float(image.pixels[offset + channel]) for channel in range(3))
                if not all(math.isfinite(value) for value in rgb):
                    raise RuntimeError("render output contains non-finite pixels")
                values.append(rgb)
        colors = {tuple(round(value, 3) for value in rgb) for rgb in values}
        maximum = max((max(rgb) for rgb in values), default=0.0)
        if len(colors) < minimum_colors or maximum < 0.1:
            raise RuntimeError("render output is blank or has inadequate variation")
        return {
            "width": width,
            "height": height,
            "sampledColors": len(colors),
            "maxChannel": round(maximum, 6),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }
    finally:
        bpy.data.images.remove(image)


def validate_blend(path: Path) -> Dict[str, Any]:
    if not path.is_file():
        raise RuntimeError("saved .blend is missing: %s" % path)
    with path.open("rb") as stream:
        magic = stream.read(7)
    if magic != b"BLENDER" or path.stat().st_size < 1024:
        raise RuntimeError("saved .blend is invalid")
    return {"bytes": path.stat().st_size, "sha256": sha256_file(path)}


def validate_glb(path: Path) -> Dict[str, Any]:
    if not path.is_file():
        raise RuntimeError("exported GLB is missing: %s" % path)
    size = path.stat().st_size
    with path.open("rb") as stream:
        header = stream.read(12)
        if len(header) != 12 or struct.unpack("<4sII", header) != (b"glTF", 2, size):
            raise RuntimeError("exported file is not a valid GLB")
        length, kind = struct.unpack("<I4s", stream.read(8))
        if kind != b"JSON" or length > size - 20:
            raise RuntimeError("GLB JSON chunk is invalid")
        document = json.loads(stream.read(length))
    if not document.get("meshes") or not document.get("accessors") or not document.get("nodes"):
        raise RuntimeError("GLB has no scene geometry")
    return {
        "bytes": size,
        "sha256": sha256_file(path),
        "meshes": len(document.get("meshes") or []),
        "nodes": len(document.get("nodes") or []),
        "accessors": len(document.get("accessors") or []),
    }


def save_blend(path: str) -> Dict[str, Any]:
    import bpy

    result = bpy.ops.wm.save_as_mainfile(filepath=str(path), check_existing=False, compress=False)
    if "FINISHED" not in result:
        raise RuntimeError("save_as_mainfile failed: %r" % (result,))
    return validate_blend(Path(path))


def export_glb(path: str, selection_only: bool, apply_modifiers: bool) -> Dict[str, Any]:
    import bpy

    try:
        import addon_utils

        addon_utils.enable("io_scene_gltf2", default_set=True, persistent=True)
    except BaseException:
        pass
    kwargs = {
        "filepath": str(path),
        "export_format": "GLB",
        "export_apply": bool(apply_modifiers),
        "use_selection": bool(selection_only),
        "export_animations": False,
        "export_cameras": False,
        "export_lights": False,
    }
    try:
        result = bpy.ops.export_scene.gltf(**kwargs)
    except TypeError:
        # Older/newer Blender may not accept every optional keyword.  Keep the
        # format and selection contract, drop only cosmetic options.
        result = bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB",
                                           use_selection=bool(selection_only))
    if "FINISHED" not in result:
        raise RuntimeError("glTF export failed: %r" % (result,))
    return validate_glb(Path(path))


# ---------------------------------------------------------------------------
# Phases


def phase_edit(args: argparse.Namespace) -> None:
    import bpy

    began = now()
    operations: List[Dict[str, Any]] = []
    if args.input:
        timed("open_scene", lambda: load_scene(args.input))
    elif args.new or args.demo_housing:
        timed("new_scene", reset_scene)
    else:
        raise RuntimeError("edit requires input or new/demo scene")

    if args.demo_housing:
        timed("demo_housing", create_demo_housing)
        operations.append({"operation": "demo_housing"})
    elif args.boolean_difference or args.bevel is not None or args.subdivide is not None:
        targets = targets_from_args(args.object)
        if args.boolean_difference:
            for target in targets:
                timed("boolean_difference",
                      lambda target=target: apply_boolean(target, args.boolean_difference,
                                                          args.delete_cutters))
                operations.append({"operation": "boolean_difference", "object": target.name,
                                   "cutter": args.boolean_difference})
        if args.bevel is not None:
            for target in targets:
                timed("bevel", lambda target=target: apply_bevel(target, args.bevel,
                                                                 args.bevel_segments))
                operations.append({"operation": "bevel", "object": target.name,
                                   "width": args.bevel, "segments": args.bevel_segments})
        if args.subdivide is not None:
            for target in targets:
                timed("subdivide", lambda target=target: apply_subdivision(target, args.subdivide))
                operations.append({"operation": "subdivide", "object": target.name,
                                   "levels": args.subdivide})
    if args.script:
        timed("user_script", lambda: run_user_script(args.script))
        operations.append({"operation": "script", "path": args.script})

    geometry = geometry_counts()
    if args.demo_housing:
        if geometry["meshObjects"] < 14 or geometry["evaluatedVertices"] < 50000 \
                or geometry["evaluatedTriangles"] < 100000:
            raise RuntimeError("demo housing geometry is incomplete: %r" % (geometry,))
    saved = None
    exported = None
    if args.save:
        saved = timed("save_blend", lambda: save_blend(args.save))
    if args.export_glb:
        exported = timed("export_glb",
                         lambda: export_glb(args.export_glb, args.selection_only, True))
    if not saved and not exported:
        raise RuntimeError("edit produced no requested output")
    emit(phase="edit", completed=True, operations=operations, geometry=geometry,
         saved=saved, exported=exported, elapsedSeconds=now() - began,
         peakRSSKiB=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)


def phase_export(args: argparse.Namespace) -> None:
    began = now()
    timed("open_scene", lambda: load_scene(args.scene))
    exported = timed("export_glb",
                     lambda: export_glb(args.output, args.selection_only, args.apply_modifiers))
    emit(phase="export", completed=True, geometry=geometry_counts(), exported=exported,
         elapsedSeconds=now() - began,
         peakRSSKiB=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)


def choose_engine(name: str) -> str:
    engines = available_engines()
    identifiers = {item["id"] for item in engines}
    if name == "eevee":
        for candidate in EEVEE_NAMES:
            if candidate in identifiers:
                return candidate
        raise RuntimeError("EEVEE engine is not available in this Blender build")
    if name == "cycles":
        if "CYCLES" not in identifiers:
            raise RuntimeError("Cycles engine is not available in this Blender build")
        return "CYCLES"
    raise RuntimeError("unknown engine: %s" % name)


def configure_cycles_gpu() -> Dict[str, Any]:
    import bpy

    addon = bpy.context.preferences.addons.get("cycles")
    if addon is None:
        raise RuntimeError("Cycles add-on is not present")
    prefs = addon.preferences
    try:
        prefs.refresh_devices()
    except BaseException:
        pass
    types = []
    try:
        types = [str(item[0]) for item in prefs.get_device_types(bpy.context)]
    except BaseException:
        types = []
    gpu_types = [item for item in types if item not in ("NONE", "CPU", "")]
    if not gpu_types:
        raise RuntimeError("no Cycles GPU compute backend is compiled or available")
    for compute_type in gpu_types:
        prefs.compute_device_type = compute_type
        try:
            prefs.get_devices()
        except BaseException:
            pass
        devices = [device for device in getattr(prefs, "devices", [])
                   if str(getattr(device, "type", "")) == compute_type]
        if devices:
            for device in prefs.devices:
                device.use = str(getattr(device, "type", "")) == compute_type
            bpy.context.scene.cycles.device = "GPU"
            return {
                "computeDeviceType": compute_type,
                "devices": [{"name": str(device.name), "type": str(device.type),
                             "id": str(device.id), "use": bool(device.use)}
                            for device in devices],
            }
    raise RuntimeError("no Cycles GPU device was found for compiled backends: %s" % gpu_types)


def configure_render(args: argparse.Namespace) -> Dict[str, Any]:
    import bpy

    scene = bpy.context.scene
    engine = choose_engine(args.engine)
    scene.render.engine = engine
    scene.render.resolution_x = args.resolution
    scene.render.resolution_y = args.resolution
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA" if args.film_transparent else "RGB"
    scene.render.image_settings.color_depth = "8"
    scene.render.film_transparent = bool(args.film_transparent)
    scene.render.use_motion_blur = False
    details: Dict[str, Any] = {"engine": engine, "device": args.device}
    if args.engine == "eevee":
        scene.eevee.taa_render_samples = args.samples
        details["samples"] = args.samples
    else:
        scene.cycles.samples = args.samples
        scene.cycles.use_denoising = False
        if args.device == "gpu":
            details.update(configure_cycles_gpu())
        else:
            scene.cycles.device = "CPU"
            details["computeDeviceType"] = "CPU"
        details["samples"] = args.samples
    return details


def render_one(path: Path) -> Dict[str, Any]:
    import bpy

    scene = bpy.context.scene
    scene.render.filepath = str(path)
    began = now()
    result = bpy.ops.render.render(write_still=True)
    seconds = now() - began
    if "FINISHED" not in result:
        raise RuntimeError("render failed: %r" % (result,))
    image = validate_png(path)
    gpu = gpu_details()
    return {
        "path": str(path),
        "seconds": seconds,
        "image": image,
        "gpu": gpu,
        "renderer": gpu.get("renderer"),
        "vendor": gpu.get("vendor"),
        "backend": gpu.get("backend_type") or gpu.get("backend"),
    }


def phase_render(args: argparse.Namespace) -> None:
    import bpy

    began = now()
    timed("open_scene", lambda: load_scene(args.scene))
    details = timed("configure_render", lambda: configure_render(args))
    import tempfile

    auto_paths: List[Path] = []

    def temp_png(prefix: str) -> Path:
        descriptor, name = tempfile.mkstemp(prefix=prefix, suffix=".png",
                                            dir=str(Path(args.output).parent))
        os.close(descriptor)
        path = Path(name)
        auto_paths.append(path)
        return path

    output = Path(args.output)
    if args.repeat == 1:
        paths = [output]
        labels = ["render"]
    elif args.repeat == 2:
        paths = [Path(args.keep_cold) if args.keep_cold else temp_png(".floe-blender-cold-"),
                 output]
        labels = ["cold", "warm"]
    else:
        paths = [Path(args.keep_cold) if args.keep_cold else temp_png(".floe-blender-cold-"),
                 temp_png(".floe-blender-middle-"), output]
        labels = ["cold", "middle", "warm"]
    renders: List[Dict[str, Any]] = []
    try:
        for label, path in zip(labels, paths):
            item = timed(label + "_render", lambda path=path: render_one(path))
            item["label"] = label
            renders.append(item)
    finally:
        for path in auto_paths:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
    if args.expect_backend:
        expected = args.expect_backend.upper()
        for item in renders:
            actual = (item.get("backend") or "").upper()
            if actual != expected:
                raise RuntimeError("expected %s backend, got %s" % (expected, actual or "unknown"))
    if args.engine == "eevee" and args.device in ("gpu", "software"):
        for item in renders:
            software = is_software_renderer(item.get("renderer"))
            if software is None:
                raise RuntimeError("GPU/software renderer could not be identified")
            if args.device == "gpu" and software:
                raise RuntimeError("GPU request was executed by a software renderer: %s"
                                   % item.get("renderer"))
            if args.device == "software" and not software:
                raise RuntimeError("software request was executed by a hardware renderer: %s"
                                   % item.get("renderer"))
    total = sum(float(item["seconds"]) for item in renders)
    emit(phase="render", completed=True, engine=args.engine, device=args.device,
         renders=renders, totalRenderSeconds=total, elapsedSeconds=now() - began,
         details=details, peakRSSKiB=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)


# ---------------------------------------------------------------------------
# CLI


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="blender_ops.py")
    sub = parser.add_subparsers(dest="phase", required=True)

    probe = sub.add_parser("probe")
    probe.set_defaults(handler=lambda _args: emit(**probe_payload()))

    edit = sub.add_parser("edit")
    edit.add_argument("--input")
    edit.add_argument("--new", action="store_true")
    edit.add_argument("--demo-housing", action="store_true")
    edit.add_argument("--object", action="append", default=[])
    edit.add_argument("--boolean-difference")
    edit.add_argument("--bevel", type=float)
    edit.add_argument("--bevel-segments", type=int, default=3)
    edit.add_argument("--subdivide", type=int)
    edit.add_argument("--script")
    edit.add_argument("--delete-cutters", action="store_true")
    edit.add_argument("--save")
    edit.add_argument("--export-glb")
    edit.add_argument("--selection-only", action="store_true")
    edit.set_defaults(handler=phase_edit)

    export = sub.add_parser("export")
    export.add_argument("--scene", required=True)
    export.add_argument("--output", required=True)
    export.add_argument("--selection-only", action="store_true")
    export.add_argument("--no-apply-modifiers", dest="apply_modifiers",
                        action="store_false", default=True)
    export.set_defaults(handler=phase_export)

    render = sub.add_parser("render")
    render.add_argument("--scene", required=True)
    render.add_argument("--engine", choices=["eevee", "cycles"], required=True)
    render.add_argument("--device", choices=["gpu", "software", "cpu"], required=True)
    render.add_argument("--output", required=True)
    render.add_argument("--resolution", type=int, default=512)
    render.add_argument("--samples", type=int, default=16)
    render.add_argument("--repeat", type=int, default=1)
    render.add_argument("--keep-cold")
    render.add_argument("--film-transparent", action="store_true")
    render.add_argument("--expect-backend", choices=["VULKAN", "OPENGL"])
    render.set_defaults(handler=phase_render)
    return parser


def main() -> int:
    if "--" not in sys.argv:
        raise SystemExit("blender_ops.py must be invoked by floe-blender")
    argv = sys.argv[sys.argv.index("--") + 1:]
    parser = build_parser()
    args = parser.parse_args(argv)
    phase = args.phase
    try:
        args.handler(args)
    except BaseException as error:
        emit(phase=phase, completed=False, error=repr(error), traceback=traceback.format_exc())
        raise
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
