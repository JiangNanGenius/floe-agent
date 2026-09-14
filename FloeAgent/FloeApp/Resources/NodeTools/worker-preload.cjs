'use strict';
// Feed job input without keeping a Worker stdio message port alive when a
// program never reads stdin. Also support the usual fs.readFileSync(0) CLI idiom.
const { workerData, isMainThread } = require('node:worker_threads');
if (!isMainThread && workerData?.floeJob) {
  const fs = require('node:fs');
  const path = require('node:path');
  if (workerData.service) {
    const net = require('node:net');
    const listen = net.Server.prototype.listen;
    net.Server.prototype.listen = function(...args) {
      // Services intended for the in-app preview must not publish a wildcard
      // listener. An omitted host is made explicitly loopback.
      if (typeof args[0] === 'object' && args[0] !== null) {
        const options = { ...args[0] };
        if (options.path || options.fd !== undefined || options.handle) throw Error('Preview services require a loopback TCP port');
        options.host ??= '127.0.0.1';
        if (!['127.0.0.1', '::1', 'localhost'].includes(options.host)) throw Error('Preview services must bind to loopback');
        args[0] = options;
      } else {
        if (typeof args[0] !== 'number') throw Error('Preview services require a TCP port');
        if (typeof args[1] !== 'string') args.splice(1, 0, '127.0.0.1');
        if (!['127.0.0.1', '::1', 'localhost'].includes(args[1])) throw Error('Preview services must bind to loopback');
      }
      return Reflect.apply(listen, this, args);
    };
  }
  const cwd = workerData.cwd;
  // Resolve ordinary JS filesystem paths per worker. Never chdir the App
  // process: Python and shell may be executing in that process concurrently.
  // This is dependency/cwd routing, not a native-code security sandbox.
  Object.defineProperty(process, 'cwd', { configurable: true, value: () => cwd });
  function absolute(value) {
    if (typeof value === 'string') return path.resolve(cwd, value);
    if (Buffer.isBuffer(value) && value[0] !== 47) return Buffer.concat([Buffer.from(cwd + '/'), value]);
    return value; // File descriptors and file URLs retain their native meaning.
  }
  function wrap(object, name, positions) {
    const original = object[name];
    if (typeof original !== 'function') return;
    const wrapped = function(...args) {
      for (const index of positions) args[index] = absolute(args[index]);
      return Reflect.apply(original, this, args);
    };
    if (typeof original.native === 'function') {
      wrapped.native = function(...args) {
        for (const index of positions) args[index] = absolute(args[index]);
        return Reflect.apply(original.native, this, args);
      };
    }
    object[name] = wrapped;
  }
  const single = ['access', 'appendFile', 'chmod', 'chown', 'exists', 'lchmod', 'lchown',
    'lstat', 'lutimes', 'mkdir', 'mkdtemp', 'open', 'opendir', 'readFile', 'readdir',
    'readlink', 'realpath', 'rm', 'rmdir', 'stat', 'statfs', 'truncate', 'unlink',
    'utimes', 'writeFile'];
  for (const name of single) {
    wrap(fs, name, [0]); wrap(fs, name + 'Sync', [0]); wrap(fs.promises, name, [0]);
  }
  for (const name of ['cp', 'copyFile', 'link', 'rename']) {
    wrap(fs, name, [0, 1]); wrap(fs, name + 'Sync', [0, 1]); wrap(fs.promises, name, [0, 1]);
  }
  // Relative symlink targets are relative to the link, not the task cwd.
  wrap(fs, 'symlink', [1]); wrap(fs, 'symlinkSync', [1]); wrap(fs.promises, 'symlink', [1]);
  for (const name of ['createReadStream', 'createWriteStream', 'watch', 'watchFile', 'unwatchFile']) wrap(fs, name, [0]);
  const { Readable } = require('node:stream');
  const bytes = Buffer.from(workerData.stdin ?? '', 'base64');
  let position = 0;
  const streamFD = Number.isInteger(workerData.stdinFD) ? workerData.stdinFD : null;
  // Native input is a private O_NONBLOCK pipe. Never dispatch a blocking fs
  // read to libuv: Worker.terminate would then wait for stdin EOF indefinitely.
  const input = streamFD !== null ? new Readable({ read(size) {
    const stream = this;
    const poll = () => {
      if (stream.destroyed) return;
      const buffer = Buffer.allocUnsafe(Math.min(size, 65536));
      try {
        const count = readSync(streamFD, buffer, 0, buffer.length, null);
        stream.push(count ? buffer.subarray(0, count) : null);
      } catch (error) {
        if (error.code === 'EAGAIN' || error.code === 'EWOULDBLOCK') setTimeout(poll, 20);
        else stream.destroy(error);
      }
    };
    poll();
  } }) : new Readable({ read(size) {
    if (position >= bytes.length) { this.push(null); return; }
    const end = Math.min(bytes.length, position + size);
    this.push(bytes.subarray(position, end)); position = end;
  } });
  input.fd = 0;
  input.isTTY = false;
  Object.defineProperty(process, 'stdin', { configurable: true, value: input });
  const readFileSync = fs.readFileSync;
  fs.readFileSync = function(file, options) {
    if (file !== 0) return readFileSync.apply(this, arguments);
    if (streamFD !== null) {
      const chunks = [], buffer = Buffer.allocUnsafe(65536);
      let count;
      while ((count = fs.readSync(0, buffer, 0, buffer.length)) > 0) chunks.push(Buffer.from(buffer.subarray(0, count)));
      const data = Buffer.concat(chunks);
      const encoding = typeof options === 'string' ? options : options?.encoding;
      return encoding ? data.toString(encoding) : data;
    }
    const data = bytes.subarray(position); position = bytes.length;
    const encoding = typeof options === 'string' ? options : options?.encoding;
    return encoding ? data.toString(encoding) : Buffer.from(data);
  };
  const readSync = fs.readSync;
  fs.readSync = function(fd, buffer, offset, length) {
    if (fd !== 0) return readSync.apply(this, arguments);
    if (streamFD !== null) {
      const sleeper = new Int32Array(new SharedArrayBuffer(4));
      while (true) {
        try { return readSync.call(this, streamFD, buffer, offset, length); }
        catch (error) {
          if (error.code !== 'EAGAIN' && error.code !== 'EWOULDBLOCK') throw error;
          Atomics.wait(sleeper, 0, 0, 20); // Interruptible by Worker.terminate.
        }
      }
    }
    if (typeof offset === 'object') { length = offset.length; offset = offset.offset; }
    offset ??= 0; length ??= buffer.byteLength - offset;
    const count = Math.min(length, bytes.length - position);
    bytes.copy(buffer, offset, position, position + count); position += count;
    return count;
  };
  require('node:module').syncBuiltinESMExports();
}
