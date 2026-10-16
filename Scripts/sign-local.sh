#!/bin/sh
set -eu

app="${1:?Usage: sign-local.sh APP [KEYCHAIN]}"
keychain="${2:-$(security default-keychain -d user | sed 's/^ *"//; s/"$//')}"
identity_name="Geuntae bar Local Signing"

find_identity() {
    security find-identity -p codesigning "$keychain" |
        awk -F '"' -v name="$identity_name" '$2 == name {split($1, fields, " "); print fields[2]; exit}'
}

signing_identity="$(find_identity)"
if [ -z "$signing_identity" ]; then
    if security find-certificate -c "$identity_name" "$keychain" >/dev/null 2>&1; then
        echo "Local signing certificate exists but its private key is unavailable. Unlock or restore the keychain." >&2
        exit 1
    fi
    umask 077
    signing_tmp="$(mktemp -d "${TMPDIR:-/tmp}/geuntae-bar-signing.XXXXXX")"
    trap 'rm -rf "$signing_tmp"' EXIT
    trap 'exit 1' HUP INT TERM
    password="$(/usr/bin/openssl rand -hex 32)"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -subj "/CN=$identity_name" \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature' \
        -addext 'extendedKeyUsage=critical,codeSigning' \
        -keyout "$signing_tmp/key.pem" -out "$signing_tmp/cert.pem"
    /usr/bin/openssl pkcs12 -export -inkey "$signing_tmp/key.pem" \
        -in "$signing_tmp/cert.pem" -out "$signing_tmp/identity.p12" -passout "pass:$password"
    security import "$signing_tmp/identity.p12" -k "$keychain" -P "$password" -x -T /usr/bin/codesign
    signing_identity="$(find_identity)"
    if [ -z "$signing_identity" ]; then
        echo "Could not find the imported local signing identity." >&2
        exit 1
    fi
fi

codesign --force --sign "$signing_identity" --keychain "$keychain" --timestamp=none "$app"
codesign --verify --strict "$app"
case "$(codesign -dr - "$app" 2>&1)" in
    *cdhash*) echo "Keychain access requires a stable signing identity" >&2; exit 1 ;;
esac
