#!/bin/bash
set -euo pipefail

name="CaptureMac Local"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "already set up"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.conf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -out "$work/identity.p12" -passout pass:capturemac 2>/dev/null

security import "$work/identity.p12" -k "$keychain" -P capturemac -T /usr/bin/codesign
echo "macos will ask for your password"
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"

echo "done!"
