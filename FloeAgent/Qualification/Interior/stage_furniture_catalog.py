#!/usr/bin/env python3
"""Stage inspected catalog metadata in the design SQLite schema; no App admission."""
import argparse
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import uuid
from zipfile import ZipFile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def localized_names(data):
    # Only the fixed package's simple key=value / Unicode escape subset.
    result={}
    for line in data.decode('ascii').splitlines():
        line=line.strip()
        if not line or line.startswith(('#','!')):
            continue
        if line.endswith('\\') or '=' not in line:
            raise ValueError('Unsupported localized properties syntax')
        key,value=line.split('=',1)
        value=re.sub(r'\\u([0-9a-fA-F]{4})',lambda m:chr(int(m[1],16)),value)
        if '\\' in value:
            raise ValueError('Unsupported localized properties escape')
        result[key]=value
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inspection',required=True,type=Path)
    parser.add_argument('--archive',required=True,type=Path)
    parser.add_argument('--schema',default='docs/design/building-project/schema-v0.sql',type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    report=json.loads(args.inspection.read_text())
    package=args.archive.read_bytes()
    package_sha=digest(package)
    if package_sha!=report['packageSHA256']:
        raise ValueError('Inspection and package mismatch')
    args.output.mkdir(parents=True,exist_ok=False)
    relative='blobs/'+package_sha[:2]+'/'+package_sha+'.zip'
    destination=args.output/relative
    destination.parent.mkdir(parents=True,exist_ok=True)
    try:
        os.link(args.archive,destination)
        storage='hardlink-to-verified-original'
    except OSError:
        shutil.copy2(args.archive,destination)
        storage='copy-of-verified-original'
    assert digest(destination.read_bytes())==package_sha
    with ZipFile(BytesIO(package)) as outer:
        with ZipFile(BytesIO(outer.read('BlendSwap-CC-0.sh3f'))) as inner:
            zh=localized_names(inner.read('PluginFurnitureCatalog_zh_CN.properties'))
    db_path=args.output/'catalog-staging.sqlite'
    db=sqlite3.connect(db_path)
    db.executescript(args.schema.read_text())
    db.execute("INSERT INTO project_state VALUES(1,'catalog-research','家具目录预研',1,0)")
    db.execute('INSERT INTO blob VALUES(?,?,?,?)',(package_sha,len(package),'application/zip',relative))
    db.execute("INSERT INTO source VALUES('catalog','asset_import','Blend Swap CC0 1.9.3')")
    db.execute('INSERT INTO source_version VALUES(?,?,?,?,?,?,?)',('catalog-v1','catalog',1,package_sha,args.archive.name,
        json.dumps({'sourceURL':report['sourceURL'],'packageVersion':'1.9.3'}),'2026-11-12'))
    db.execute('INSERT INTO asset_license VALUES(?,?,?,?,?)',('cc0','CC-0',report['sourceURL'],
        'Creator and per-model license files retained in source package','allowed'))
    first_version=None
    for item in report['entries']:
        identity=str(uuid.uuid5(uuid.NAMESPACE_URL,'SweetHome3D/'+item['sourceAssetID']))
        version=identity+'@1.9.3'
        index=str(item['sourceIndex'])
        name=zh.get('name#'+index,item['name'])
        category=zh.get('category#'+index,item['category'])
        location=identity+'-source'
        locator={'kind':'nested-archive','libraryEntry':'BlendSwap-CC-0.sh3f','modelEntry':item['model']}
        db.execute('INSERT INTO source_location VALUES(?,?,?)',(location,'catalog-v1',json.dumps(locator)))
        metadata=dict(item)
        metadata.update({'sourceLocationID':location,'containerLocator':locator,'nameZhCN':name,
                         'catalogStage':'not-native-admitted','originalPackageSHA256':package_sha})
        encoded=json.dumps(metadata,ensure_ascii=False,sort_keys=True)
        db.execute('INSERT INTO asset_definition VALUES(?,?,?,?,?)',(identity,'furniture',category,name,'catalog'))
        width,depth,height=item['declaredDimensionsMM']
        db.execute('INSERT INTO asset_version VALUES(?,?,?,?,?,?,?,?,?,?)',
            (version,identity,1,'mesh',package_sha,'cc0',width,depth,height,encoded))
        tokens=' '.join([name,item['name'],category,item['category'],item['creator'] or '',item['resourceInspectionState']])
        db.execute('INSERT INTO search_entry(source_version_id,asset_version_id,title,tokens,input_fingerprint) VALUES(?,?,?,?,?)',
            ('catalog-v1',version,name,tokens,digest(encoded.encode())))
        if first_version is None:
            first_version=version
            first_query='"'+name.replace('"','""')+'"'
    db.commit()
    assert db.execute('SELECT count(*) FROM asset_version').fetchone()[0]==175
    assert db.execute('SELECT count(*) FROM asset_release').fetchone()[0]==0
    repair_count=db.execute("SELECT count(*) FROM asset_version WHERE json_extract(metadata_json,'$.resourceInspectionState')='needs-repair'").fetchone()[0]
    assert repair_count==6
    matches=db.execute('SELECT e.asset_version_id FROM search_fts f JOIN search_entry e ON e.id=f.rowid WHERE search_fts MATCH ?',
                       (first_query,)).fetchall()
    assert first_version in [row[0] for row in matches]
    foreign_key_refused=False
    try:
        db.execute("INSERT INTO search_entry(asset_version_id,title,tokens,input_fingerprint) VALUES('missing','bad','bad','bad')")
    except sqlite3.IntegrityError:
        foreign_key_refused=True
        db.rollback()
    assert foreign_key_refused
    backup=sqlite3.connect(args.output/'catalog-backup.sqlite')
    db.backup(backup)
    backup.close()
    db.close()
    reopened=sqlite3.connect(args.output/'catalog-backup.sqlite')
    assert reopened.execute('SELECT count(*) FROM asset_version').fetchone()[0]==175
    reopened.close()
    receipt={'scope':'Catalog staging and retrieval only; no native import or App integration',
        'assetVersions':175,'nativeAdmittedAssetReleases':0,'needsResourceRepair':repair_count,
        'sourceArchiveSHA256':package_sha,'blobStorage':storage,'sourceLocations':175,
        'linkedAssetForeignKeyRefusal':foreign_key_refused,'backupReadback':True,
        'chineseQuery':first_query,'chineseQueryMatchCount':len(matches),
        'schemaSHA256':digest(args.schema.read_bytes()),
        'packageLocatorResolver':'design metadata, not an implemented App archive resolver',
        'remaining':['Native mesh/material validation','Full multilingual tokenization','GRDB/App integration']}
    (args.output/'verification.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(receipt,ensure_ascii=False))


if __name__=='__main__':
    main()
