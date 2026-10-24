/*
 * SPDX-License-Identifier: MPL-2.0
 *
 * floe_git_trust.h — Floe-authored narrow C shim for the Android Git
 * platform-trust seam (lane job-f74b2a485e9a4434, G04-R2 native Git
 * continuation of job-6cb7731a07774f01).
 *
 * WHY THIS FILE EXISTS
 *   Swift cannot call `git_libgit2_opts`, because it is a C variadic
 *   function (`int git_libgit2_opts(int option, ...)`), and no
 *   non-variadic public libgit2 entry point installs TLS trust
 *   locations. This shim fixes the argument list for the two
 *   supported options the FloeGit trust seam needs, and pins the
 *   redirect policy constants on the C side where the vendored
 *   libgit2 1.9.2 headers are authoritative. It contains NO other
 *   logic: no trust-all path, no certificate parsing, no config
 *   reads. All upstream libgit2 / mbedTLS / SwiftGitX bytes stay
 *   untouched (see ../FLOE_OVERLAY_HASHES.sha256 — this directory is
 *   the only non-upstream addition besides the documented
 *   mbedtls/floe-config header hunk).
 *
 * BACKEND SUPPORT (pinned 1.9.2 sources, verified in lane):
 *   src/libgit2/settings.c case GIT_OPT_SET_SSL_CERT_LOCATIONS
 *   dispatches to `git_mbedtls__set_cert_location(file, path)` when
 *   GIT_HTTPS_MBEDTLS is defined (the Android overlay build), to the
 *   OpenSSL helper for OpenSSL backends, and otherwise fails closed
 *   with "TLS backend doesn't support certificate locations" — the
 *   Apple overlay branch (SecureTransport) returns -1 from opts.
 *   `git_mbedtls__set_cert_location` itself GIT_ASSERT_ARGs that at
 *   least one of file/path is non-NULL, so clearing via this entry
 *   point would ABORT the process; floe_git_set_ssl_cert_locations
 *   therefore refuses (NULL, NULL) with a plain error return instead.
 */
#ifndef FLOE_GIT_TRUST_H
#define FLOE_GIT_TRUST_H

#include <git2.h>

/*
 * Install verified CA trust locations into the libgit2 TLS backend
 * for the CURRENT runtime epoch (git_libgit2_init refcount held by
 * the caller). `file` points to one PEM bundle (may contain multiple
 * certificates); `path` may be NULL. Returns 0 on success, -1 on
 * refusal or backend failure (callers read git_error_last()).
 */
int floe_git_set_ssl_cert_locations(const char *file, const char *path);

/*
 * Pin a fetch/clone-stage fetch options struct so the remote
 * transport never consults the repository's `http.followRedirects`
 * config and never follows an off-site redirect:
 * follow_redirects = GIT_REMOTE_REDIRECT_NONE (value 1; the value 0
 * means "unspecified" and is what lets untrusted .git/config widen
 * redirect following — src/libgit2/remote.c
 * git_remote_connect_options_normalize + lookup_redirect_config).
 * Same-HTTPS-host redirects keep working (git_net_url_apply_redirect
 * only rejects cross-host + non-upgrade scheme changes).
 */
void floe_git_fetch_options_forbid_offsite_redirects(git_fetch_options *opts);

/* Same pin for the push-stage options struct. */
void floe_git_push_options_forbid_offsite_redirects(git_push_options *opts);

/* The pinned mode constant as libgit2 itself defines it (1). Used by
 * the focused test suite to lock the seam against enum drift. */
int floe_git_redirect_policy_none_value(void);

#endif /* FLOE_GIT_TRUST_H */
