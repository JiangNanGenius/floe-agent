/* SPDX-License-Identifier: MPL-2.0
 * Floe neutral branding overlay (self-authored, 2026-10-26).
 *
 * Replaces the producer's unpublished --with-app-branding branding.js.
 * Defines only the two globals that the shipped mobile initializer reads.
 * No DOM handlers, timers, polling, remote fetches, credential access,
 * new permissions, or upstream branding code.
 *
 * Copyright 2026 the Floe project contributors.
 */
(function () {
  'use strict';
  window.brandProductName = 'Floe';
  window.brandProductURL = '';
})();
