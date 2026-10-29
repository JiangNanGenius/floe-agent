#!/usr/bin/env python3
"""Read-only App Store Connect certificate helper for the Floe Bridge identity.

This helper never reads, exports or logs the Developer ID private key. It works
only with the public PKCS#10 CSR, public certificate bytes and the existing
App Store Connect API key supplied by the caller's environment.

Safety properties:
  * Apple API base and certificate resource paths are fixed; redirects and
    non-Apple links are refused.
  * This helper is GET-only. It contains no POST, DELETE or revocation path.
  * Certificates are listed and matched by the CSR public key; an ambiguous
    match fails closed instead of choosing a certificate.
  * Errors are summarised and redacted; PEM blocks, bearer tokens and long
    base64 blobs are never printed.

Apple documents Developer ID certificate creation as available only through
the Apple Developer website or Xcode. This helper therefore does not attempt
creation; it reads and verifies the certificate after the portal issues it.
"""

from __future__ import annotations

import argparse
import base64
import datetime as _dt
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

API_BASE = "https://api.appstoreconnect.apple.com"
API_HOST = "api.appstoreconnect.apple.com"
CERT_TYPE = "DEVELOPER_ID_APPLICATION_G2"
# Public hash of the approved 2026-10-29 Floe Bridge CSR. Update only with a
# reviewed CSR replacement; this pin prevents accidentally submitting another
# key's request.
EXPECTED_CSR_SHA256 = "36960a59add0b28edb18d4d37d9e90f1cddbb482d50d8781c5898c86d6b08291"
CERT_FIELDS = (
    "certificateContent,certificateType,displayName,expirationDate,"
    "serialNumber,activated"
)
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_CERT_DER_BYTES = 64 * 1024
MAX_PAGES = 10
PAGE_LIMIT = 200
EXPIRING_SOON = _dt.timedelta(days=30)

_SECRET_PATTERNS = [
    re.compile(r"-----BEGIN [A-Z0-9 ]+-----.*?-----END [A-Z0-9 ]+-----", re.S),
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]{16,}"),
    re.compile(r"[A-Za-z0-9+/]{120,}={0,2}"),
]


class HelperError(Exception):
    """A bounded, user-facing failure with an exit code and optional context."""

    def __init__(
        self,
        message: str,
        exit_code: int = 2,
        http_status: int | None = None,
        apple_error: str | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.exit_code = exit_code
        self.http_status = http_status
        self.apple_error = apple_error


def redact(value: str) -> str:
    text = str(value)
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("<redacted>", text)
    return text.replace("\x00", "")


def now_utc() -> _dt.datetime:
    return _dt.datetime.now(_dt.timezone.utc)


def isoformat(value: _dt.datetime) -> str:
    return value.astimezone(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_time(value: Any) -> _dt.datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = _dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed.astimezone(_dt.timezone.utc)


def sha256_hex(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def run_tool(args: list[str], *, input_bytes: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            args,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=60,
        )
    except FileNotFoundError as error:
        raise HelperError(f"Required tool not found: {args[0]}") from error
    except subprocess.TimeoutExpired as error:
        raise HelperError(f"Tool timed out: {args[0]}") from error


def openssl_check(args: list[str], *, input_bytes: bytes | None = None, what: str) -> bytes:
    result = run_tool(["openssl", *args], input_bytes=input_bytes)
    if result.returncode != 0:
        detail = redact(result.stderr.decode("utf-8", "replace")).strip()[:300]
        raise HelperError(f"OpenSSL {what} failed" + (f": {detail}" if detail else ""))
    return result.stdout


def public_key_sha256_from_csr(csr_path: Path) -> str:
    pem = openssl_check(
        ["req", "-in", str(csr_path), "-pubkey", "-noout"],
        what="CSR public-key extraction",
    )
    der = openssl_check(
        ["pkey", "-pubin", "-outform", "DER"],
        input_bytes=pem,
        what="CSR public-key conversion",
    )
    return sha256_hex(der)


def public_key_sha256_from_der_certificate(der: bytes) -> str:
    if not 100 <= len(der) <= MAX_CERT_DER_BYTES:
        raise HelperError("Certificate bytes are outside the accepted size range")
    pem = openssl_check(
        ["x509", "-inform", "DER", "-pubkey", "-noout"],
        input_bytes=der,
        what="certificate public-key extraction",
    )
    spki = openssl_check(
        ["pkey", "-pubin", "-outform", "DER"],
        input_bytes=pem,
        what="certificate public-key conversion",
    )
    return sha256_hex(spki)


def der_to_pem(der: bytes) -> str:
    pem = openssl_check(
        ["x509", "-inform", "DER", "-outform", "PEM"],
        input_bytes=der,
        what="certificate PEM conversion",
    )
    return pem.decode("ascii")


def load_csr(path_value: str) -> dict[str, Any]:
    path = Path(path_value).expanduser()
    if not path.is_file():
        raise HelperError(f"CSR not found: {path}")
    raw = path.read_bytes()
    if not 200 <= len(raw) <= 16 * 1024:
        raise HelperError("CSR size is outside the accepted range")
    digest = sha256_hex(raw)
    if digest != EXPECTED_CSR_SHA256:
        raise HelperError(
            "CSR SHA-256 does not match the approved Floe Bridge CSR; "
            "this helper is pinned to the reviewed 2026-10-29 request"
        )
    text = raw.decode("ascii", "strict")
    if text.count("-----BEGIN CERTIFICATE REQUEST-----") != 1 or text.count(
        "-----END CERTIFICATE REQUEST-----"
    ) != 1:
        raise HelperError("CSR must contain exactly one PKCS#10 request")
    verify = run_tool(["openssl", "req", "-in", str(path), "-noout", "-verify"])
    if verify.returncode != 0:
        raise HelperError("OpenSSL reported an invalid CSR signature")
    subject_output = openssl_check(
        ["req", "-in", str(path), "-noout", "-subject", "-nameopt", "RFC2253"],
        what="CSR subject read",
    ).decode("utf-8", "replace").strip()
    subject = subject_output[len("subject="):] if subject_output.startswith("subject=") else subject_output
    return {
        "path": str(path),
        "sha256": digest,
        "public_key_sha256": public_key_sha256_from_csr(path),
        "subject": subject,
        "pem": text,
    }


def generate_token(repo_root: Path) -> str:
    missing = [
        name
        for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH")
        if not os.environ.get(name, "").strip()
    ]
    if missing:
        raise HelperError("Missing App Store Connect credential environment: " + ", ".join(missing))
    script = repo_root / "FloeAgent" / "scripts" / "generate_asc_jwt.py"
    if not script.is_file():
        raise HelperError(f"JWT helper not found: {script}")
    environment = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "ASC_KEY_ID": os.environ["ASC_KEY_ID"],
        "ASC_ISSUER_ID": os.environ["ASC_ISSUER_ID"],
        "ASC_PRIVATE_KEY_PATH": os.environ["ASC_PRIVATE_KEY_PATH"],
    }
    result = subprocess.run(
        [sys.executable, str(script)],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=60,
    )
    token = result.stdout.decode("ascii", "replace").strip()
    if result.returncode != 0 or token.count(".") != 2 or len(token) < 100:
        raise HelperError("App Store Connect token generation failed")
    return token


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


def _validate_api_url(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname != API_HOST:
        raise HelperError("Refusing a non-Apple API URL")
    if not parsed.path.startswith("/v1/certificates"):
        raise HelperError("Refusing a non-certificate API path")
    return url


def api_request(
    method: str,
    path_or_url: str,
    token: str,
) -> tuple[int, dict[str, Any]]:
    if method != "GET":
        raise HelperError("This certificate helper is read-only")
    if path_or_url.startswith("https://"):
        url = _validate_api_url(path_or_url)
    else:
        if not path_or_url.startswith("/v1/certificates"):
            raise HelperError("Refusing a non-certificate API path")
        url = API_BASE + path_or_url
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "User-Agent": "floe-bridge-certificate-helper/1",
    }
    request = urllib.request.Request(url, headers=headers, method="GET")
    opener = urllib.request.build_opener(_NoRedirect())
    try:
        with opener.open(request, timeout=45) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            if len(raw) > MAX_RESPONSE_BYTES:
                raise HelperError("Apple response exceeded the accepted size")
            return response.status, json.loads(raw.decode("utf-8") or "{}")
    except urllib.error.HTTPError as error:
        if 300 <= error.code < 400:
            raise HelperError("Refusing an HTTP redirect from the Apple API", http_status=error.code)
        raw = error.read(MAX_RESPONSE_BYTES)
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            payload = {}
        return error.code, payload


def summarize_apple_error(payload: dict[str, Any]) -> str:
    errors = payload.get("errors")
    if not isinstance(errors, list) or not errors:
        return "no Apple error detail"
    parts: list[str] = []
    for item in errors[:3]:
        if not isinstance(item, dict):
            continue
        status = str(item.get("status", "")).strip()
        code = str(item.get("code", "")).strip()
        title = str(item.get("title", "")).strip()
        detail = redact(str(item.get("detail", ""))).strip()[:300]
        label = " ".join(piece for piece in (status, code) if piece)
        text = ": ".join(piece for piece in (title, detail) if piece)
        parts.append(f"{label} {text}".strip())
    return " | ".join(parts) or "no Apple error detail"


def auth_hint(status: int) -> str:
    if status == 401:
        return (
            "Apple rejected the token. Check the key ID, issuer ID, private key file, "
            "system clock and that the key has not been revoked."
        )
    if status == 403:
        return (
            "The App Store Connect key is not authorised for this certificate request. "
            "Developer ID certificate access requires the Account Holder, or an Admin "
            "with the Developer ID certificate access role. The portal remains the "
            "documented Developer ID issuance route."
        )
    return "Apple returned an unexpected status."


def _is_filter_rejection(payload: dict[str, Any]) -> bool:
    text = summarize_apple_error(payload).lower()
    return "filter" in text or "certificatetype" in text or "certificate_type" in text


def _certificate_page_path(with_filter: bool) -> str:
    query = [
        ("fields[certificates]", CERT_FIELDS),
        ("limit", str(PAGE_LIMIT)),
    ]
    if with_filter:
        query.append(("filter[certificateType]", CERT_TYPE))
    return "/v1/certificates?" + urllib.parse.urlencode(query)


def list_certificates(token: str, *, with_filter: bool = True) -> tuple[list[dict[str, Any]], bool]:
    """Return certificate resources and whether the G2 filter was accepted."""
    items: list[dict[str, Any]] = []
    url = _certificate_page_path(with_filter)
    filter_supported = with_filter
    for page in range(MAX_PAGES):
        status, payload = api_request("GET", url, token)
        if status == 400 and with_filter and page == 0 and _is_filter_rejection(payload):
            return list_certificates(token, with_filter=False)
        if status in (401, 403):
            raise HelperError(
                auth_hint(status),
                exit_code=3 if status == 401 else 4,
                http_status=status,
                apple_error=summarize_apple_error(payload),
            )
        if status != 200:
            raise HelperError(
                f"Certificate listing failed with HTTP {status}: {summarize_apple_error(payload)}",
                http_status=status,
                apple_error=summarize_apple_error(payload),
            )
        data = payload.get("data")
        if not isinstance(data, list):
            raise HelperError("Apple returned an unexpected certificate list shape")
        items.extend(item for item in data if isinstance(item, dict))
        next_url = (payload.get("links") or {}).get("next")
        if not next_url:
            break
        url = _validate_api_url(next_url)
    else:
        raise HelperError("Certificate pagination exceeded the bounded page limit")
    return items, filter_supported


def _certificate_match(
    item: dict[str, Any],
    csr_public_key_sha256: str,
) -> tuple[dict[str, Any] | None, str | None]:
    attrs = item.get("attributes")
    if not isinstance(attrs, dict):
        return None, "certificate item has no attributes"
    certificate_type = attrs.get("certificateType")
    if certificate_type != CERT_TYPE:
        return None, None
    if attrs.get("activated") is False:
        return None, f"inactive {CERT_TYPE} certificate {item.get('id', 'unknown')} skipped"
    content = attrs.get("certificateContent")
    if not isinstance(content, str) or not content.strip():
        return None, f"certificate {item.get('id', 'unknown')} has no certificateContent"
    try:
        der = base64.b64decode(content, validate=True)
    except (ValueError, TypeError):
        return None, f"certificate {item.get('id', 'unknown')} has invalid base64 content"
    try:
        public_key_sha256 = public_key_sha256_from_der_certificate(der)
    except HelperError as error:
        return None, f"certificate {item.get('id', 'unknown')}: {error.message}"
    if public_key_sha256 != csr_public_key_sha256:
        return None, None
    expiry = parse_time(attrs.get("expirationDate"))
    if expiry is not None and expiry <= now_utc():
        return None, f"matching certificate {item.get('id', 'unknown')} is expired"
    serial = str(attrs.get("serialNumber") or item.get("id") or "unknown")
    return {
        "id": str(item.get("id") or ""),
        "displayName": str(attrs.get("displayName") or ""),
        "certificateType": CERT_TYPE,
        "serialNumber": serial,
        "expirationDate": attrs.get("expirationDate"),
        "activated": attrs.get("activated"),
        "expiringSoon": bool(expiry is not None and expiry - now_utc() <= EXPIRING_SOON),
        "publicKeySha256": public_key_sha256,
        "der": der,
        "pem": der_to_pem(der),
        "derSha256": sha256_hex(der),
    }, None


def match_certificates(
    items: list[dict[str, Any]],
    csr_public_key_sha256: str,
) -> tuple[list[dict[str, Any]], list[str]]:
    matches: list[dict[str, Any]] = []
    notes: list[str] = []
    for item in items:
        match, note = _certificate_match(item, csr_public_key_sha256)
        if note:
            notes.append(note)
        if match:
            matches.append(match)
    return matches, notes


def sanitize_component(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("._")
    return (cleaned or "certificate")[:80]


def write_certificate(certificate: dict[str, Any], out_dir: Path) -> dict[str, Any]:
    stem = "FloeBridge-DeveloperID-" + sanitize_component(str(certificate.get("serialNumber") or certificate["id"]))
    der_path = out_dir / f"{stem}.cer"
    pem_path = out_dir / f"{stem}.pem"
    actions: list[str] = []
    for path, payload in ((der_path, certificate["der"]), (pem_path, certificate["pem"].encode("ascii"))):
        if path.exists():
            if path.read_bytes() != payload:
                raise HelperError(f"Refusing to overwrite a different existing certificate file: {path.name}")
            actions.append(f"{path.name}=unchanged")
        else:
            path.write_bytes(payload)
            path.chmod(0o644)
            actions.append(f"{path.name}=written")
    metadata = {
        "id": certificate["id"],
        "displayName": certificate["displayName"],
        "certificateType": certificate["certificateType"],
        "serialNumber": certificate["serialNumber"],
        "expirationDate": certificate["expirationDate"],
        "activated": certificate["activated"],
        "expiringSoon": certificate["expiringSoon"],
        "publicKeySha256": certificate["publicKeySha256"],
        "derSha256": certificate["derSha256"],
        "files": [der_path.name, pem_path.name],
    }
    write_json(out_dir / "certificate.json", metadata)
    return {"certificate": metadata, "files": actions}


def certificate_summary(
    matches: list[dict[str, Any]],
    notes: list[str],
    filter_supported: bool,
    csr: dict[str, Any],
) -> dict[str, Any]:
    return {
        "csr": {
            "path": Path(csr["path"]).name,
            "sha256": csr["sha256"],
            "publicKeySha256": csr["public_key_sha256"],
            "subject": csr["subject"],
        },
        "api": {
            "base": API_BASE,
            "certificateType": CERT_TYPE,
            "g2FilterAccepted": filter_supported,
            "status": "ok",
        },
        "matches": [
            {
                key: value
                for key, value in match.items()
                if key not in ("der", "pem")
            }
            for match in matches
        ],
        "notes": notes,
        "checkedAt": isoformat(now_utc()),
    }


def probe(args: argparse.Namespace, token: str) -> dict[str, Any]:
    csr = load_csr(args.csr)
    items, filter_supported = list_certificates(token)
    matches, notes = match_certificates(items, csr["public_key_sha256"])
    summary = certificate_summary(matches, notes, filter_supported, csr)
    summary["operation"] = "probe"
    summary["certificateCount"] = len(items)
    write_json(args.out_dir / "probe.json", summary)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return summary


def fetch(args: argparse.Namespace, token: str) -> dict[str, Any]:
    csr = load_csr(args.csr)
    items, filter_supported = list_certificates(token)
    matches, notes = match_certificates(items, csr["public_key_sha256"])
    summary = certificate_summary(matches, notes, filter_supported, csr)
    summary["operation"] = "fetch"
    summary["certificateCount"] = len(items)
    write_json(args.out_dir / "probe.json", summary)
    if not matches:
        raise HelperError(
            "No active Developer ID Application G2 certificate matches the approved CSR public key. "
            "Issue the certificate through the Apple Developer website or Xcode, then re-run fetch.",
            exit_code=3,
        )
    if len(matches) > 1:
        ids = ", ".join(match["id"] for match in matches)
        raise HelperError(
            f"More than one matching certificate was found ({ids}); refusing to choose one.",
            exit_code=4,
        )
    written = write_certificate(matches[0], args.out_dir)
    result = {**summary, **written, "outcome": "fetched"}
    write_json(args.out_dir / "result.json", result)
    print(json.dumps({**summary, "written": written}, indent=2, sort_keys=True))
    return result


def load_certificate_bytes(path_value: str) -> bytes:
    path = Path(path_value).expanduser()
    if not path.is_file():
        raise HelperError(f"Certificate not found: {path}")
    raw = path.read_bytes()
    if not 100 <= len(raw) <= MAX_CERT_DER_BYTES:
        raise HelperError("Certificate size is outside the accepted range")
    return raw


def certificate_fields(raw: bytes, what: str) -> str:
    if b"-----BEGIN CERTIFICATE-----" in raw:
        return openssl_check(["x509", "-inform", "PEM", "-noout", "-subject", "-issuer", "-serial", "-startdate", "-enddate"], input_bytes=raw, what=what).decode("utf-8", "replace")
    return openssl_check(["x509", "-inform", "DER", "-noout", "-subject", "-issuer", "-serial", "-startdate", "-enddate"], input_bytes=raw, what=what).decode("utf-8", "replace")


def verify_certificate(args: argparse.Namespace) -> dict[str, Any]:
    csr = load_csr(args.csr)
    raw = load_certificate_bytes(args.cert)
    if b"-----BEGIN CERTIFICATE-----" in raw:
        der = openssl_check(["x509", "-inform", "PEM", "-outform", "DER"], input_bytes=raw, what="certificate DER conversion")
    else:
        der = raw
    public_key_sha256 = public_key_sha256_from_der_certificate(der)
    fields = certificate_fields(der, "certificate field read")
    values: dict[str, str] = {}
    for line in fields.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    subject = values.get("subject", "")
    issuer = values.get("issuer", "")
    serial = values.get("serial", "")
    not_after = values.get("notAfter", "")
    expiry = None
    if not_after:
        try:
            expiry = _dt.datetime.strptime(not_after, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=_dt.timezone.utc)
        except ValueError:
            expiry = None
    expired = bool(expiry is not None and expiry <= now_utc())
    issuer_ok = "Developer ID" in issuer and "Certification Authority" in issuer
    text = openssl_check(["x509", "-inform", "DER", "-noout", "-text"], input_bytes=der, what="certificate text read").decode("utf-8", "replace")
    eku_code_signing = "Code Signing" in text and "Extended Key Usage" in text
    match = public_key_sha256 == csr["public_key_sha256"]
    summary = {
        "operation": "verify-cert",
        "csr": {
            "sha256": csr["sha256"],
            "publicKeySha256": csr["public_key_sha256"],
            "subject": csr["subject"],
        },
        "certificate": {
            "sha256": sha256_hex(der),
            "publicKeySha256": public_key_sha256,
            "subject": subject,
            "issuer": issuer,
            "serial": serial,
            "notAfter": not_after,
            "expired": expired,
            "issuerLooksLikeDeveloperId": issuer_ok,
            "ekuCodeSigning": eku_code_signing,
        },
        "publicKeyMatch": match,
        "checkedAt": isoformat(now_utc()),
    }
    write_json(args.out_dir / "verify-cert.json", summary)
    print(json.dumps(summary, indent=2, sort_keys=True))
    if not match:
        raise HelperError(
            "Downloaded certificate public key does not match the approved CSR. "
            "Do not import it; the portal may have returned a different existing certificate.",
            exit_code=5,
        )
    if expired:
        raise HelperError("Downloaded certificate is already expired", exit_code=5)
    if not issuer_ok:
        raise HelperError("Downloaded certificate does not look like a Developer ID certificate", exit_code=5)
    if not eku_code_signing:
        raise HelperError("Downloaded certificate does not show the Code Signing extended key usage", exit_code=5)
    return summary


def csr_info(args: argparse.Namespace) -> dict[str, Any]:
    csr = load_csr(args.csr)
    summary = {
        "operation": "csr-info",
        "path": csr["path"],
        "sha256": csr["sha256"],
        "publicKeySha256": csr["public_key_sha256"],
        "subject": csr["subject"],
    }
    write_json(args.out_dir / "csr-info.json", summary)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--repo-root",
        default=str(Path(__file__).resolve().parents[2]),
        help="Repository root containing FloeAgent/scripts/generate_asc_jwt.py",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("--csr", required=True, help="Public PKCS#10 CSR path")
        sub.add_argument("--out-dir", default="bridge-cert-out", help="Directory for public outputs")

    for name in ("probe", "fetch"):
        sub = subparsers.add_parser(name)
        add_common(sub)
    verify = subparsers.add_parser("verify-cert")
    add_common(verify)
    verify.add_argument("--cert", required=True, help="Downloaded .cer or .pem path")
    info = subparsers.add_parser("csr-info")
    add_common(info)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    args.out_dir = Path(args.out_dir).expanduser().resolve()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    try:
        if args.command == "csr-info":
            csr_info(args)
            return 0
        if args.command == "verify-cert":
            verify_certificate(args)
            return 0
        token = generate_token(Path(args.repo_root).expanduser().resolve())
        if args.command == "probe":
            probe(args, token)
            return 0
        if args.command == "fetch":
            fetch(args, token)
            return 0
        raise HelperError("Unsupported command")
    except HelperError as error:
        failure = {
            "operation": args.command,
            "message": redact(error.message),
            "httpStatus": error.http_status,
            "appleError": redact(error.apple_error) if error.apple_error else None,
            "checkedAt": isoformat(now_utc()),
        }
        write_json(args.out_dir / "error.json", failure)
        print(f"error: {failure['message']}", file=sys.stderr)
        if failure["appleError"]:
            print(f"apple: {failure['appleError']}", file=sys.stderr)
        return error.exit_code
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
