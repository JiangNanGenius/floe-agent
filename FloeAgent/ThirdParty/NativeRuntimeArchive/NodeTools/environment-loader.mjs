// Standard ESM package/exports resolution, extended with the same ordered
// dependency roots used by the job's CommonJS resolver. No source rewriting.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
let roots = [];
export function initialize(data) {
  roots = [...new Set(data.roots.filter(root => typeof root === 'string' && path.isAbsolute(root)))];
}
export async function resolve(specifier, context, nextResolve) {
  try { return await nextResolve(specifier, context); }
  catch (original) {
    // An invalid export or broken relative import must remain an error.
    if (original.code !== 'ERR_MODULE_NOT_FOUND' || !/^(?:@[a-z0-9._-]+\/)?[a-z0-9][a-z0-9._-]*(?:\/.*)?$/i.test(specifier)) throw original;
    const parts = specifier.split('/');
    const packageName = specifier.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
    for (const root of roots) {
      if (!fs.existsSync(path.join(root, packageName))) continue;
      // Let Node enforce package exports, import conditions, extension/type
      // and subpaths. A broken higher-priority package cannot fall through.
      const parentURL = pathToFileURL(path.join(path.dirname(root), '_floe_resolve.mjs')).href;
      return nextResolve(specifier, { ...context, parentURL });
    }
    throw original;
  }
}
