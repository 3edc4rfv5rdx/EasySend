#!/usr/bin/env bash
#
# Create the signing key the Android release is built with, and the properties
# file android/app/build.gradle.kts reads it from.
#
# Run it once, by hand:  bash 77-MakeMyKey.sh
# It has no execute bit on purpose — this is not a step of any build, and a
# second run over an existing keystore would cost you every installed copy of
# the app: an APK signed with a new key cannot update one signed with the old.
#
set -e

# Before anything is created, not after: the keystore and the properties file
# both hold the signing password, and a chmod that follows the write leaves a
# window where they are readable by everybody on the machine.
umask 077

SAFE_DIR="$HOME/.my-safe"
STORE="$SAFE_DIR/my-release-key.jks"
PROPS="$SAFE_DIR/key.properties"
ALIAS="my-key-alias"
VALIDITY_DAYS=10000
# X.500 name written into the certificate: CN is the owner, OU the unit, O the
# organisation, C the country. Android checks the key, never these, so they are
# cosmetic; empty fields are left out rather than passed as blanks.
DNAME="CN=3edc4rfv5rdx, OU=EasySend, O=EasySend, C=UA"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,9p' "$0"
    exit 0
fi

command -v keytool >/dev/null 2>&1 || {
    echo "keytool not found — it comes with the JDK."
    exit 1
}

# Nothing here overwrites anything. Both files are named separately so the
# message says which one is in the way.
for f in "$STORE" "$PROPS"; do
    if [ -e "$f" ]; then
        echo "Already there: $f"
        echo "Move it aside yourself if you really mean to make a new key."
        exit 1
    fi
done

mkdir -p "$SAFE_DIR"
chmod 700 "$SAFE_DIR"

read -rsp "Keystore password: " STORE_PASS
echo
read -rsp "Repeat: " STORE_PASS2
echo
if [ "$STORE_PASS" != "$STORE_PASS2" ]; then
    echo "They differ."
    exit 1
fi
if [ ${#STORE_PASS} -lt 6 ]; then
    echo "keytool wants at least 6 characters."
    exit 1
fi

# One password for the store and the key: two of them buy nothing here and are
# one more thing to lose.
# The password goes in on stdin, not in the argument list: /proc/<pid>/cmdline is
# readable by every process on the machine for as long as keytool runs. Asked
# twice because that is what keytool wants for a new keystore, and -keypass is
# left out on purpose — a PKCS12 keystore, which is the default, keeps one
# password for the store and the key, which is what this script wants anyway.
printf '%s\n%s\n' "$STORE_PASS" "$STORE_PASS" | keytool -genkeypair -v \
    -keystore "$STORE" \
    -alias "$ALIAS" \
    -keyalg RSA -keysize 2048 \
    -validity "$VALIDITY_DAYS" \
    -dname "$DNAME"

cat > "$PROPS" <<PROPERTIES
storeFile=$STORE
storePassword=$STORE_PASS
keyAlias=$ALIAS
keyPassword=$STORE_PASS
PROPERTIES

chmod 600 "$PROPS" "$STORE"

echo
echo "Keystore: $STORE"
echo "Properties: $PROPS"
echo
echo "Back both up somewhere off this machine. Losing them means every device"
echo "that has the app installed can only take a fresh install, never an update."
