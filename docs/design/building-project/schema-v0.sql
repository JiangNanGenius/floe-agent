-- Executable design prototype. Not an application migration or geometry store.
PRAGMA foreign_keys = ON;
PRAGMA user_version = 1;

CREATE TABLE project_state (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
  project_id TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  records_revision INTEGER NOT NULL DEFAULT 0 CHECK(records_revision >= 0),
  model_revision INTEGER NOT NULL DEFAULT 0 CHECK(model_revision >= 0)
);

CREATE TABLE object (
  id TEXT PRIMARY KEY NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('building','storey','room','wall','slab','roof','door','window','column','beam','stair','furniture','cabinet','fixture','mep','custom')),
  parent_id TEXT REFERENCES object(id),
  name TEXT NOT NULL,
  lifecycle TEXT NOT NULL DEFAULT 'active' CHECK(lifecycle IN ('active','retired')),
  CHECK(parent_id IS NULL OR parent_id <> id)
);
CREATE INDEX object_parent ON object(parent_id, kind, lifecycle);
CREATE TRIGGER object_no_cycle BEFORE UPDATE OF parent_id ON object BEGIN
  SELECT CASE WHEN EXISTS (
    WITH RECURSIVE parents(id,parent_id) AS (
      SELECT id,parent_id FROM object WHERE id=NEW.parent_id
      UNION SELECT o.id,o.parent_id FROM object o JOIN parents p ON o.id=p.parent_id
    ) SELECT 1 FROM parents WHERE id=NEW.id
  ) THEN RAISE(ABORT,'object hierarchy cycle') END;
END;
CREATE TABLE object_alias (
  object_id TEXT NOT NULL REFERENCES object(id), alias TEXT NOT NULL,
  PRIMARY KEY(object_id, alias)
);

CREATE TABLE blob (
  sha256 TEXT PRIMARY KEY NOT NULL CHECK(length(sha256)=64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
  byte_length INTEGER NOT NULL CHECK(byte_length >= 0),
  media_type TEXT NOT NULL,
  relative_path TEXT NOT NULL UNIQUE CHECK(relative_path NOT LIKE '/%' AND instr(relative_path,'..')=0 AND instr(relative_path,char(92))=0)
);
CREATE TABLE source (
  id TEXT PRIMARY KEY NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('sketch','photo','document','scan','note','cad','asset_import','ai_request')),
  title TEXT NOT NULL
);
CREATE TABLE source_version (
  id TEXT PRIMARY KEY NOT NULL,
  source_id TEXT NOT NULL REFERENCES source(id),
  version INTEGER NOT NULL CHECK(version > 0),
  blob_sha256 TEXT NOT NULL REFERENCES blob(sha256),
  original_name TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(metadata_json) AND json_type(metadata_json)='object'),
  created_at TEXT NOT NULL,
  UNIQUE(source_id,version)
);
CREATE TABLE source_location (
  id TEXT PRIMARY KEY NOT NULL,
  source_version_id TEXT NOT NULL REFERENCES source_version(id),
  locator_json TEXT NOT NULL CHECK(json_valid(locator_json) AND json_type(locator_json)='object')
);
CREATE TABLE object_source (
  object_id TEXT NOT NULL REFERENCES object(id),
  location_id TEXT NOT NULL REFERENCES source_location(id),
  role TEXT NOT NULL CHECK(role IN ('reference','measurement','requirement','generated_from')),
  PRIMARY KEY(object_id,location_id,role)
);

-- Form definitions and typed observations share these keys. Geometry stays in CAD.
CREATE TABLE field_definition (
  key TEXT PRIMARY KEY NOT NULL,
  value_type TEXT NOT NULL CHECK(value_type IN ('number','integer','text','boolean')),
  unit TEXT NOT NULL DEFAULT '',
  minimum REAL, maximum REAL,
  label_zh TEXT NOT NULL, label_en TEXT NOT NULL,
  CHECK(minimum IS NULL OR maximum IS NULL OR minimum <= maximum),
  UNIQUE(key,value_type,unit)
);
CREATE TABLE observation (
  id TEXT PRIMARY KEY NOT NULL,
  object_id TEXT NOT NULL REFERENCES object(id),
  field_key TEXT NOT NULL,
  value_type TEXT NOT NULL,
  unit TEXT NOT NULL,
  number_value REAL,
  text_value TEXT,
  boolean_value INTEGER CHECK(boolean_value IN (0,1)),
  origin TEXT NOT NULL CHECK(origin IN ('user','manual_measurement','ar','lidar','ai_extracted','ai_inferred','calculated')),
  location_id TEXT NOT NULL REFERENCES source_location(id),
  created_at TEXT NOT NULL,
  FOREIGN KEY(field_key,value_type,unit) REFERENCES field_definition(key,value_type,unit),
  UNIQUE(id,object_id,field_key),
  CHECK(
    (value_type IN ('number','integer') AND number_value IS NOT NULL AND text_value IS NULL AND boolean_value IS NULL AND number_value BETWEEN -1e12 AND 1e12 AND (value_type='number' OR number_value=round(number_value))) OR
    (value_type='text' AND text_value IS NOT NULL AND number_value IS NULL AND boolean_value IS NULL) OR
    (value_type='boolean' AND boolean_value IS NOT NULL AND number_value IS NULL AND text_value IS NULL)
  )
);
CREATE INDEX observation_lookup ON observation(object_id,field_key,created_at);
CREATE TRIGGER observation_range BEFORE INSERT ON observation BEGIN
  SELECT CASE WHEN EXISTS (
    SELECT 1 FROM field_definition f WHERE f.key=NEW.field_key AND NEW.number_value IS NOT NULL
      AND ((f.minimum IS NOT NULL AND NEW.number_value<f.minimum) OR (f.maximum IS NOT NULL AND NEW.number_value>f.maximum))
  ) THEN RAISE(ABORT,'normalized value outside field range; keep raw input as source/issue') END;
END;
CREATE TABLE decision (
  id TEXT PRIMARY KEY NOT NULL,
  actor TEXT NOT NULL CHECK(actor IN ('user','assistant','system')),
  reason TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE adoption (
  id TEXT PRIMARY KEY NOT NULL,
  object_id TEXT NOT NULL REFERENCES object(id),
  field_key TEXT NOT NULL REFERENCES field_definition(key),
  observation_id TEXT NOT NULL,
  decision_id TEXT NOT NULL REFERENCES decision(id),
  supersedes_id TEXT,
  FOREIGN KEY(observation_id,object_id,field_key) REFERENCES observation(id,object_id,field_key),
  FOREIGN KEY(supersedes_id,object_id,field_key) REFERENCES adoption(id,object_id,field_key),
  CHECK(supersedes_id IS NULL OR supersedes_id<>id),
  UNIQUE(id,object_id,field_key)
);
CREATE TABLE current_fact (
  object_id TEXT NOT NULL REFERENCES object(id),
  field_key TEXT NOT NULL REFERENCES field_definition(key),
  adoption_id TEXT NOT NULL,
  PRIMARY KEY(object_id,field_key),
  FOREIGN KEY(adoption_id,object_id,field_key) REFERENCES adoption(id,object_id,field_key)
);
CREATE TABLE issue (
  id TEXT PRIMARY KEY NOT NULL,
  object_id TEXT REFERENCES object(id),
  field_key TEXT REFERENCES field_definition(key),
  code TEXT NOT NULL,
  message TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('open','resolved','dismissed')),
  decision_id TEXT REFERENCES decision(id),
  CHECK((state='open' AND decision_id IS NULL) OR (state<>'open' AND decision_id IS NOT NULL))
);
CREATE TABLE model_binding (
  object_id TEXT NOT NULL REFERENCES object(id),
  native_id TEXT NOT NULL,
  role TEXT NOT NULL,
  model_revision INTEGER NOT NULL CHECK(model_revision>=0),
  PRIMARY KEY(object_id,native_id,role)
);

CREATE TABLE asset_license (
  id TEXT PRIMARY KEY NOT NULL,
  identifier TEXT NOT NULL,
  source_url TEXT NOT NULL,
  attribution TEXT NOT NULL DEFAULT '',
  redistribution TEXT NOT NULL CHECK(redistribution IN ('allowed','conditional','not_granted','unknown'))
);
CREATE TABLE asset_definition (
  id TEXT PRIMARY KEY NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('furniture','material','hardware','cabinet_template')),
  category TEXT NOT NULL,
  name TEXT NOT NULL,
  origin TEXT NOT NULL CHECK(origin IN ('catalog','user_import','ai_generated','user_authored'))
);
CREATE TABLE asset_version (
  id TEXT PRIMARY KEY NOT NULL,
  definition_id TEXT NOT NULL REFERENCES asset_definition(id),
  version INTEGER NOT NULL CHECK(version>0),
  geometry_kind TEXT NOT NULL CHECK(geometry_kind IN ('mesh','parametric','brep','material','assembly')),
  blob_sha256 TEXT NOT NULL REFERENCES blob(sha256),
  license_id TEXT NOT NULL REFERENCES asset_license(id),
  width_mm REAL CHECK(width_mm>0), depth_mm REAL CHECK(depth_mm>0), height_mm REAL CHECK(height_mm>0),
  metadata_json TEXT NOT NULL CHECK(json_valid(metadata_json) AND json_type(metadata_json)='object'),
  UNIQUE(definition_id,version)
);
CREATE TABLE asset_dependency (
  asset_version_id TEXT NOT NULL REFERENCES asset_version(id),
  dependency_version_id TEXT NOT NULL REFERENCES asset_version(id),
  PRIMARY KEY(asset_version_id,dependency_version_id),
  CHECK(asset_version_id<>dependency_version_id)
);
CREATE TABLE asset_release (
  asset_version_id TEXT PRIMARY KEY NOT NULL REFERENCES asset_version(id),
  created_at TEXT NOT NULL
);
CREATE TRIGGER dependency_no_cycle BEFORE INSERT ON asset_dependency BEGIN
  SELECT CASE WHEN EXISTS (
    WITH RECURSIVE deps(id) AS (
      SELECT dependency_version_id FROM asset_dependency WHERE asset_version_id=NEW.dependency_version_id
      UNION SELECT d.dependency_version_id FROM asset_dependency d JOIN deps p ON d.asset_version_id=p.id
    ) SELECT 1 FROM deps WHERE id=NEW.asset_version_id
  ) THEN RAISE(ABORT,'asset dependency cycle') END;
  SELECT CASE WHEN EXISTS (SELECT 1 FROM asset_release WHERE asset_version_id=NEW.asset_version_id)
    THEN RAISE(ABORT,'append a new asset version to change dependencies') END;
END;
CREATE TRIGGER dependency_no_update BEFORE UPDATE ON asset_dependency BEGIN SELECT RAISE(ABORT,'append asset version'); END;
CREATE TRIGGER dependency_no_delete BEFORE DELETE ON asset_dependency
WHEN EXISTS (SELECT 1 FROM asset_release WHERE asset_version_id=OLD.asset_version_id)
BEGIN SELECT RAISE(ABORT,'released dependencies are immutable'); END;
CREATE TRIGGER asset_release_complete BEFORE INSERT ON asset_release BEGIN
  SELECT CASE WHEN EXISTS (
    SELECT 1 FROM asset_dependency d WHERE d.asset_version_id=NEW.asset_version_id
      AND NOT EXISTS (SELECT 1 FROM asset_release r WHERE r.asset_version_id=d.dependency_version_id)
  ) THEN RAISE(ABORT,'dependency version is not released') END;
END;
CREATE TABLE asset_instance (
  object_id TEXT PRIMARY KEY NOT NULL REFERENCES object(id),
  asset_version_id TEXT NOT NULL REFERENCES asset_release(asset_version_id),
  transform_json TEXT NOT NULL CHECK(json_valid(transform_json) AND json_type(transform_json)='array' AND json_array_length(transform_json)=16),
  parameters_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(parameters_json) AND json_type(parameters_json)='object')
);

-- Project history of existing service-owned jobs; not a second scheduler.
CREATE TABLE operation (
  id TEXT PRIMARY KEY NOT NULL,
  operation_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK(kind IN ('import','extract','convert','generate_asset','edit_model','export')),
  service_job_id TEXT,
  state TEXT NOT NULL CHECK(state IN ('queued','running','prepared','completed','failed','cancelled')),
  engine_id TEXT NOT NULL,
  engine_version TEXT NOT NULL,
  payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256)=64 AND payload_sha256 NOT GLOB '*[^0-9a-f]*'),
  expected_records_revision INTEGER NOT NULL CHECK(expected_records_revision>=0),
  expected_model_revision INTEGER NOT NULL CHECK(expected_model_revision>=0),
  input_json TEXT NOT NULL CHECK(json_valid(input_json) AND json_type(input_json)='object'),
  output_asset_version_id TEXT REFERENCES asset_version(id),
  result_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(result_json) AND json_type(result_json)='object')
);

CREATE TABLE search_entry (
  id INTEGER PRIMARY KEY,
  object_id TEXT REFERENCES object(id),
  source_version_id TEXT REFERENCES source_version(id),
  asset_version_id TEXT REFERENCES asset_version(id),
  title TEXT NOT NULL,
  tokens TEXT NOT NULL,
  input_fingerprint TEXT NOT NULL
);
CREATE INDEX search_entry_asset ON search_entry(asset_version_id);
CREATE VIRTUAL TABLE search_fts USING fts5(title,tokens,content='search_entry',content_rowid='id',tokenize='unicode61');
CREATE TRIGGER search_insert AFTER INSERT ON search_entry BEGIN
  INSERT INTO search_fts(rowid,title,tokens) VALUES(NEW.id,NEW.title,NEW.tokens);
END;
CREATE TRIGGER search_delete AFTER DELETE ON search_entry BEGIN
  INSERT INTO search_fts(search_fts,rowid,title,tokens) VALUES('delete',OLD.id,OLD.title,OLD.tokens);
END;
CREATE TRIGGER search_update AFTER UPDATE ON search_entry BEGIN
  INSERT INTO search_fts(search_fts,rowid,title,tokens) VALUES('delete',OLD.id,OLD.title,OLD.tokens);
  INSERT INTO search_fts(rowid,title,tokens) VALUES(NEW.id,NEW.title,NEW.tokens);
END;

CREATE VIEW adopted_fields AS
SELECT c.object_id,c.field_key,o.value_type,o.unit,o.number_value,o.text_value,o.boolean_value,
       o.origin,o.location_id,a.id AS adoption_id,a.decision_id
FROM current_fact c JOIN adoption a ON a.id=c.adoption_id JOIN observation o ON o.id=a.observation_id;

CREATE TRIGGER source_version_immutable BEFORE UPDATE ON source_version BEGIN SELECT RAISE(ABORT,'append source version'); END;
CREATE TRIGGER observation_immutable BEFORE UPDATE ON observation BEGIN SELECT RAISE(ABORT,'append observation'); END;
CREATE TRIGGER adoption_immutable BEFORE UPDATE ON adoption BEGIN SELECT RAISE(ABORT,'append adoption'); END;
CREATE TRIGGER asset_version_immutable BEFORE UPDATE ON asset_version BEGIN SELECT RAISE(ABORT,'append asset version'); END;
CREATE TRIGGER asset_release_immutable BEFORE UPDATE ON asset_release BEGIN SELECT RAISE(ABORT,'append asset version'); END;
CREATE TRIGGER asset_release_no_delete BEFORE DELETE ON asset_release BEGIN SELECT RAISE(ABORT,'retire asset definition instead'); END;
