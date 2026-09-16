#!/usr/bin/env bash
#
# FundedFirm auto-register + Guerrilla Mail auto-verify
#
# Flow:
#   1. Claim a Guerrilla Mail address (sharklasers.com) on a persistent session
#   2. POST /api/register on FundedFirm with that email
#   3. Poll the Guerrilla inbox until the verification email arrives
#   4. Extract the "Verify Email" link from the email body
#   5. Call the real confirmRegistration endpoint (verifies the account)
#   6. Append the account credentials to accounts.txt for later login
#
set -euo pipefail

GM_API="https://api.guerrillamail.com/ajax.php"
FF_API="https://api.fundedfirm.com/api/register"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"
PASSWORD="${FF_PASSWORD:-Harrylove@8018}"
# Where to store accounts. On Render, set DATA_DIR to the persistent disk mount
# (e.g. /data) so records survive restarts/deploys. Falls back to script dir.
DATA_DIR="${DATA_DIR:-$(dirname "$0")}"
ACCOUNTS_FILE="${DATA_DIR%/}/accounts.txt"
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

log() { printf '\033[1;36m%s\033[0m\n' "$*"; }

# Portable UUID generator (uuidgen may be absent in slim Linux containers)
gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    python3 -c "import uuid; print(uuid.uuid4())"
  fi
}

# ---------------------------------------------------------------------------
# 1) Claim a Guerrilla Mail address on a persistent session
# ---------------------------------------------------------------------------
# Random first / last name from small pools
FIRST_NAMES=(James John Robert Michael William David Richard Joseph Thomas Charles Daniel Matthew Anthony Mark Steven Andrew Kevin Brian George Edward Harry Oliver Jack Henry Leo Alex Ryan Ethan Noah Lucas)
LAST_NAMES=(Smith Johnson Williams Brown Jones Garcia Miller Davis Wilson Anderson Taylor Thomas Moore Martin Jackson Lee Walker Hall Allen Young King Wright Scott Green Baker Adams Nelson Carter Mitchell Verma)

FIRST_NAME=${FIRST_NAMES[$((RANDOM % ${#FIRST_NAMES[@]}))]}
LAST_NAME=${LAST_NAMES[$((RANDOM % ${#LAST_NAMES[@]}))]}

RAND=$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')
# email local part derived from the random name for readability
LOCAL="$(echo "${FIRST_NAME}${LAST_NAME}" | tr '[:upper:]' '[:lower:]')${RAND}"

log "==> [1] Claiming Guerrilla Mail address"
# Use whatever address Guerrilla returns (it may hand back a rotated domain);
# that is the address whose inbox we will actually poll.
EMAIL=$(curl -s -c "$JAR" -b "$JAR" -A "$UA" \
  "${GM_API}?f=set_email_user&email_user=${LOCAL}&lang=en&site=sharklasers.com" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('email_addr',''))")

# Randomize phone (API enforces unique phone numbers).
# Indian mobile: +91 then 10 digits, first digit 7/8/9.
LEAD=$(( RANDOM % 3 + 7 ))                       # 7, 8, or 9
REST=$(printf '%09d' $(( RANDOM * RANDOM % 1000000000 )))
PHONE="+91${LEAD}${REST}"

echo "    Using name:  $FIRST_NAME $LAST_NAME"
echo "    Using email: $EMAIL"
echo "    Using phone: $PHONE"

# ---------------------------------------------------------------------------
# 2) Register on FundedFirm
# ---------------------------------------------------------------------------
log "==> [2] Registering on FundedFirm"
REG=$(curl -s "$FF_API" \
  -H 'accept: application/json, text/plain, */*' \
  -H 'origin: https://my.fundedfirm.com' \
  -H "user-agent: $UA" \
  -F "first_name=$FIRST_NAME" \
  -F "last_name=$LAST_NAME" \
  -F "email=$EMAIL" \
  -F "phone=$PHONE" \
  -F "password=$PASSWORD" \
  -F "confirm_password=$PASSWORD" \
  -F 'ref=null' \
  -F "device_id=$(gen_uuid)" \
  -F 'timezone=Asia/Calcutta' \
  -F 'platform=web' \
  -F "session_id=$(gen_uuid)" \
  -F 'landing_page=https://my.fundedfirm.com/')
echo "$REG" | python3 -m json.tool 2>/dev/null || echo "$REG"

# ---------------------------------------------------------------------------
# 3) Poll the inbox for the verification email
# ---------------------------------------------------------------------------
log "==> [3] Waiting for verification email..."
MAIL_ID=""
for i in $(seq 1 30); do
  LIST=$(curl -s -c "$JAR" -b "$JAR" -A "$UA" "${GM_API}?f=get_email_list&offset=0")
  MAIL_ID=$(echo "$LIST" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get('list',[]):
    blob=(str(m.get('mail_from',''))+str(m.get('mail_subject',''))).lower()
    if 'fundedfirm' in blob or 'verif' in blob:
        print(m['mail_id']); break
")
  if [ -n "$MAIL_ID" ]; then
    echo "    Got email id: $MAIL_ID"
    break
  fi
  echo "    ...still waiting ($i/30)"
  sleep 3
done

if [ -z "$MAIL_ID" ]; then
  echo "!! No verification email arrived in time."
  exit 1
fi

# ---------------------------------------------------------------------------
# 4) Fetch the email body and extract the verify link
# ---------------------------------------------------------------------------
log "==> [4] Fetching email body and extracting verify link"
BODY=$(curl -s -c "$JAR" -b "$JAR" -A "$UA" "${GM_API}?f=fetch_email&email_id=${MAIL_ID}")

# Extract the verification token from the link in the email.
# The email link is a front-end route: https://my.fundedfirm.com/email/verify/<token>
# The SPA turns that into an API call: GET .../api/confirmRegistration/<token>
TOKEN_HEX=$(echo "$BODY" | python3 -c "
import sys,json,re,html
d=json.load(sys.stdin)
body=html.unescape(d.get('mail_body',''))
urls=re.findall(r'href=[\"\x27]([^\"\x27]+)[\"\x27]', body)
urls+=re.findall(r'https?://[^\s\"\x27<>]+', body)
tok=''
for u in urls:
    m=re.search(r'/email/verify/([A-Za-z0-9]+)', u)
    if m:
        tok=m.group(1); break
print(tok)
")

if [ -z "$TOKEN_HEX" ]; then
  echo "!! Could not find a verify link/token. Full email body follows:"
  echo "$BODY" | python3 -c "import sys,json,html; print(html.unescape(json.load(sys.stdin).get('mail_body','')))"
  exit 1
fi
echo "    Verify token: $TOKEN_HEX"
echo "    Front-end link: https://my.fundedfirm.com/email/verify/$TOKEN_HEX"

# ---------------------------------------------------------------------------
# 5) Call the real verification endpoint (what clicking the link triggers)
# ---------------------------------------------------------------------------
log "==> [5] Verifying account via confirmRegistration API"
VERIFY_RESP=$(curl -s "https://api.fundedfirm.com/api/confirmRegistration/${TOKEN_HEX}" \
  -H 'accept: application/json, text/plain, */*' \
  -H 'origin: https://my.fundedfirm.com' \
  -H "user-agent: $UA")
echo "--- verification response ---"
echo "$VERIFY_RESP" | python3 -m json.tool 2>/dev/null || echo "$VERIFY_RESP"

VERIFIED=$(echo "$VERIFY_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('verified'))" 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# 6) Persist the account so it can be logged into later
# ---------------------------------------------------------------------------
log "==> [6] Saving account to $ACCOUNTS_FILE"

# Pull the long-lived auth token returned by verification (24h JWT)
AUTH_TOKEN=$(echo "$VERIFY_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('token',''))" 2>/dev/null || echo "")
ACCOUNT_ID=$(echo "$REG" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('id',''))" 2>/dev/null || echo "")
CREATED_AT=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

# Add a header once, if the file doesn't exist yet
if [ ! -f "$ACCOUNTS_FILE" ]; then
  printf '# FundedFirm accounts (created by register_verify.sh)\n' > "$ACCOUNTS_FILE"
  printf '# created_at | name | email | password | phone | verified | id | auth_token\n' >> "$ACCOUNTS_FILE"
fi

# Append one pipe-delimited record per account
printf '%s | %s %s | %s | %s | %s | %s | %s | %s\n' \
  "$CREATED_AT" "$FIRST_NAME" "$LAST_NAME" "$EMAIL" "$PASSWORD" "$PHONE" "$VERIFIED" "$ACCOUNT_ID" "$AUTH_TOKEN" \
  >> "$ACCOUNTS_FILE"

echo "    Saved:"
echo "      name:     $FIRST_NAME $LAST_NAME"
echo "      email:    $EMAIL"
echo "      password: $PASSWORD"
echo "      phone:    $PHONE"
echo "      verified: $VERIFIED"

# ---------------------------------------------------------------------------
# 7) Optionally commit accounts.txt back to GitHub (free persistence).
#    Enabled when GIT_PUSH=1 and a repo checkout exists at REPO_DIR.
#    Auth uses GITHUB_TOKEN (set in the Render dashboard, never in code).
# ---------------------------------------------------------------------------
if [ "${GIT_PUSH:-0}" = "1" ]; then
  log "==> [7] Committing accounts.txt to GitHub"
  REPO_DIR="${REPO_DIR:-$(dirname "$0")}"
  (
    cd "$REPO_DIR" || exit 0
    # Configure identity (idempotent)
    git config user.email "${GIT_AUTHOR_EMAIL:-bot@fundedfirm.local}" 2>/dev/null || true
    git config user.name  "${GIT_AUTHOR_NAME:-fundedfirm-bot}" 2>/dev/null || true

    git add "$ACCOUNTS_FILE" 2>/dev/null || true
    if git diff --cached --quiet 2>/dev/null; then
      echo "    nothing to commit"
      exit 0
    fi
    git commit -q -m "account: $EMAIL ($CREATED_AT)" || { echo "    commit failed"; exit 0; }

    # Push using token auth if provided; retry once after a rebase on conflict
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GIT_REPO_SLUG:-}" ]; then
      REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/${GIT_REPO_SLUG}.git"
      if ! git push -q "$REMOTE" HEAD:"${GIT_BRANCH:-main}" 2>/dev/null; then
        git pull -q --rebase "$REMOTE" "${GIT_BRANCH:-main}" 2>/dev/null || true
        git push -q "$REMOTE" HEAD:"${GIT_BRANCH:-main}" 2>/dev/null \
          && echo "    pushed (after rebase)" || echo "    push failed"
      else
        echo "    pushed"
      fi
    else
      # No token: push to whatever origin is configured (local dev)
      git push -q origin HEAD:"${GIT_BRANCH:-main}" 2>/dev/null \
        && echo "    pushed via origin" || echo "    (no GITHUB_TOKEN; committed locally only)"
    fi
  )
fi

echo
log "==> Done. Account email: $EMAIL  (verified=$VERIFIED)"
