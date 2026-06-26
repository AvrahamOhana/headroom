#!/bin/bash
# Get a TONE3000 OAuth access token via PKCE (for API testing).
# Prereq: register  namrig://oauth-callback  as a redirect URI in TONE3000 settings.
# Usage:  bash tools/t3k_token.sh

CLIENT_ID="t3k_pub_hTu9uxJ8c4u7vvPiaz2DQ-FoMul2X5m9"
REDIRECT="namrig://oauth-callback"
REDIRECT_ENC="namrig%3A%2F%2Foauth-callback"
BASE="https://www.tone3000.com/api/v1"

VERIFIER=$(openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
CHALLENGE=$(printf "%s" "$VERIFIER" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '=')
STATE=$(openssl rand -hex 8)

echo
echo "──────────────────────────────────────────────────────────────"
echo "STEP 1 — open this URL in a browser, log in, and click Authorize:"
echo "──────────────────────────────────────────────────────────────"
echo
echo "${BASE}/oauth/authorize?client_id=${CLIENT_ID}&redirect_uri=${REDIRECT_ENC}&response_type=code&code_challenge=${CHALLENGE}&code_challenge_method=S256&state=${STATE}"
echo
echo "The browser will try to open  namrig://oauth-callback?code=...  and show"
echo "an error — that's expected. Copy that whole URL from the address bar."
echo
read -r -p "STEP 2 — paste the namrig:// URL (or just the code) here: " INPUT

CODE=$(printf "%s" "$INPUT" | sed -n 's/.*code=\([^&]*\).*/\1/p')
[ -z "$CODE" ] && CODE="$INPUT"

echo
echo "STEP 3 — exchanging for a token…"
echo
RESP=$(curl -s -X POST "${BASE}/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=${CODE}" \
  --data-urlencode "code_verifier=${VERIFIER}" \
  --data-urlencode "redirect_uri=${REDIRECT}" \
  --data-urlencode "client_id=${CLIENT_ID}")

echo "$RESP"
echo
TOKEN=$(printf "%s" "$RESP" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
if [ -n "$TOKEN" ]; then
  echo "✅ access_token:"
  echo "$TOKEN"
else
  echo "⚠️  No access_token in the response above (check the error / redirect URI registration)."
fi
echo
