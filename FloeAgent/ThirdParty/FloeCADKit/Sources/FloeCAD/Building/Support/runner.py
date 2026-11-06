# SPDX-License-Identifier: MPL-2.0
"""Fixed building-study adapter. Run only by the task's resolved exec.shell.

Geometry is the saved CAD tessellation, in IFC metres; IfcOpenShell owns IFC
authoring, triangulation and clash queries. PyNite owns the explicitly defined
single-member analysis. IDS checks information requirements, not building law.
No document text is executed and no input-supplied path is opened.
"""
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def finite(value, low=-1e8, high=1e8):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and low <= value <= high


def write_atomic(name, data):
    path = Path(name)
    require(not path.is_symlink() and not path.with_suffix(path.suffix + ".tmp").is_symlink(), "Unsafe result path")
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_bytes(data)
    temp.replace(path)


def make_ifc(request):
    import ifcopenshell
    from ifcopenshell.api import aggregate, context, geometry, project, root, spatial, unit
    model = request["model"]
    f = project.create_file(version="IFC4")
    project_entity = root.create_entity(f, ifc_class="IfcProject", name=model["name"])
    unit.assign_unit(f, units=[unit.add_si_unit(f, unit_type="LENGTHUNIT")])
    site = root.create_entity(f, ifc_class="IfcSite", name="Site")
    building = root.create_entity(f, ifc_class="IfcBuilding", name=model["name"])
    aggregate.assign_object(f, products=[site], relating_object=project_entity)
    aggregate.assign_object(f, products=[building], relating_object=site)
    body_context = context.add_context(f, context_type="Model")
    body_context = context.add_context(f, context_type="Model", context_identifier="Body", target_view="MODEL_VIEW", parent=body_context)
    floors = {}
    for item in model["storeys"]:
        floor = root.create_entity(f, ifc_class="IfcBuildingStorey", name=item["name"])
        floor.Elevation = item["elevationMM"] / 1000
        aggregate.assign_object(f, products=[floor], relating_object=building)
        floors[item["id"]] = floor
    classes = {"wall": "IfcWall", "slab": "IfcSlab", "roof": "IfcRoof", "stair": "IfcStair",
               "column": "IfcColumn", "beam": "IfcBeam", "door": "IfcDoor", "window": "IfcWindow",
               "space": "IfcSpace", "pipe": "IfcPipeSegment", "duct": "IfcDuctSegment"}
    mesh_by_id = {}
    triangles = 0
    for item in request["geometry"]:
        positions, indices = item["verticesM"], item["indices"]
        require(0 < len(positions) <= 1_500_000 and len(indices) % 3 == 0, "Invalid IFC mesh")
        triangles += len(indices) // 3
        require(triangles <= 500_000, "IFC triangle budget exceeded")
        require(all(len(p) == 3 and all(finite(x) for x in p) for p in positions), "Invalid IFC coordinates")
        require(all(isinstance(i, int) and 0 <= i < len(positions) for i in indices), "Invalid IFC triangle index")
        mesh_by_id.setdefault(item["elementID"], []).append((positions, [indices[i:i+3] for i in range(0, len(indices), 3)]))
    products = {}
    for item in model["elements"]:
        entity = root.create_entity(f, ifc_class=classes[item["kind"]], name=item["name"])
        entity.GlobalId = ifcopenshell.guid.compress(item["id"].replace("-", "").lower())
        entity.Description = "Floe building element; saved CAD tessellation in metres"
        if item["kind"] == "space":
            aggregate.assign_object(f, products=[entity], relating_object=floors[item["storeyID"]])
        else:
            spatial.assign_container(f, products=[entity], relating_structure=floors[item["storeyID"]])
            meshes = mesh_by_id.get(item["id"], [])
            require(meshes, "Missing saved CAD geometry")
            representation = geometry.add_mesh_representation(f, context=body_context,
                vertices=[mesh[0] for mesh in meshes], faces=[mesh[1] for mesh in meshes], unit_scale=1.0)
            geometry.assign_representation(f, product=entity, representation=representation)
        products[item["id"]] = entity
    # Geometry already contains real openings. Reference hosted components
    # through explicit relationships without subtracting the opening twice.
    from ifcopenshell.api import pset
    for item in model["elements"]:
        fields = {"FloeElementId": item["id"], "GeometryRepresentation": "saved CAD tessellation"}
        if item.get("hostID"):
            fields["HostElementId"] = item["hostID"]
        properties = pset.add_pset(f, product=products[item["id"]], name="FloeBuilding")
        pset.edit_pset(f, pset=properties, properties=fields)
    data = f.to_string().encode("utf-8")
    write_atomic("model.ifc", data)
    reopened = ifcopenshell.open("model.ifc")
    require(len(reopened.by_type("IfcBuildingStorey")) == len(model["storeys"]), "IFC floor readback mismatch")
    for item in model["elements"]:
        entity = reopened.by_guid(products[item["id"]].GlobalId)
        require(entity is not None and entity.Name == item["name"], "IFC identity readback mismatch")
        if item["kind"] != "space":
            import ifcopenshell.geom
            shape = ifcopenshell.geom.create_shape(ifcopenshell.geom.settings(), entity)
            require(len(shape.geometry.verts) > 0 and len(shape.geometry.faces) > 0, "IFC shape could not be read back")
    return reopened, {item["id"]: reopened.by_guid(entity.GlobalId) for item, entity in
                      ((item, products[item["id"]]) for item in model["elements"])}, triangles


def structure(request):
    from Pynite import FEModel3D
    settings = request["structural"]
    member = next((x for x in request["model"]["elements"] if x["id"] == settings.get("memberID") and x["kind"] == "beam"), None)
    require(member is not None, "Choose an authored beam for this single-member study")
    length = math.hypot(member["b"][0]-member["a"][0], member["b"][1]-member["a"][1])
    width, depth = member["thicknessMM"], member["heightMM"]
    e, nu, load = settings["elasticModulusNPerMM2"], settings["poissonRatio"], settings["lineLoadNPerMM"]
    require(all(finite(x, 1, 1e7) for x in [length, width, depth, e]) and finite(nu, 0, 0.4999) and finite(load, 1e-6, 1e6), "Invalid structural inputs")
    support = settings["support"]
    require(support in ["simplySupported", "cantilever"], "Unsupported support condition")
    area, iy, iz = width*depth, depth*width**3/12, width*depth**3/12
    b, h = max(width, depth), min(width, depth)
    torsion = b*h**3*(1/3-0.21*h/b*(1-h**4/(12*b**4)))
    analysis = FEModel3D()
    analysis.add_material("Authored material", e, e/(2*(1+nu)), nu, 0)
    analysis.add_section("Rectangular section", area, iy, iz, torsion)
    analysis.add_node("A", 0, 0, 0)
    analysis.add_node("B", length, 0, 0)
    analysis.add_member("M", "A", "B", "Authored material", "Rectangular section")
    if support == "cantilever":
        analysis.def_support("A", True, True, True, True, True, True)
    else:
        analysis.def_support("A", True, True, True, True, False, False)
        analysis.def_support("B", False, True, True, False, False, False)
    analysis.add_member_dist_load("M", "Fy", -load, -load)
    analysis.analyze_linear(check_stability=True, check_statics=True)
    displacement = analysis.members["M"].min_deflection("dy")
    reaction = sum(node.RxnFY["Combo 1"] for node in analysis.nodes.values())
    require(finite(displacement, -1e15, 1e15) and abs(reaction-load*length) <= max(1e-5, load*length*1e-8), "Structural equilibrium check failed")
    return {"scope": "one rectangular beam with explicitly authored material, supports and uniform load",
            "memberID": member["id"], "support": support, "spanMM": length,
            "lineLoadNPerMM": load, "minimumDeflectionMM": displacement, "reactionSumN": reaction,
            "wholeBuildingAnalysis": False, "designCodeApproval": False}


def mep(request, f, products):
    import ifcopenshell.geom
    systems = [products[x["id"]] for x in request["model"]["elements"] if x["kind"] in ["pipe", "duct"]]
    structure = [products[x["id"]] for x in request["model"]["elements"] if x["kind"] in ["wall", "slab", "roof", "beam", "column"]]
    if not systems or not structure:
        return {"status": "notEvaluated", "reason": "Add a pipe or duct and building geometry to run coordination", "clashes": []}
    tree = ifcopenshell.geom.tree(f, backend="opencascade.trianglebvh")
    clashes = tree.clash_intersection_many(systems, structure, tolerance=0.002, check_all=True)
    rows = [{"a": clash.a.GlobalId, "b": clash.b.GlobalId, "distanceM": clash.distance} for clash in clashes]
    return {"status": "evaluated", "method": "IfcOpenShell geometric intersection", "toleranceM": 0.002,
            "clashes": rows, "systemSizing": False, "codeApproval": False}


def information(request, f):
    from ifctester import ids
    checks = ids.Ids(title="Floe building information requirements")
    classes = sorted(set(x.is_a().upper() for x in f.by_type("IfcElement")))
    for name in classes:
        spec = ids.Specification(name=name + " has a name", minOccurs=1, ifcVersion=["IFC4"])
        spec.applicability.append(ids.Entity(name=name))
        spec.requirements.append(ids.Attribute(name="Name", cardinality="required"))
        checks.specifications.append(spec)
    checks.validate(f)
    checks.to_xml("requirements.ids")
    return {"scope": "IDS names on present IFC element classes", "buildingRegulations": False,
            "checks": [{"name": x.name, "passed": bool(x.status), "applicable": len(x.applicable_entities),
                        "failed": len(x.failed_entities)} for x in checks.specifications]}


def main():
    path = Path("input.json")
    require(not path.is_symlink() and path.stat().st_size <= 64*1024*1024, "Unsafe or oversized building input")
    raw = path.read_bytes()
    request = json.loads(raw)
    require(request["schemaVersion"] == 1 and request["action"] in ["ifc", "structure", "mep", "information"], "Unsupported building study")
    model = request["model"]
    require(model["schemaVersion"] == 1 and 0 < len(model["storeys"]) <= 128 and len(model["elements"]) <= 1000, "Invalid building records")
    f, products, triangles = make_ifc(request)
    result = {"schemaVersion": 1, "action": request["action"], "sourceSHA256": sha(raw),
              "sourceRevision": request["revision"], "modelSHA256": request["modelSHA256"],
              "geometry": "saved CAD tessellation", "triangles": triangles,
              "backendVersions": {name: importlib.metadata.version(name) for name in ["ifcopenshell", "ifctester", "PyniteFEA"]}}
    if request["action"] == "structure":
        result["analysis"] = structure(request)
    elif request["action"] == "mep":
        result["coordination"] = mep(request, f, products)
    elif request["action"] == "information":
        result["information"] = information(request, f)
    result["artifacts"] = {name: sha(Path(name).read_bytes()) for name in ["model.ifc", "requirements.ids"] if Path(name).is_file()}
    require(result["artifacts"].get("model.ifc"), "Missing IFC output")
    write_atomic("result.json", json.dumps(result, sort_keys=True, allow_nan=False).encode("utf-8"))
    print(json.dumps({"completed": request["action"], "elements": len(products), "sourceSHA256": sha(raw)}, sort_keys=True))


if __name__ == "__main__":
    main()
