// SPDX-License-Identifier: MPL-2.0
// BrowserFS adapter: no shadow copy is ever acknowledged as a native save.
(function (scope) {
  'use strict';
  function createNativeFilesystem(BrowserFS, Buffer, rpc, onCommit = () => {}) {
    const policy = scope.FloeIDEPolicy || {
      // Minimal safety net if the policy script is ever missing: never treat
      // NUL bytes or invalid UTF-8 as text. Path typing needs the policy file.
      refusal: (path, bytes) => {
        if (bytes) {
          for (let index = 0; index < bytes.length; index += 1) {
            if (bytes[index] === 0) return { code: 'ENOTSUP', message: `${path} is binary and cannot be opened as text` };
          }
          try { new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
          catch (_) { return { code: 'ENOTSUP', message: `${path} is binary and cannot be opened as text` }; }
        }
        return null;
      }
    };
    const sample = new BrowserFS.FileSystem.InMemory();
    const Stats = sample.statSync('/', false).constructor;
    const Base = Object.getPrototypeOf(BrowserFS.FileSystem.Editor.prototype).constructor;
    let ApiError;
    try { sample.statSync('/missing', false); } catch (e) { ApiError = e.constructor; }
    const errno = { EIO: 5, ENOENT: 2, EACCES: 13, EEXIST: 17, EINVAL: 22, ENOTSUP: 95, EFBIG: 27, EISDIR: 21, EBUSY: 16 };
    const error = (e, path) => new ApiError(errno[e.code] || 5, e.message || String(e), path);
    const call = (request, callback, transform = () => undefined) => {
      Promise.resolve().then(() => rpc(request)).then(result => {
        if (result.error) throw result.error;
        return transform(result);
      }).then(value => callback(null, value), e => callback(error(e, request.path)));
    };
    class NativeFilesystem extends Base {
      static Name = 'FloeNative';
      static Options = {};
      static isAvailable() { return true; }
      static Create(_options, callback) { callback(null, new NativeFilesystem()); }
      getName() { return NativeFilesystem.Name; }
      isReadOnly() { return false; }
      supportsSynch() { return false; }
      supportsLinks() { return false; }
      supportsProps() { return false; }
      stat(path, _lstat, cb) {
        call({ operation: 'stat', path }, cb, value => {
          const date = Number(value.modified || 0);
          return new Stats(value.directory ? 0x4000 : 0x8000, value.size || 0, undefined, date, date, date);
        });
      }
      readdir(path, cb) { call({ operation: 'list', path }, cb, value => value.entries.map(e => e.name)); }
      readFile(path, encoding, _flag, cb) {
        call({ operation: 'read', path }, cb, value => {
          const bytes = Buffer.from(value.contentBase64, 'base64');
          const refused = policy.refusal(path, bytes);
          if (refused) throw refused;
          return encoding ? bytes.toString(encoding) : bytes;
        });
      }
      writeFile(path, data, encoding, flag, _mode, cb) {
        // Appending or read/update file handles would require separate native semantics.
        if (flag && flag.getFlagString() !== 'w') { cb(error({code:'ENOTSUP',message:'Only complete text saves are supported'}, path)); return; }
        const bytes = Buffer.isBuffer(data) ? data : Buffer.from(data, encoding || 'utf8');
        if (bytes.length > 4 * 1024 * 1024) { cb(error({code:'EFBIG',message:'Text file exceeds 4 MiB'}, path)); return; }
        // Refuse before the RPC: a non-text target must never be overwritten
        // even when the incoming bytes happen to decode as UTF-8 (xlsx case).
        const refused = policy.refusal(path, bytes);
        if (refused) { cb(error(refused, path)); return; }
        call({ operation: 'write', path, contentBase64: bytes.toString('base64') }, cb, () => onCommit(path, bytes.toString('utf8')));
      }
      mkdir(path, _mode, cb) { call({ operation: 'mkdir', path }, cb); }
      rename(path, destination, cb) { call({ operation: 'rename', path, destination }, cb); }
      unlink(path, cb) { call({ operation: 'delete', path }, cb); }
      rmdir(path, cb) { call({ operation: 'delete', path }, cb); }
      exists(path, cb) { this.stat(path, false, err => cb(!err)); }
      realpath(path, _cache, cb) { this.stat(path, false, err => cb(err, err ? undefined : path)); }
    }
    return NativeFilesystem;
  }
  scope.FloeNativeFilesystem = createNativeFilesystem;
  if (typeof module !== 'undefined') module.exports = createNativeFilesystem;
})(typeof window === 'undefined' ? globalThis : window);
