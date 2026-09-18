// SPDX-License-Identifier: MPL-2.0
// Typed routing policy for the IDE bridge. This mirrors the Swift
// `WorkspaceTextPolicy` (FloeAgent/Sources/FloeWorkspace/WorkspaceTextPolicy.swift)
// so the web workbench refuses the same paths the native bridge refuses.
// Office/PDF/CAD/image/media/archive bytes never reach Monaco, and a file whose
// bytes sniff as binary is refused for both read and write.
(function (scope) {
  'use strict';
  const TEXT = new Set(('txt md markdown json jsonc swift py js mjs cjs jsx ts tsx c h m mm cc cpp cxx hpp html htm css ' +
    'scss xml yaml yml toml sh bash zsh fish log csv rs go java kt kts sql rb php pl lua dart vue svelte gradle ' +
    'properties ini conf env gitignore dockerfile makefile patch diff').split(' '));
  const CODE = new Set(('json jsonc swift py js mjs cjs jsx ts tsx c h m mm cc cpp cxx hpp html htm css scss xml yaml yml ' +
    'toml sh bash zsh fish rs go java kt kts sql rb php pl lua dart vue svelte gradle properties ini conf').split(' '));
  const OFFICE = new Set(('docx docm xlsx xlsm pptx pptm doc xls ppt odt ods odp rtf').split(' '));
  const CAD = new Set(('dxf dwg step stp iges igs stl obj').split(' '));
  const IMAGE = new Set(('png jpg jpeg gif heic heif webp tiff tif bmp svg').split(' '));
  const MEDIA = new Set(('mov mp4 m4v avi mkv webm mp3 m4a wav aac flac').split(' '));
  const ARCHIVE = new Set(('zip tar gz tgz bz2 xz 7z rar jar war ipa deb dmg iso').split(' '));
  const BINARY = new Set(('bin dat exe dll dylib so a o class pyc wasm sqlite db p12 pfx cer der mobileprovision keystore ttf otf woff woff2').split(' '));
  const NAMED_TEXT = new Set(('makefile dockerfile license readme notice changelog gitignore gitattributes editorconfig').split(' '));

  const split = (path) => {
    const value = String(path || '').replace(/\\/g, '/');
    const index = value.lastIndexOf('/');
    const name = (index >= 0 ? value.slice(index + 1) : value).toLowerCase();
    const dot = name.lastIndexOf('.');
    return { name, ext: dot > 0 ? name.slice(dot + 1) : '' };
  };

  const kindForPath = (path) => {
    const { name, ext } = split(path);
    if (!ext) return NAMED_TEXT.has(name) ? 'text' : 'unknown';
    if (CODE.has(ext)) return 'code';
    if (TEXT.has(ext)) return 'text';
    if (OFFICE.has(ext)) return 'office';
    if (ext === 'pdf') return 'pdf';
    if (CAD.has(ext)) return 'cad';
    if (IMAGE.has(ext)) return 'image';
    if (MEDIA.has(ext)) return 'media';
    if (ARCHIVE.has(ext)) return 'archive';
    if (BINARY.has(ext)) return 'binary';
    return 'unknown';
  };

  const isTextualPath = (path) => {
    const kind = kindForPath(path);
    return kind === 'text' || kind === 'code' || kind === 'unknown';
  };

  const hasBinaryContent = (bytes) => {
    const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || []);
    for (let index = 0; index < view.length; index += 1) {
      if (view[index] === 0) return true;
    }
    try {
      new TextDecoder('utf-8', { fatal: true }).decode(view);
      return false;
    } catch (_) {
      return true;
    }
  };

  const surfaceName = (kind) => {
    switch (kind) {
      case 'office': return 'Office editor';
      case 'pdf': case 'cad': case 'image': return 'viewer';
      case 'media': return 'media workbench';
      default: return 'workspace viewer';
    }
  };

  const refusal = (path, bytes) => {
    const kind = kindForPath(path);
    if (!isTextualPath(path)) {
      return { code: 'ENOTSUP', message: `${path} is a ${kind} document; open it in its native ${surfaceName(kind)}` };
    }
    if (bytes && hasBinaryContent(bytes)) {
      return { code: 'ENOTSUP', message: `${path} is binary and cannot be opened as text` };
    }
    return null;
  };

  scope.FloeIDEPolicy = { kindForPath, isTextualPath, hasBinaryContent, refusal, surfaceName };
  if (typeof module !== 'undefined' && module.exports) module.exports = scope.FloeIDEPolicy;
})(typeof window === 'undefined' ? globalThis : window);
