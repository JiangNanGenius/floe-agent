import GRDB

/// Generic per-skill configuration: trusted installation identity, profile
/// and target scoped revisions, ordinary variable values, Keychain-backed
/// secret/connection bindings and per-revision live validation receipts.
///
/// No column stores secret bytes. A binding references the existing
/// `credential_records` row, which in turn references a Keychain item; both
/// credential owners and the vault remain the single secret authority.
public enum V59SkillConfiguration {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v59_skill_configuration") { db in
            try db.execute(sql: """
                CREATE TABLE skill_config_installations (
                    installation_id TEXT PRIMARY KEY NOT NULL,
                    skill_id TEXT NOT NULL,
                    source_binding TEXT NOT NULL,
                    publisher TEXT,
                    source_trust TEXT NOT NULL,
                    reviewed_digest TEXT NOT NULL,
                    source_digest TEXT,
                    source_pin TEXT,
                    rewrite_model_id TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(skill_id, source_binding)
                ) STRICT;

                CREATE TABLE skill_config_profiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    installation_id TEXT NOT NULL
                        REFERENCES skill_config_installations(installation_id) ON DELETE CASCADE,
                    skill_id TEXT NOT NULL,
                    profile TEXT NOT NULL,
                    target TEXT NOT NULL,
                    revision INTEGER NOT NULL CHECK(revision >= 1),
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(installation_id, profile, target)
                ) STRICT;
                CREATE INDEX skill_config_profiles_skill
                    ON skill_config_profiles(skill_id, profile, target);

                CREATE TABLE skill_config_entries (
                    profile_id TEXT NOT NULL
                        REFERENCES skill_config_profiles(id) ON DELETE CASCADE,
                    field_key TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('variable', 'secret', 'connection')),
                    value_text TEXT,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(profile_id, field_key)
                ) STRICT;

                CREATE TABLE skill_config_bindings (
                    profile_id TEXT NOT NULL
                        REFERENCES skill_config_profiles(id) ON DELETE CASCADE,
                    field_key TEXT NOT NULL,
                    credential_id TEXT NOT NULL
                        REFERENCES credential_records(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK(role IN ('owned', 'shared')),
                    connection_kind TEXT,
                    device_bound INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(profile_id, field_key)
                ) STRICT;
                CREATE INDEX skill_config_bindings_credential
                    ON skill_config_bindings(credential_id);

                CREATE TABLE skill_config_local_declarations (
                    profile_id TEXT NOT NULL
                        REFERENCES skill_config_profiles(id) ON DELETE CASCADE,
                    field_key TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('variable', 'secret')),
                    value_type TEXT NOT NULL CHECK(value_type IN (
                        'string', 'number', 'boolean', 'url', 'enumeration'
                    )),
                    title TEXT,
                    detail TEXT,
                    required INTEGER NOT NULL,
                    environment_name TEXT NOT NULL,
                    allowed_values_json TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(profile_id, field_key)
                ) STRICT;
                CREATE UNIQUE INDEX skill_config_local_declarations_environment
                    ON skill_config_local_declarations(profile_id, environment_name);

                CREATE TABLE skill_config_validations (
                    profile_id TEXT NOT NULL
                        REFERENCES skill_config_profiles(id) ON DELETE CASCADE,
                    field_key TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('validated', 'invalid', 'unsupported')),
                    validator TEXT NOT NULL,
                    detail TEXT,
                    validated_at TEXT NOT NULL,
                    PRIMARY KEY(profile_id, field_key, revision)
                ) STRICT;

                PRAGMA user_version = 59;
                """)
        }
    }
}
