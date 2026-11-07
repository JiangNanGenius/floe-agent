# Floe package patch record

- Declare the `NIOFoundationCompat` product used by Citadel sources. Hosted App
  tests can make the product dynamic, which requires its imported dependency
  to be linked explicitly. Upstream versions and implementation are unchanged.

- Consume the root's maintained Swift Crypto 3.15.1 copy as one dynamic Crypto
  product, including its unchanged `_CryptoExtras` module. This prevents two
  Crypto runtime images in the App/hosted-test graph; see the Swift Crypto patch
  record. Citadel's Crypto and Extras imports and implementations are unchanged.
