#!/bin/zsh

set -euo pipefail

IDENTITY_NAME="Recordly Local Development"
SECURITY_BIN="${RECORDLY_SECURITY_BIN:-/usr/bin/security}"
OPENSSL_BIN="${RECORDLY_OPENSSL_BIN:-$(command -v openssl)}"

fail() {
  echo "Local signing setup failed: $1" >&2
  exit 1
}

[[ -x "$SECURITY_BIN" ]] || fail "security tool not found at $SECURITY_BIN"
[[ -n "$OPENSSL_BIN" && -x "$OPENSSL_BIN" ]] || \
  fail "OpenSSL is required. Install it or set RECORDLY_OPENSSL_BIN."

if [[ -n "${RECORDLY_KEYCHAIN_PATH:-}" ]]; then
  KEYCHAIN_PATH="$RECORDLY_KEYCHAIN_PATH"
else
  KEYCHAIN_PATH="$($SECURITY_BIN default-keychain -d user)"
  KEYCHAIN_PATH="${KEYCHAIN_PATH#"${KEYCHAIN_PATH%%[![:space:]]*}"}"
  KEYCHAIN_PATH="${KEYCHAIN_PATH%"${KEYCHAIN_PATH##*[![:space:]]}"}"
  KEYCHAIN_PATH="${KEYCHAIN_PATH#\"}"
  KEYCHAIN_PATH="${KEYCHAIN_PATH%\"}"
  [[ -n "$KEYCHAIN_PATH" ]] || fail "could not determine the user login keychain"
fi

identity_exists() {
  "$SECURITY_BIN" find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | \
    grep -Fq "\"$IDENTITY_NAME\""
}

if identity_exists; then
  echo "Code-signing identity already exists: $IDENTITY_NAME"
  exit 0
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/recordly-local-signing.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

OPENSSL_CONFIG="$TEMP_DIR/openssl.cnf"
PRIVATE_KEY="$TEMP_DIR/identity.key"
CERTIFICATE="$TEMP_DIR/identity.crt"
PKCS12_FILE="$TEMP_DIR/identity.p12"
PKCS12_PASSWORD="$($OPENSSL_BIN rand -hex 32)"

cat > "$OPENSSL_CONFIG" <<EOF
[req]
prompt = no
distinguished_name = distinguished_name
x509_extensions = code_signing

[distinguished_name]
CN = $IDENTITY_NAME
O = Recordly Local Development

[code_signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

"$OPENSSL_BIN" req \
  -x509 \
  -newkey rsa:2048 \
  -sha256 \
  -days 3650 \
  -nodes \
  -keyout "$PRIVATE_KEY" \
  -out "$CERTIFICATE" \
  -config "$OPENSSL_CONFIG" \
  >/dev/null 2>&1 || fail "OpenSSL could not create the certificate"

PKCS12_COMPATIBILITY_ARGS=()
if "$OPENSSL_BIN" pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
  PKCS12_COMPATIBILITY_ARGS=(-legacy)
fi

"$OPENSSL_BIN" pkcs12 \
  -export \
  "${PKCS12_COMPATIBILITY_ARGS[@]}" \
  -inkey "$PRIVATE_KEY" \
  -in "$CERTIFICATE" \
  -name "$IDENTITY_NAME" \
  -out "$PKCS12_FILE" \
  -passout "pass:$PKCS12_PASSWORD" \
  >/dev/null 2>&1 || fail "OpenSSL could not create the PKCS#12 identity"

"$SECURITY_BIN" import "$PKCS12_FILE" \
  -k "$KEYCHAIN_PATH" \
  -P "$PKCS12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  >/dev/null || fail "could not import the identity into $KEYCHAIN_PATH"

"$SECURITY_BIN" add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN_PATH" \
  "$CERTIFICATE" \
  >/dev/null || fail "could not trust the certificate for code signing"

identity_exists || fail \
  "the imported identity is not valid; inspect it with security find-identity -v -p codesigning"

echo "Created code-signing identity: $IDENTITY_NAME"
echo "Keychain: $KEYCHAIN_PATH"
