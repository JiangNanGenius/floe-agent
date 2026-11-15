import Foundation

/// Versioned SQLite schema. The strings are intentionally static so the
/// non-native schema check can execute the exact statements shipped by the
/// migration without invoking the Swift toolchain.
enum RecordsSchema {
    static let v1Records: [String] = [
        """
        CREATE TABLE project_state (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            project_id TEXT NOT NULL UNIQUE CHECK (length(project_id) = 36),
            name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 200),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            records_revision INTEGER NOT NULL DEFAULT 0 CHECK (records_revision >= 0)
        )
        """,
        """
        CREATE TABLE room (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project_state(project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 200),
            storey TEXT CHECK (storey IS NULL OR length(storey) <= 80),
            kind TEXT NOT NULL CHECK (kind IN (
                'living_room','bedroom','kitchen','bathroom','dining','study','balcony',
                'hallway','storage','garage','office','utility','other'
            )),
            notes TEXT NOT NULL DEFAULT '' CHECK (length(notes) <= 20000),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE room_alias (
            room_id TEXT NOT NULL REFERENCES room(id) ON DELETE CASCADE,
            alias TEXT NOT NULL CHECK (length(trim(alias)) BETWEEN 1 AND 200),
            PRIMARY KEY (room_id, alias)
        )
        """,
        """
        CREATE INDEX room_project ON room(project_id, storey, name)
        """,
        """
        CREATE INDEX room_alias_alias ON room_alias(alias)
        """,
        """
        CREATE TRIGGER room_alias_unique_ci
        BEFORE INSERT ON room_alias
        WHEN EXISTS (
            SELECT 1 FROM room_alias a
            WHERE a.room_id = NEW.room_id AND lower(a.alias) = lower(NEW.alias)
        )
        BEGIN
            SELECT RAISE(ABORT, 'duplicate room alias');
        END
        """,
        """
        CREATE TABLE content_blob (
            sha256 TEXT PRIMARY KEY NOT NULL
                CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
            byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
            media_type TEXT NOT NULL CHECK (length(trim(media_type)) BETWEEN 1 AND 200),
            relative_path TEXT NOT NULL UNIQUE CHECK (
                relative_path NOT LIKE '/%'
                AND instr(relative_path, '..') = 0
                AND instr(relative_path, char(92)) = 0
            ),
            created_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE source (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project_state(project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            kind TEXT NOT NULL CHECK (kind IN (
                'sketch','photo','document','scan','note','cad',
                'asset_import','ai_request','table','other'
            )),
            title TEXT NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 200),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE INDEX source_project ON source(project_id, updated_at DESC)
        """,
        """
        CREATE TABLE source_version (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES source(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            version INTEGER NOT NULL CHECK (version > 0),
            sha256 TEXT NOT NULL REFERENCES content_blob(sha256) ON UPDATE RESTRICT ON DELETE RESTRICT,
            original_name TEXT NOT NULL CHECK (length(original_name) BETWEEN 1 AND 255),
            media_type TEXT NOT NULL CHECK (length(trim(media_type)) BETWEEN 1 AND 200),
            byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
            note TEXT NOT NULL DEFAULT '' CHECK (length(note) <= 20000),
            imported_at TEXT NOT NULL,
            UNIQUE (source_id, version)
        )
        """,
        """
        CREATE INDEX source_version_lookup ON source_version(source_id, version DESC)
        """,
        """
        CREATE TRIGGER source_version_immutable_update
        BEFORE UPDATE ON source_version
        BEGIN
            SELECT RAISE(ABORT, 'source versions are immutable');
        END
        """,
        """
        CREATE TRIGGER source_version_immutable_delete
        BEFORE DELETE ON source_version
        BEGIN
            SELECT RAISE(ABORT, 'source versions are immutable');
        END
        """,
        """
        CREATE TABLE source_room (
            source_id TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
            room_id TEXT NOT NULL REFERENCES room(id) ON DELETE CASCADE,
            linked_at TEXT NOT NULL,
            PRIMARY KEY (source_id, room_id)
        )
        """,
        """
        CREATE INDEX source_room_room ON source_room(room_id)
        """,
        """
        CREATE TABLE import_operation (
            operation_key TEXT PRIMARY KEY NOT NULL CHECK (length(operation_key) BETWEEN 1 AND 1024),
            project_id TEXT NOT NULL REFERENCES project_state(project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            request_fingerprint TEXT NOT NULL
                CHECK (length(request_fingerprint) = 64 AND request_fingerprint NOT GLOB '*[^0-9a-f]*'),
            source_id TEXT NOT NULL REFERENCES source(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            source_version_id TEXT NOT NULL REFERENCES source_version(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            created_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE observation (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project_state(project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            room_id TEXT NOT NULL REFERENCES room(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            property_key TEXT NOT NULL CHECK (length(property_key) BETWEEN 1 AND 64),
            raw_value TEXT NOT NULL CHECK (length(raw_value) BETWEEN 1 AND 20000),
            value_kind TEXT CHECK (value_kind IS NULL OR value_kind IN ('number','text','boolean')),
            value_number REAL,
            value_text TEXT,
            value_boolean INTEGER CHECK (value_boolean IS NULL OR value_boolean IN (0, 1)),
            value_unit TEXT CHECK (value_unit IS NULL OR length(value_unit) BETWEEN 1 AND 24),
            source_version_id TEXT REFERENCES source_version(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            locator_json TEXT CHECK (
                locator_json IS NULL
                OR (json_valid(locator_json) AND json_type(locator_json) = 'object')
            ),
            note TEXT NOT NULL DEFAULT '' CHECK (length(note) <= 20000),
            created_at TEXT NOT NULL,
            supersedes_observation_id TEXT REFERENCES observation(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            UNIQUE (id, room_id, property_key),
            CHECK (source_version_id IS NOT NULL OR locator_json IS NULL),
            CHECK (supersedes_observation_id IS NULL OR supersedes_observation_id <> id),
            CHECK (
                (value_kind IS NULL AND value_number IS NULL AND value_text IS NULL
                    AND value_boolean IS NULL AND value_unit IS NULL)
                OR (value_kind = 'number' AND value_number IS NOT NULL AND value_text IS NULL
                    AND value_boolean IS NULL AND (value_unit IS NULL OR length(value_unit) BETWEEN 1 AND 24))
                OR (value_kind = 'text' AND value_text IS NOT NULL AND value_number IS NULL
                    AND value_boolean IS NULL AND value_unit IS NULL)
                OR (value_kind = 'boolean' AND value_boolean IS NOT NULL AND value_number IS NULL
                    AND value_text IS NULL AND value_unit IS NULL)
            )
        )
        """,
        """
        CREATE INDEX observation_room ON observation(room_id, property_key, created_at DESC)
        """,
        """
        CREATE INDEX observation_source_version ON observation(source_version_id)
        """,
        """
        CREATE TRIGGER observation_immutable_update
        BEFORE UPDATE ON observation
        BEGIN
            SELECT RAISE(ABORT, 'observations are immutable; record a new observation instead');
        END
        """,
        """
        CREATE TRIGGER observation_immutable_delete
        BEFORE DELETE ON observation
        BEGIN
            SELECT RAISE(ABORT, 'observations are immutable');
        END
        """,
        """
        CREATE TABLE adopted_value (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project_state(project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            room_id TEXT NOT NULL REFERENCES room(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            property_key TEXT NOT NULL CHECK (length(property_key) BETWEEN 1 AND 64),
            value_kind TEXT NOT NULL CHECK (value_kind IN ('number','text','boolean')),
            value_number REAL,
            value_text TEXT,
            value_boolean INTEGER CHECK (value_boolean IS NULL OR value_boolean IN (0, 1)),
            value_unit TEXT CHECK (value_unit IS NULL OR length(value_unit) BETWEEN 1 AND 24),
            observation_id TEXT NOT NULL,
            adopted_at TEXT NOT NULL,
            adopted_revision INTEGER NOT NULL CHECK (adopted_revision >= 1),
            superseded_by TEXT REFERENCES adopted_value(id) DEFERRABLE INITIALLY DEFERRED,
            UNIQUE (id, room_id, property_key),
            FOREIGN KEY (observation_id, room_id, property_key)
                REFERENCES observation(id, room_id, property_key) ON UPDATE RESTRICT ON DELETE RESTRICT,
            FOREIGN KEY (superseded_by, room_id, property_key)
                REFERENCES adopted_value(id, room_id, property_key)
                ON UPDATE RESTRICT ON DELETE RESTRICT
                DEFERRABLE INITIALLY DEFERRED,
            CHECK (superseded_by IS NULL OR superseded_by <> id),
            CHECK (
                (value_kind = 'number' AND value_number IS NOT NULL AND value_text IS NULL
                    AND value_boolean IS NULL AND (value_unit IS NULL OR length(value_unit) BETWEEN 1 AND 24))
                OR (value_kind = 'text' AND value_text IS NOT NULL AND value_number IS NULL
                    AND value_boolean IS NULL AND value_unit IS NULL)
                OR (value_kind = 'boolean' AND value_boolean IS NOT NULL AND value_number IS NULL
                    AND value_text IS NULL AND value_unit IS NULL)
            )
        )
        """,
        """
        CREATE UNIQUE INDEX adopted_value_current
        ON adopted_value(project_id, room_id, property_key)
        WHERE superseded_by IS NULL
        """,
        """
        CREATE INDEX adopted_value_history
        ON adopted_value(room_id, property_key, adopted_at DESC)
        """,
        """
        CREATE TRIGGER adopted_value_supersede_only
        BEFORE UPDATE ON adopted_value
        WHEN OLD.superseded_by IS NOT NULL
            OR NEW.id <> OLD.id
            OR NEW.project_id <> OLD.project_id
            OR NEW.room_id <> OLD.room_id
            OR NEW.property_key <> OLD.property_key
            OR NEW.value_kind <> OLD.value_kind
            OR NEW.value_number IS NOT OLD.value_number
            OR NEW.value_text IS NOT OLD.value_text
            OR NEW.value_boolean IS NOT OLD.value_boolean
            OR NEW.value_unit IS NOT OLD.value_unit
            OR NEW.observation_id <> OLD.observation_id
            OR NEW.adopted_at <> OLD.adopted_at
            OR NEW.adopted_revision <> OLD.adopted_revision
            OR NEW.superseded_by IS NULL
        BEGIN
            SELECT RAISE(ABORT, 'adopted values can only be superseded once');
        END
        """,
        """
        CREATE TRIGGER adopted_value_immutable_delete
        BEFORE DELETE ON adopted_value
        BEGIN
            SELECT RAISE(ABORT, 'adopted values are retained as history');
        END
        """,
        """
        CREATE TRIGGER content_blob_immutable_update
        BEFORE UPDATE ON content_blob
        BEGIN
            SELECT RAISE(ABORT, 'content-addressed blobs are immutable');
        END
        """,
        """
        CREATE TRIGGER content_blob_immutable_delete
        BEFORE DELETE ON content_blob
        BEGIN
            SELECT RAISE(ABORT, 'content-addressed blobs are retained');
        END
        """,
        """
        CREATE TRIGGER project_state_revision_guard
        BEFORE UPDATE ON project_state
        WHEN NEW.singleton <> OLD.singleton
            OR NEW.project_id <> OLD.project_id
            OR NEW.created_at <> OLD.created_at
            OR NEW.records_revision <> OLD.records_revision + 1
        BEGIN
            SELECT RAISE(ABORT, 'project identity is immutable and the records revision must increment by one');
        END
        """
    ]

    static let v2BOM: [String] = [
        """
        CREATE TABLE bom_target (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project_state(project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 200),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE INDEX bom_target_project ON bom_target(project_id, name)
        """,
        """
        CREATE TABLE bom_draft (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project_state(project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            source_version_id TEXT NOT NULL REFERENCES source_version(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            target_id TEXT REFERENCES bom_target(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            adapter_identifier TEXT NOT NULL CHECK (length(trim(adapter_identifier)) BETWEEN 1 AND 80),
            fingerprint TEXT NOT NULL
                CHECK (length(fingerprint) = 64 AND fingerprint NOT GLOB '*[^0-9a-f]*'),
            mapping_json TEXT NOT NULL CHECK (json_valid(mapping_json) AND json_type(mapping_json) = 'object'),
            delimiter TEXT CHECK (
                delimiter IS NULL
                OR delimiter IN ('comma','tab','semicolon','pipe')
            ),
            created_at TEXT NOT NULL,
            UNIQUE (project_id, source_version_id, fingerprint)
        )
        """,
        """
        CREATE INDEX bom_draft_target ON bom_draft(project_id, target_id, created_at DESC)
        """,
        """
        CREATE TABLE bom_draft_row (
            id TEXT PRIMARY KEY NOT NULL,
            draft_id TEXT NOT NULL REFERENCES bom_draft(id) ON DELETE CASCADE,
            row_index INTEGER NOT NULL CHECK (row_index >= 0),
            line_number INTEGER NOT NULL CHECK (line_number >= 1),
            source_row_key TEXT NOT NULL CHECK (length(source_row_key) BETWEEN 1 AND 200),
            raw_fields_json TEXT NOT NULL CHECK (
                json_valid(raw_fields_json) AND json_type(raw_fields_json) = 'array'
            ),
            raw_record TEXT NOT NULL,
            locator_json TEXT NOT NULL CHECK (json_valid(locator_json) AND json_type(locator_json) = 'object'),
            brand TEXT,
            model TEXT,
            order_code TEXT,
            product_name TEXT,
            series TEXT,
            room_name TEXT,
            storey TEXT,
            system_name TEXT,
            raw_quantity TEXT NOT NULL,
            raw_unit TEXT,
            quantity REAL,
            quantity_kind TEXT CHECK (
                quantity_kind IS NULL
                OR quantity_kind IN ('devices','channels','sets','packages','metres','other')
            ),
            channels_per_device INTEGER CHECK (channels_per_device IS NULL OR channels_per_device > 0),
            spare_quantity REAL CHECK (spare_quantity IS NULL OR spare_quantity >= 0),
            role TEXT CHECK (
                role IS NULL
                OR role IN (
                    'design_requirement','quotation','ordered','received','installed',
                    'spare','kit_component','source_note'
                )
            ),
            role_raw TEXT,
            matched_room_id TEXT REFERENCES room(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            notes TEXT NOT NULL DEFAULT '',
            comparison_key TEXT NOT NULL,
            allocation_identity TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('ready','needs_review','blocked')),
            countable INTEGER NOT NULL CHECK (countable IN (0, 1)),
            UNIQUE (draft_id, row_index),
            UNIQUE (draft_id, source_row_key),
            UNIQUE (draft_id, allocation_identity)
        )
        """,
        """
        CREATE INDEX bom_draft_row_room ON bom_draft_row(matched_room_id)
        """,
        """
        CREATE TABLE bom_issue (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project_state(project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            draft_id TEXT NOT NULL REFERENCES bom_draft(id) ON DELETE CASCADE,
            row_id TEXT REFERENCES bom_draft_row(id) ON DELETE CASCADE,
            row_index INTEGER CHECK (row_index IS NULL OR row_index >= 0),
            kind TEXT NOT NULL,
            severity TEXT NOT NULL CHECK (severity IN ('blocking','warning','info')),
            field TEXT,
            message TEXT NOT NULL,
            raw_value TEXT,
            state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','resolved')),
            created_at TEXT NOT NULL
        )
        """,
        """
        CREATE INDEX bom_issue_draft ON bom_issue(draft_id, row_index, created_at)
        """,
        """
        CREATE TABLE bom_item (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project_state(project_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            target_id TEXT NOT NULL REFERENCES bom_target(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            role TEXT NOT NULL CHECK (role IN (
                'design_requirement','quotation','ordered','received','installed',
                'spare','kit_component','source_note'
            )),
            room_id TEXT REFERENCES room(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            storey TEXT,
            system_name TEXT,
            brand TEXT,
            raw_model TEXT,
            series TEXT,
            order_code TEXT,
            product_name TEXT,
            quantity REAL NOT NULL CHECK (quantity > 0),
            quantity_kind TEXT CHECK (
                quantity_kind IS NULL
                OR quantity_kind IN ('devices','channels','sets','packages','metres','other')
            ),
            raw_quantity TEXT NOT NULL,
            raw_unit TEXT,
            channels_per_device INTEGER CHECK (channels_per_device IS NULL OR channels_per_device > 0),
            spare_quantity REAL CHECK (spare_quantity IS NULL OR spare_quantity >= 0),
            origin_kind TEXT NOT NULL CHECK (origin_kind IN ('source','manual')),
            source_version_id TEXT REFERENCES source_version(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            draft_id TEXT REFERENCES bom_draft(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
            source_row_key TEXT,
            allocation_key TEXT NOT NULL UNIQUE,
            match_state TEXT NOT NULL CHECK (
                match_state IN ('source_backed_custom','identity_unresolved','manual_custom')
            ),
            capability_state TEXT NOT NULL CHECK (
                capability_state IN ('unknown','source_declared','verified')
            ),
            is_counted INTEGER NOT NULL CHECK (is_counted IN (0, 1)),
            notes TEXT NOT NULL DEFAULT '',
            applied_revision INTEGER NOT NULL CHECK (applied_revision >= 1),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            CHECK (
                (origin_kind = 'source' AND source_version_id IS NOT NULL
                    AND draft_id IS NOT NULL AND source_row_key IS NOT NULL)
                OR (origin_kind = 'manual' AND source_version_id IS NULL
                    AND draft_id IS NULL AND source_row_key IS NULL)
            ),
            CHECK (is_counted = 0 OR (quantity_kind IS NOT NULL AND match_state <> 'identity_unresolved'))
        )
        """,
        """
        CREATE INDEX bom_item_target ON bom_item(target_id, role, room_id)
        """,
        """
        CREATE INDEX bom_item_source ON bom_item(source_version_id, draft_id)
        """
    ]
    static let v3ObservationOrigin: [String] = [
        """
        ALTER TABLE observation ADD COLUMN origin TEXT NOT NULL DEFAULT 'unknown'
            CHECK (origin IN ('unknown','user','manual_measurement','ar','lidar',
                'ai_extracted','ai_inferred','calculated','imported'))
        """
    ]

}
