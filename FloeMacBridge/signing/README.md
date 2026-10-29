# Floe Bridge Developer ID signing material

This directory contains only public certificate-signing material for the Floe
Bridge macOS companion. The corresponding private key is a permanent RSA-2048
key in the release Mac's login Keychain (label `Floe Bridge Developer ID
20261029`, application tag `org.floeagent.bridge.developer-id.20261029`). The
private key is never exported, copied into a repository, uploaded as an
artifact, or passed to CI.

## Approved CSR

`FloeBridge-DeveloperID-20261029.certSigningRequest`

| Field | Value |
| --- | --- |
| SHA-256 | `36960a59add0b28edb18d4d37d9e90f1cddbb482d50d8781c5898c86d6b08291` |
| Public-key SHA-256 (SPKI DER) | `10ff001d145474dbbf9ec77aa98799decbcbc0411ac47badfcdbf70b8b9d7bab` |
| Subject | `CN=Floe Bridge Release` |
| Key | RSA 2048, SHA-256 PKCS#1 v1.5 signature |

Verify the committed copy without touching a private key:

```sh
openssl req -in FloeMacBridge/signing/FloeBridge-DeveloperID-20261029.certSigningRequest \
  -noout -verify -subject
shasum -a 256 FloeMacBridge/signing/FloeBridge-DeveloperID-20261029.certSigningRequest
```

The certificate helper pins the CSR SHA-256 in `asc_certificate.py`. A new CSR
therefore requires a reviewed code change as well as a reviewed signing file.

## Issuing the certificate (documented route)

Apple's current Certificates documentation states that Developer ID
certificates can only be created through the Apple Developer website or Xcode.
The App Store Connect API exposes the `DEVELOPER_ID_APPLICATION_G2` type for
reading/filtering certificates, but the public API is not the documented
creation route.

1. In Apple Developer, open **Certificates, Identifiers & Profiles** >
   **Certificates** > **+** > **Software** > **Developer ID** > **Continue**.
2. Select **Developer ID Application** and upload the approved CSR.
3. Download the issued `.cer` file.
4. Before importing, verify that the certificate belongs to this CSR:

   ```sh
   python3 FloeMacBridge/scripts/asc_certificate.py verify-cert \
     --csr FloeMacBridge/signing/FloeBridge-DeveloperID-20261029.certSigningRequest \
     --cert "$HOME/Downloads/developerID_application.cer" \
     --out-dir "$HOME/Downloads/bridge-certificate-out"
   ```

   A public-key mismatch must stop the process. The portal has been observed
   returning an existing certificate regardless of the uploaded CSR; importing
   such a certificate produces an unusable identity and can consume the
   five-certificate Developer ID Application allowance.
5. Import the matching `.cer` into the login Keychain and confirm the identity:

   ```sh
   security import "$HOME/Downloads/developerID_application.cer" \
     -k "$HOME/Library/Keychains/login.keychain-db"
   security find-identity -v -p codesigning
   ```

   The expected entry is `Developer ID Application: ... (TEAMID)`.
6. Do not revoke existing certificates. The account allows up to five
   Developer ID Application certificates; reuse an existing matching
   certificate when its public key is the approved one.

Developer ID certificate access requires the Account Holder, or an Admin with
the Developer ID certificate access role. The release owner performs the
portal step; CI does not need the private key or a portal session.

## Notarization

The release workflow uses the existing App Store Connect team key on a macOS
runner. It accepts only a signed, source-bound bridge artifact; signing stays
on the release Mac. See the release-owner dispatch notes supplied with the
review patch.
