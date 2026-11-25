#!/bin/zsh
# Creates a self-signed "Air Local Code Signing" identity in the login keychain (code signing only,
# not trusted system-wide), so macOS keeps Air's permissions across rebuilds.
# Remove it later with:  security delete-identity -c "Air Local Code Signing"
#   (or Keychain Access > login > My Certificates > "Air Local Code Signing" > Delete)
set -euo pipefail
NAME="Air Local Code Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "Already exists."; exit 0; fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name=dn
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -config "$TMP/ext.cnf" -extensions ext 2>/dev/null
PASS=$(openssl rand -hex 12)
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/air.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/air.p12" -passout "pass:$PASS"
security import "$TMP/air.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\"."
