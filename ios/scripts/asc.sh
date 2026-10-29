#!/bin/bash
# Minimal App Store Connect API caller: ASC.sh METHOD PATH [JSON_BODY]
set -euo pipefail
KEY="$HOME/.appstoreconnect/private_keys/AuthKey_5D6627S3L2.p8"
KID="5D6627S3L2"
ISS="69a6de72-af42-47e3-e053-5b8c7c11a4d1"

b64url_raw() { # convert DER signature on stdin to base64url raw r||s
  python3 -c '
import sys,base64
d=sys.stdin.buffer.read()
i=2
assert d[0]==0x30
if d[1]&0x80: i=2+ (d[1]&0x7f)
# parse INTEGER r
assert d[i]==0x02
ln=d[i+1]; r=d[i+2:i+2+ln]
i=i+2+ln
assert d[i]==0x02
ln=d[i+1]; s=d[i+2:i+2+ln]
r=r[-32:].rjust(32,b"\0"); s=s[-32:].rjust(32,b"\0")
sys.stdout.write(base64.urlsafe_b64encode(r+s).decode().rstrip("="))
'
}
b64url_json() { python3 -c 'import sys,base64; sys.stdout.write(base64.urlsafe_b64encode(sys.stdin.buffer.read()).decode().rstrip("="))'; }

NOW=$(date +%s)
EXP=$((NOW+540))
HEADER=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$KID" | b64url_json)
PAYLOAD=$(printf '{"iss":"%s","cid":"%s","aud":"appstoreconnect-v1","exp":%d}' "$ISS" "$KID" "$EXP" | b64url_json)
SIGNING_INPUT="${HEADER}.${PAYLOAD}"
SIG=$(printf '%s' "$SIGNING_INPUT" | openssl dgst -sha256 -sign "$KEY" | b64url_raw)
JWT="${SIGNING_INPUT}.${SIG}"

M=${1:-GET}
P=${2:-/v1/apps}
BODY=${3:-}
if [ -n "$BODY" ]; then
  curl -sS -X "$M" "https://api.appstoreconnect.apple.com$P" \
    -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
    --data "$BODY"
else
  curl -sS -X "$M" "https://api.appstoreconnect.apple.com$P" \
    -H "Authorization: Bearer $JWT"
fi
