// SPDX-License-Identifier: MPL-2.0
#pragma once
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// A single anonymous GET: approved numeric destination, origin TLS/Host, no
// automatic redirect, proxy, cookie engine, credentials or shared easy handle.
typedef struct {
    unsigned char *bytes;
    size_t length, capacity, headerBytes;
    int truncated;
    long status;
    char *mime, *redirect;
    int (*isCancelled)(void *);
    void *cancelContext;
} FloeWebTransfer;

static inline size_t floe_web_body(char *bytes, size_t size, size_t count, void *opaque) {
    FloeWebTransfer *t = (FloeWebTransfer *)opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    size_t keep = length < t->capacity - t->length ? length : t->capacity - t->length;
    memcpy(t->bytes + t->length, bytes, keep);
    t->length += keep;
    if (keep < length) t->truncated = 1;
    return keep;
}

static inline size_t floe_web_header(char *bytes, size_t size, size_t count, void *opaque) {
    (void)bytes;
    FloeWebTransfer *t = (FloeWebTransfer *)opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length > 65536 - t->headerBytes) return 0;
    t->headerBytes += length;
    return length;
}

static inline int floe_web_progress(void *opaque, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
    (void)a; (void)b; (void)c; (void)d;
    FloeWebTransfer *t = (FloeWebTransfer *)opaque;
    return t->isCancelled(t->cancelContext);
}

static inline CURLcode floe_web_get(const char *url, const char *pin, long timeoutMillis, FloeWebTransfer *t) {
    CURL *curl = curl_easy_init();
    if (!curl) return CURLE_FAILED_INIT;
    struct curl_slist *destination = curl_slist_append(NULL, pin);
    CURLcode rc = CURLE_OUT_OF_MEMORY;
    if (!destination) goto cleanup;
    #define FLOE_WEB_OPT(opt, value) do { rc = curl_easy_setopt(curl, opt, value); if (rc != CURLE_OK) goto cleanup; } while (0)
    FLOE_WEB_OPT(CURLOPT_URL, url);
    FLOE_WEB_OPT(CURLOPT_PROTOCOLS_STR, "https");
    FLOE_WEB_OPT(CURLOPT_CONNECT_TO, destination);
    FLOE_WEB_OPT(CURLOPT_PROXY, "");
    FLOE_WEB_OPT(CURLOPT_FOLLOWLOCATION, 0L);
    FLOE_WEB_OPT(CURLOPT_DISALLOW_USERNAME_IN_URL, 1L);
    FLOE_WEB_OPT(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    FLOE_WEB_OPT(CURLOPT_HTTPAUTH, (long)CURLAUTH_NONE);
    FLOE_WEB_OPT(CURLOPT_ACCEPT_ENCODING, "");
    FLOE_WEB_OPT(CURLOPT_USERAGENT, "FloeAgent/1.0");
    FLOE_WEB_OPT(CURLOPT_TIMEOUT_MS, timeoutMillis);
    FLOE_WEB_OPT(CURLOPT_NOSIGNAL, 1L);
    FLOE_WEB_OPT(CURLOPT_WRITEDATA, t);
    FLOE_WEB_OPT(CURLOPT_WRITEFUNCTION, floe_web_body);
    FLOE_WEB_OPT(CURLOPT_HEADERDATA, t);
    FLOE_WEB_OPT(CURLOPT_HEADERFUNCTION, floe_web_header);
    FLOE_WEB_OPT(CURLOPT_XFERINFODATA, t);
    FLOE_WEB_OPT(CURLOPT_XFERINFOFUNCTION, floe_web_progress);
    FLOE_WEB_OPT(CURLOPT_NOPROGRESS, 0L);
    #undef FLOE_WEB_OPT
    rc = curl_easy_perform(curl);
    if (rc == CURLE_WRITE_ERROR && t->truncated) rc = CURLE_OK;
    if (rc == CURLE_OK) {
        char *mime = NULL, *next = NULL;
        rc = curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &t->status);
        if (rc != CURLE_OK) goto cleanup;
        rc = curl_easy_getinfo(curl, CURLINFO_CONTENT_TYPE, &mime);
        if (rc != CURLE_OK) goto cleanup;
        rc = curl_easy_getinfo(curl, CURLINFO_REDIRECT_URL, &next);
        if (rc != CURLE_OK) goto cleanup;
        if (mime && !(t->mime = strdup(mime))) rc = CURLE_OUT_OF_MEMORY;
        if (next && !(t->redirect = strdup(next))) rc = CURLE_OUT_OF_MEMORY;
    }
cleanup:
    curl_easy_cleanup(curl);
    curl_slist_free_all(destination);
    return rc;
}
