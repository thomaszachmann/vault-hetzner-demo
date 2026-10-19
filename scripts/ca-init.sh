#!/usr/bin/env bash
# Erzeugt die Offline-Root-CA, die in der Demo die "übergeordnete behördliche PKI" darstellt.
# Sie wird EINMAL erzeugt und überlebt jedes `mise run destroy` – so muss der Laptop
# ihr nur einmal vertrauen. Der private Schlüssel verlässt den Laptop nie.
set -euo pipefail

CA_DIR=".secrets/ca"
mkdir -p "$CA_DIR"
chmod 700 .secrets "$CA_DIR"

if [[ -f "$CA_DIR/root-ca.pem" ]]; then
  echo "Root-CA existiert bereits: $CA_DIR/root-ca.pem (wird nicht überschrieben)"
  exit 0
fi

openssl ecparam -name secp384r1 -genkey -noout -out "$CA_DIR/root-ca.key"
chmod 600 "$CA_DIR/root-ca.key"

openssl req -x509 -new -key "$CA_DIR/root-ca.key" -sha384 -days 3650 \
  -subj "/C=DE/O=Vault Demo Behoerde/OU=Offline Root/CN=Vault Demo Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -out "$CA_DIR/root-ca.pem"

echo "Root-CA erzeugt: $CA_DIR/root-ca.pem"
echo
echo "Einmalig dem Laptop vertrauen (fragt nach dem macOS-Passwort):"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $PWD/$CA_DIR/root-ca.pem"
