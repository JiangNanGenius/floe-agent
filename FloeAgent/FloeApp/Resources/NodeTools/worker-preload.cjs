'use strict';
// Feed job input without keeping a Worker stdio message port alive when a
// program never reads stdin. Also support the usual fs.readFileSync(0) CLI idiom.
const { workerData, isMainThread } = require('node:worker_threads');
if (!isMainThread && workerData?.floeJob) {
  const fs = require('node:fs');
  const { Readable } = require('node:stream');
  const bytes = Buffer.from(workerData.stdin ?? '', 'base64');
  let position = 0;
  const input = new Readable({ read(size) {
    if (position >= bytes.length) { this.push(null); return; }
    const end = Math.min(bytes.length, position + size);
    this.push(bytes.subarray(position, end)); position = end;
  } });
  input.fd = 0; input.isTTY = false;
  Object.defineProperty(process, 'stdin', { configurable: true, value: input });
  const readFileSync = fs.readFileSync;
  fs.readFileSync = function(file, options) {
    if (file !== 0) return readFileSync.apply(this, arguments);
    const data = bytes.subarray(position); position = bytes.length;
    const encoding = typeof options === 'string' ? options : options?.encoding;
    return encoding ? data.toString(encoding) : Buffer.from(data);
  };
  const readSync = fs.readSync;
  fs.readSync = function(fd, buffer, offset, length) {
    if (fd !== 0) return readSync.apply(this, arguments);
    if (typeof offset === 'object') { length = offset.length; offset = offset.offset; }
    offset ??= 0; length ??= buffer.byteLength - offset;
    const count = Math.min(length, bytes.length - position);
    bytes.copy(buffer, offset, position, position + count); position += count;
    return count;
  };
}
