#!/usr/bin/env python3
"""guest-https-check.py — real HTTPS request with the platform's default
certificate verification, run inside the guest.

Prints FLOE_STAGE2_PY_HTTPS_200 on success (marker assembled at runtime, never
present in the script bytes), FLOE_STAGE2_PY_HTTPS_FAIL plus the exception on
failure. There is no opt-out of verification anywhere in this file: a 1970
clock or a missing CA store must fail loudly, because that is exactly the
failure mode the image build has to detect.
"""
import ssl
import sys
import time
import urllib.request

URL = "https://deb.debian.org/debian/dists/trixie/Release"


def main():
    print("url=%s" % URL)
    print("utc=%s" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    print("tls=%s" % ssl.OPENSSL_VERSION)
    try:
        with urllib.request.urlopen(URL, timeout=45) as response:
            body = response.read(120)
            status = getattr(response, "status", 0)
            print("FLOE_STAGE2_PY_HTTPS_%d" % status)
            print("first_line=%s" % body.split(b"\n", 1)[0].decode("utf-8", "replace"))
            if status != 200:
                return 1
    except Exception as exc:  # noqa: BLE001 - the failure detail is the evidence
        print("FLOE_STAGE2_PY_HTTPS_FAIL")
        print("error=%s" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
