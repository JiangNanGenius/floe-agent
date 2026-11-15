#!/usr/bin/env python3
"""Inspect the fixed CC0 SH3F package; this is not an App/general importer."""
import argparse
from collections import Counter
import hashlib
from io import BytesIO
import json
import math
from pathlib import Path, PurePosixPath
import posixpath
import stat
from zipfile import ZipFile

EXPECTED_SHA = 'f87b1689df18a1b4302446dcb51922eca4d93ae9f388cf86624eb633f3068c39'
SOURCE_URL = 'https://sourceforge.net/projects/sweethome3d/files/SweetHome3D-models/3DModels-1.9.3/3DModels-BlendSwap-CC-0-1.9.3.zip/download'
UNITS_URL = 'https://www.sweethome3d.com/javadoc/com/eteks/sweethome3d/io/DefaultFurnitureCatalog.PropertyKey.html'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_name(name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
        raise ValueError('Unsupported archive path: '+name)
    return name


def properties(data):
    # This pinned base catalog is ASCII, with no escaped or continued values.
    # Fail on another syntax rather than impersonating a Java Properties reader.
    result = {}
    for line in data.decode('ascii').splitlines():
        line = line.strip()
        if not line or line.startswith(('#', '!')):
            continue
        if '\\' in line or '=' not in line:
            raise ValueError('Unsupported properties syntax')
        key, value = line.split('=', 1)
        if key in result:
            raise ValueError('Duplicate catalog property: '+key)
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    package = args.archive.read_bytes()
    if sha(package) != EXPECTED_SHA:
        raise ValueError('Package differs from the fixed official download digest')
    args.output.mkdir(parents=True, exist_ok=False)
    issues, records, inventory = [], [], []
    with ZipFile(BytesIO(package)) as outer:
        license_data = outer.read('LICENSE.TXT')
        (args.output/'package-license.txt').write_bytes(license_data)
        (args.output/'package-readme.txt').write_bytes(outer.read('README.TXT'))
        library = outer.read('BlendSwap-CC-0.sh3f')
    with ZipFile(BytesIO(library)) as archive:
        entries = archive.infolist()
        if len(entries)>2000 or sum(i.file_size for i in entries)>200*1024*1024:
            raise ValueError('Fixture package exceeds research inspection bounds')
        names = set()
        for item in entries:
            safe_name(item.filename)
            if item.filename in names or stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError('Duplicate path or symbolic link in package')
            names.add(item.filename)
            if not item.is_dir():
                data = archive.read(item)
                inventory.append({'path':item.filename,'bytes':len(data),'sha256':sha(data)})
        raw = archive.read('PluginFurnitureCatalog.properties')
        (args.output/'PluginFurnitureCatalog.properties').write_bytes(raw)
        catalog = properties(raw)
        indexes = sorted(int(key[6:]) for key in catalog if key.startswith('model#'))
        if len(indexes)!=175 or len({catalog['id#'+str(i)] for i in indexes})!=175:
            raise ValueError('Unexpected catalog entry count or duplicate identity')
        for index in indexes:
            def field(key, default=None):
                return catalog.get(key+'#'+str(index), default)
            model = safe_name(field('model').removeprefix('/'))
            icon = safe_name(field('icon').removeprefix('/'))
            if model not in names or icon not in names:
                raise ValueError('Missing model/icon: '+str(index))
            dimensions = [float(field(k)) for k in ['width','depth','height']]
            if not all(math.isfinite(v) and v>0 for v in dimensions):
                raise ValueError('Invalid declared dimensions: '+str(index))
            if field('license')!='CC-0':
                raise ValueError('Unexpected per-entry license: '+str(index))
            folder = str(PurePosixPath(model).parent)+'/'
            dependencies = [row for row in inventory if row['path'].startswith(folder)]
            obj = archive.read(model).decode('utf-8-sig', errors='replace')
            vertices, faces, triangle_estimate, material_files = [], 0, 0, []
            for line in obj.splitlines():
                parts = line.split()
                if not parts:
                    continue
                if parts[0]=='v':
                    point = [float(v) for v in parts[1:4]]
                    if len(point)!=3 or not all(math.isfinite(v) for v in point):
                        raise ValueError('Invalid vertex: '+model)
                    vertices.append(point)
                elif parts[0]=='f':
                    faces += 1
                    triangle_estimate += max(0, len(parts)-3)
                    for token in parts[1:]:
                        value = int(token.split('/')[0])
                        resolved = value if value>0 else len(vertices)+value+1
                        if value==0 or resolved<1 or resolved>len(vertices):
                            issues.append({'model':model,'kind':'vertex-reference','value':value})
                elif parts[0]=='mtllib':
                    # The selected package uses one plain local path per line.
                    reference = line.strip().split(None,1)[1]
                    material_files.append(posixpath.normpath(posixpath.join(folder, reference)))
            if not vertices or not faces:
                raise ValueError('Empty mesh: '+model)
            for material in material_files:
                try:
                    safe_name(material)
                except ValueError:
                    issues.append({'model':model,'kind':'unsupported-material-reference','path':material})
                    continue
                if material not in names:
                    issues.append({'model':model,'kind':'missing-material','path':material})
                    continue
                for line in archive.read(material).decode('utf-8-sig', errors='replace').splitlines():
                    parts = line.strip().split(None, 1)
                    if parts and (parts[0].startswith('map_') or parts[0] in ['bump','disp','norm']):
                        if len(parts)!=2 or parts[1].startswith('-'):
                            issues.append({'model':model,'kind':'unsupported-texture-directive','line':line})
                            continue
                        texture = posixpath.normpath(posixpath.join(posixpath.dirname(material), parts[1]))
                        try:
                            safe_name(texture)
                        except ValueError:
                            basename = parts[1].replace('\\','/').rsplit('/',1)[-1].strip('"')
                            candidates = [row['path'] for row in dependencies
                                          if PurePosixPath(row['path']).name==basename]
                            issues.append({'model':model,'kind':'unsupported-texture-reference',
                                           'path':parts[1],'notReadAsHostPath':True,
                                           'proposedPackageCandidates':candidates,'repairApplied':False})
                            continue
                        if texture not in names:
                            issues.append({'model':model,'kind':'missing-texture','path':texture})
            model_issues = [issue for issue in issues if issue['model']==model]
            records.append({
                'sourceAssetID':field('id'),'sourceIndex':index,'sourceVersion':catalog['version'],
                'name':field('name'),'category':field('category'),'creator':field('creator'),
                'license':field('license'),'model':model,'icon':icon,
                'declaredDimensionsCM':dimensions,'declaredDimensionsMM':[v*10 for v in dimensions],
                'dimensionBasis':'Catalog declaration, not a physical measurement or native mesh normalization',
                'modelRotationRaw':field('modelRotation'),'multiPartModel':field('multiPartModel'),
                'rawVertexBoundsXYZ':[[min(v[a] for v in vertices) for a in range(3)],
                                      [max(v[a] for v in vertices) for a in range(3)]],
                'vertices':len(vertices),'polygons':faces,'triangleEstimate':triangle_estimate,
                'triangleEstimateBasis':'sum(n-2), not a triangulation/geometry validity proof',
                'dependentFolderFiles':dependencies,'representation':'visual-mesh',
                'resourceInspectionState':'needs-repair' if model_issues else 'basic-references-checked',
                'resourceIssues':model_issues,
                'nativeImportAndAppearanceVerified':False,'manufacturingVerified':False,
            })
        # Keep one small complete sample with its original license and icon.
        sample = next(r for r in records if r['sourceAssetID']=='Blend Swap CC-0#armchair')
        for row in sample['dependentFolderFiles']:
            destination = args.output/'sample'/row['path']
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(archive.read(row['path']))
        icon_path = args.output/'sample'/sample['icon']
        icon_path.parent.mkdir(parents=True, exist_ok=True)
        icon_path.write_bytes(archive.read(sample['icon']))
    report = {
        'scope':'Fixed library resource inspection, not App admission or native rendering',
        'sourceURL':SOURCE_URL,'unitReference':UNITS_URL,'packageSHA256':EXPECTED_SHA,
        'packageBytes':len(package),'librarySHA256':sha(library),'libraryBytes':len(library),
        'entryCount':len(records),'fileCount':len(inventory),
        'modelExtensions':dict(Counter(PurePosixPath(r['model']).suffix for r in records)),
        'licenseCounts':dict(Counter(r['license'] for r in records)),
        'resourceInspectionCounts':dict(Counter(r['resourceInspectionState'] for r in records)),
        'issues':issues,'entries':records,'files':inventory,
        'remaining':['Full OBJ/MTL parser qualification','Native normalization, rendering and materials',
                     'Front/anchor selection and plan symbols','App database/library integration'],
    }
    (args.output/'catalog-inspection.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'entries':len(records),'files':len(inventory),'dependencyIssues':len(issues),
                      'nativeImportVerified':False}))


if __name__=='__main__':
    main()
