// SPDX-License-Identifier: MPL-2.0
// Floe's narrow compatibility bridge. SQLite and its generated runtime retain
// their own upstream terms; this file does not relicense either component.
//
// Browser: use the separately bundled official module loaded before the editor.
// Node qualification: use the same package's Node entry and the identical WASM.
// These fixed URLs are chosen by this bundled loader/test harness, not by tools,
// imported project content, SQL text, or a model-supplied filesystem path.
let initialization;

export function sql() {
  if (!initialization) {
    initialization = initialize().catch(error => {
      initialization = undefined;
      throw error;
    });
  }
  return initialization;
}

async function initialize() {
  let official = globalThis.FloeSQLiteOfficial;
  if (!official) {
    if (__FLOE_GIS_SQLITE_TESTING__) {
      const testModule = globalThis.FloeEditorTestSQLiteModule;
      if (!testModule) throw new Error('The SQLite fixture entry is unavailable');
      official = await import(testModule);
    } else {
      throw new Error('The bundled SQLite module is unavailable');
    }
  }
  const initializeOfficialSQLite = official.default;
  const bundledBinary = globalThis.FloeBundledBinaryAssets?.['sqlite3.wasm'];
  const wasmBinary = typeof bundledBinary === 'string'
    ? Uint8Array.from(atob(bundledBinary), character => character.charCodeAt(0))
    : undefined;
  const sqlite3 = await initializeOfficialSQLite({
    wasmBinary,
    locateFile: name => {
      if (name !== 'sqlite3.wasm') throw new Error('Unexpected SQLite resource');
      const fixture = __FLOE_GIS_SQLITE_TESTING__ ? globalThis.FloeEditorTestSQLWasm : undefined;
      return fixture || new URL('sqlite3.wasm', location.href).href;
    }
  });
  const { capi, wasm, oo1 } = sqlite3;

  const copiedValue = value => value instanceof Uint8Array
    ? value.slice()
    : typeof value === 'bigint' ? Number(value) : value;

  class Statement {
    constructor(database, native) {
      this.database = database;
      this.statement = native;
      database.statements.add(this);
    }
    native() {
      this.database.native();
      if (!this.statement) throw new Error('SQLite statement has been freed');
      return this.statement;
    }
    bind(values) {
      const statement = this.native();
      statement.reset(true);
      if (values !== undefined) statement.bind(values);
      return true;
    }
    step() { return Boolean(this.native().step()); }
    get(values) {
      if (values !== undefined) {
        this.bind(values);
        if (!this.step()) return [];
      }
      return this.native().get([]).map(copiedValue);
    }
    getAsObject(values) {
      const row = this.get(values);
      return Object.fromEntries(this.getColumnNames().map((name, index) => [name, row[index]]));
    }
    getColumnNames() { return this.native().getColumnNames([]); }
    run(values) {
      if (values !== undefined) this.bind(values);
      try {
        this.step();
        return this;
      } finally {
        // SQL.js reset clears bindings. resetNoThrow preserves the original step
        // failure, while safely releasing all parameters for the next use.
        this.native().resetNoThrow(true);
      }
    }
    reset() { return this.native().resetNoThrow(true) === capi.SQLITE_OK; }
    free() {
      if (!this.statement) return false;
      const statement = this.statement;
      this.statement = undefined;
      this.database.statements.delete(this);
      return statement.finalize() === capi.SQLITE_OK;
    }
  }

  class Database {
    constructor(input) {
      this.statements = new Set();
      this.database = new oo1.DB(':memory:', 'c');
      if (input !== undefined && input !== null) {
        const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
        if (bytes.byteLength) {
          let pointer;
          try {
            pointer = wasm.allocFromTypedArray(bytes);
            this.database.checkRc(capi.sqlite3_deserialize(
              this.database.pointer, 'main', pointer, bytes.byteLength, bytes.byteLength,
              capi.SQLITE_DESERIALIZE_FREEONCLOSE | capi.SQLITE_DESERIALIZE_RESIZEABLE
            ));
            // Ownership transfers only after a successful deserialize. SQLite
            // reallocates this buffer as an imported GeoPackage grows.
            pointer = undefined;
            this.database.exec('PRAGMA schema_version');
          } catch (error) {
            if (pointer) wasm.dealloc(pointer);
            this.close();
            throw error;
          }
        }
      }
    }
    native() {
      if (!this.database?.pointer) throw new Error('SQLite database is closed');
      return this.database;
    }
    prepare(source, values) {
      const statement = new Statement(this, this.native().prepare(String(source)));
      try {
        if (values !== undefined) statement.bind(values);
        return statement;
      } catch (error) {
        statement.free();
        throw error;
      }
    }
    *iterateStatements(source) {
      const db = this.native();
      const sqlBytes = new TextEncoder().encode(String(source) + '\0');
      const sourcePointer = wasm.allocFromTypedArray(sqlBytes);
      const pointers = wasm.alloc(wasm.ptr.size * 2);
      const tailPointer = wasm.ptr.add(pointers, wasm.ptr.size);
      const end = wasm.ptr.add(sourcePointer, sqlBytes.byteLength - 1);
      let cursor = sourcePointer;
      try {
        while (cursor && wasm.peek8(cursor)) {
          wasm.pokePtr([pointers, tailPointer], 0);
          db.checkRc(capi.sqlite3_prepare_v3(
            db.pointer, cursor, Number(wasm.ptr.add(end, -cursor)), 0, pointers, tailPointer
          ));
          const handle = wasm.peekPtr(pointers);
          const next = wasm.peekPtr(tailPointer);
          if (!next || next <= cursor) {
            if (handle) capi.sqlite3_finalize(handle);
            throw new Error('SQLite parser made no progress');
          }
          cursor = next;
          if (!handle) continue; // Empty statements and comments are not SQL.
          const statement = new Statement(this, oo1.Stmt.wrapHandle(db, handle, true));
          try {
            yield statement;
          } finally {
            statement.free();
          }
        }
      } finally {
        wasm.dealloc(pointers);
        wasm.dealloc(sourcePointer);
      }
    }
    run(source, values) {
      this.native().exec(values === undefined ? String(source) : { sql: String(source), bind: values });
      return this;
    }
    exec(source, values) {
      const results = [];
      let bound = false;
      for (const statement of this.iterateStatements(source)) {
        if (!bound && values !== undefined && statement.native().parameterCount) {
          statement.bind(values);
          bound = true;
        }
        const columns = statement.getColumnNames();
        const rows = [];
        while (statement.step()) rows.push(statement.get());
        if (rows.length) results.push({ columns, values: rows });
      }
      return results;
    }
    export() { return capi.sqlite3_js_db_export(this.native()).slice(); }
    close() {
      if (!this.database) return;
      for (const statement of [...this.statements]) statement.free();
      const db = this.database;
      this.database = undefined;
      db.close();
    }
  }
  return Object.freeze({
    Database,
    engineInfo: Object.freeze({
      package: '@sqlite.org/sqlite-wasm', packageVersion: '3.54.1-build1',
      sqliteVersion: sqlite3.version.libVersion, sourceID: sqlite3.version.sourceId
    })
  });
}
