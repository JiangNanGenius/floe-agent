/*
 * SPDX-License-Identifier: MPL-2.0
 *
 * floe_git_trust.c — see floe_git_trust.h. Floe-authored shim; NOT
 * upstream libgit2 code. Kept deliberately tiny: every decision that
 * requires libgit2 internals (variadic opts call, enum spelling) is
 * made here at compile time against the pinned 1.9.2 headers, and
 * everything policy-shaped stays in Swift where it is testable.
 */
#include "floe_git_trust.h"

int floe_git_set_ssl_cert_locations(const char *file, const char *path)
{
	/* git_mbedtls__set_cert_location asserts file || path; passing
	 * (NULL, NULL) through GIT_OPT would abort the process. The seam
	 * models "retire" on the Swift side (binding revoked + per-operation
	 * CA install); a full global clear is not needed and is refused here
	 * so it can never be called by mistake. */
	if (file == NULL && path == NULL)
		return -1;

	return git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, file, path);
}

void floe_git_fetch_options_forbid_offsite_redirects(git_fetch_options *opts)
{
	if (opts)
		opts->follow_redirects = GIT_REMOTE_REDIRECT_NONE;
}

void floe_git_push_options_forbid_offsite_redirects(git_push_options *opts)
{
	if (opts)
		opts->follow_redirects = GIT_REMOTE_REDIRECT_NONE;
}

int floe_git_redirect_policy_none_value(void)
{
	return (int)GIT_REMOTE_REDIRECT_NONE;
}
