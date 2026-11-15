#!/usr/bin/env python3
"""Exercise the SQLite design with synthetic records; does not run the App."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-directory', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    output = args.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=True)
    database = output / 'building-design.sqlite'
    if database.exists():
        raise SystemExit('Use a fresh task-owned output directory; existing database preserved.')
    db = sqlite3.connect(':memory:', isolation_level=None)
    db.executescript((root / 'schema-v0.sql').read_text())
    checks = []

    def passed(name):
        checks.append({'name': name, 'result': 'passed'})

    def reject(name, sql, parameters=()):
        try:
            db.execute(sql, parameters)
        except sqlite3.IntegrityError:
            passed(name)
        else:
            raise AssertionError('Invalid operation accepted: ' + name)

    forms = json.loads((root / 'forms-v0.json').read_text())
    keys = {f['key'] for f in forms['fieldDefinitions']}
    assert len(keys) == len(forms['fieldDefinitions'])
    for form in forms['forms']:
        assert form['title']['zh'] and form['title']['en']
        assert all('property' not in f or f['property'] in keys for f in form['fields'])
    for f in forms['fieldDefinitions']:
        db.execute('INSERT INTO field_definition VALUES(?,?,?,?,?,?,?)',
                   (f['key'],f['valueType'],f['unit'],f.get('minimum'),f.get('maximum'),
                    f['label']['zh'],f['label']['en']))
    passed('shared form keys and bilingual labels')
    db.execute("INSERT INTO project_state VALUES(1,'demo-project','合成住宅',0,0)")
    for row in [('building','building',None,'住宅'),('floor','storey','building','一层'),
                ('kitchen','room','floor','厨房'),('bedroom','room','floor','卧室'),
                ('cabinet','cabinet','kitchen','收纳柜')]:
        db.execute('INSERT INTO object(id,kind,parent_id,name) VALUES(?,?,?,?)',row)
    reject('hierarchy cycle rejected',"UPDATE object SET parent_id='kitchen' WHERE id='floor'")

    raw = '合成记录：厨房长3.6m；另一份现场记录为4.0m。'.encode()
    digest = hashlib.sha256(raw).hexdigest()
    (output/'sources').mkdir()
    (output/'sources'/'note.txt').write_bytes(raw)
    db.execute('INSERT INTO blob VALUES(?,?,?,?)',(digest,len(raw),'text/plain','sources/note.txt'))
    db.execute("INSERT INTO source VALUES('note','note','合成现场说明')")
    db.execute('INSERT INTO source_version VALUES(?,?,?,?,?,?,?)',
               ('note-v1','note',1,digest,'note.txt','{}','2026-11-12T00:00:00Z'))
    db.execute("INSERT INTO source_location VALUES('loc','note-v1','{\"textRange\":[0,24]}')")
    db.execute("INSERT INTO object_source VALUES('kitchen','loc','measurement')")
    observation_sql = 'INSERT INTO observation VALUES(?,?,?,?,?,?,?,?,?,?,?)'

    def observation(identifier, value, unit='mm', object_id='kitchen', kind='number'):
        return (identifier,object_id,'room.requested_length',kind,unit,value,None,None,
                'manual_measurement','loc','2026-11-12T00:00:00Z')

    db.execute(observation_sql,observation('obs-3600',3600))
    db.execute(observation_sql,observation('obs-4000',4000))
    db.execute("INSERT INTO decision VALUES('decision-1','user','暂采用手绘尺寸','2026-11-12T00:00:00Z')")
    db.execute("INSERT INTO adoption VALUES('adoption-1','kitchen','room.requested_length','obs-3600','decision-1',NULL)")
    db.execute("INSERT INTO current_fact VALUES('kitchen','room.requested_length','adoption-1')")
    assert db.execute('SELECT count(*) FROM observation').fetchone()[0] == 2
    assert db.execute('SELECT number_value FROM adopted_fields').fetchone()[0] == 3600
    passed('conflicting observations preserved without replacing adopted value')
    reject('unit mismatch rejected',observation_sql,observation('bad-unit',3.6,'m'))
    reject('negative design length rejected',observation_sql,observation('bad-length',-20))
    reject('typed value mismatch rejected',observation_sql,observation('bad-type',3600,kind='text'))
    reject('cross-room adoption rejected',
           "INSERT INTO adoption VALUES('bad-room','bedroom','room.requested_length','obs-3600','decision-1',NULL)")
    reject('source version immutable',"UPDATE source_version SET version=2 WHERE id='note-v1'")
    reject('measurement history immutable',"UPDATE observation SET number_value=4000 WHERE id='obs-3600'")
    reject('resolved issue requires decision',
           "INSERT INTO issue VALUES('bad-issue','kitchen','room.requested_length','dimension_conflict','conflict','resolved',NULL)")

    before = db.execute('SELECT count(*) FROM observation').fetchone()[0]
    db.execute('BEGIN IMMEDIATE')
    db.execute(observation_sql,observation('rolled-back',3900))
    db.execute('ROLLBACK')
    assert db.execute('SELECT count(*) FROM observation').fetchone()[0] == before
    passed('interrupted record transaction rolls back')
    db.execute('BEGIN IMMEDIATE')
    cursor = db.execute('UPDATE project_state SET records_revision=records_revision+1 WHERE singleton=1 AND records_revision=?',(0,))
    assert cursor.rowcount == 1
    db.execute("INSERT INTO decision VALUES('decision-2','user','用户明确采用现场4m','2026-11-12T00:01:00Z')")
    db.execute("INSERT INTO adoption VALUES('adoption-2','kitchen','room.requested_length','obs-4000','decision-2','adoption-1')")
    db.execute("UPDATE current_fact SET adoption_id='adoption-2' WHERE object_id='kitchen' AND field_key='room.requested_length'")
    db.execute('COMMIT')
    assert db.execute('SELECT number_value FROM adopted_fields').fetchone()[0] == 4000
    assert db.execute('SELECT count(*) FROM adoption').fetchone()[0] == 2
    stale = db.execute('UPDATE project_state SET records_revision=records_revision+1 WHERE singleton=1 AND records_revision=?',(0,))
    assert stale.rowcount == 0
    passed('revision compare-and-swap rejects stale revision')
    passed('adoption changes preserve previous decision chain')

    db.execute("INSERT INTO asset_license VALUES('synthetic','user-authored','urn:synthetic-fixture','','unknown')")
    db.execute("INSERT INTO asset_definition VALUES('asset','cabinet_template','storage','合成参数柜','user_authored')")
    (output/'assets').mkdir()
    for version in (1,2,3):
        width = 2400+version*100
        recipe = json.dumps({'prototypeOnly':True,'kind':'cabinet','parametersMM':{'width':width,'depth':600,'height':2400}}).encode()
        recipe_digest = hashlib.sha256(recipe).hexdigest()
        relative_path = f'assets/synthetic-recipe-v{version}.json'
        (output/relative_path).write_bytes(recipe)
        db.execute('INSERT INTO blob VALUES(?,?,?,?)',(recipe_digest,len(recipe),'application/json',relative_path))
        db.execute('INSERT INTO asset_version VALUES(?,?,?,?,?,?,?,?,?,?)',
                   (f'asset-v{version}','asset',version,'parametric',recipe_digest,'synthetic',width,600,2400,'{}'))
    identity = json.dumps([1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
    reject('unreleased asset cannot be placed','INSERT INTO asset_instance VALUES(?,?,?,?)',('cabinet','asset-v1',identity,'{}'))
    db.execute("INSERT INTO asset_dependency VALUES('asset-v1','asset-v2')")
    reject('incomplete asset dependency cannot be released',"INSERT INTO asset_release VALUES('asset-v1','now')")
    reject('asset dependency cycle rejected',"INSERT INTO asset_dependency VALUES('asset-v2','asset-v1')")
    db.execute("INSERT INTO asset_release VALUES('asset-v2','now')")
    db.execute("INSERT INTO asset_release VALUES('asset-v1','now')")
    db.execute('INSERT INTO asset_instance VALUES(?,?,?,?)',('cabinet','asset-v1',identity,'{}'))
    reject('released asset dependency cannot drift',"INSERT INTO asset_dependency VALUES('asset-v1','asset-v3')")
    reject('released asset content cannot drift',"UPDATE asset_version SET width_mm=999 WHERE id='asset-v1'")
    db.execute("INSERT INTO asset_release VALUES('asset-v3','now')")
    assert db.execute('SELECT asset_version_id FROM asset_instance').fetchone()[0] == 'asset-v1'
    passed('new library version leaves placed instance pinned')

    db.execute("INSERT INTO operation VALUES('op','request-1','generate_asset',NULL,'queued','synthetic','v0',?,1,0,'{}',NULL,'{}')",(digest,))
    reject('duplicate operation key rejected',"INSERT INTO operation SELECT 'op2',operation_key,kind,service_job_id,state,engine_id,engine_version,payload_sha256,expected_records_revision,expected_model_revision,input_json,output_asset_version_id,result_json FROM operation WHERE id='op'")
    db.execute('INSERT INTO search_entry(id,object_id,source_version_id,title,tokens,input_fingerprint) VALUES(1,?,?,?,?,?)',('kitchen','note-v1','一层厨房','厨房 长度 4000 净高',digest))
    assert db.execute("SELECT rowid FROM search_fts WHERE search_fts MATCH ?",('厨房',)).fetchall() == [(1,)]
    db.execute("INSERT INTO search_fts(search_fts) VALUES('rebuild')")
    assert db.execute("SELECT rowid FROM search_fts WHERE search_fts MATCH ?",('净高',)).fetchall() == [(1,)]
    passed('Chinese fixture tokens searchable and index rebuildable')
    assert not db.execute('PRAGMA foreign_key_check').fetchall()
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    passed('database referential integrity')
    for sha,length,path in db.execute('SELECT sha256,byte_length,relative_path FROM blob'):
        data=(output/path).read_bytes()
        assert len(data)==length and hashlib.sha256(data).hexdigest()==sha
    passed('synthetic source and recipe files match registered hashes')

    destination = sqlite3.connect(database)
    db.backup(destination)
    destination.close()
    db.close()
    reopened = sqlite3.connect(database)
    assert reopened.execute('SELECT number_value FROM adopted_fields').fetchone()[0] == 4000
    assert reopened.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    reopened.close()
    passed('SQLite backup and reopen retain adopted data')
    report = {'status':'passed','scope':'SQLite design and synthetic records only; no native UI, GRDB build, geometry conversion, filesystem source ingestion, GPU inference or cross-store commit tested',
              'sqliteVersion':sqlite3.sqlite_version,'checks':checks,'formCount':len(forms['forms']),
              'schemaSHA256':hashlib.sha256((root/'schema-v0.sql').read_bytes()).hexdigest(),
              'databaseSHA256':hashlib.sha256(database.read_bytes()).hexdigest()}
    (output/'verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'status':'passed','checks':len(checks),'forms':len(forms['forms']),'database':str(database)},ensure_ascii=False))


if __name__ == '__main__':
    main()
