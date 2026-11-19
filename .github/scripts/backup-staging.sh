# Helpers for backup.yml's staging target: the private bucket prod-backups on the staging project
# (migration 80). Sourced by a step running with set -euo pipefail. Needs STAGING_TOKEN (the
# staging access token), STAGING_PROJECT_REF and BACKUP_BUCKET. Prints HTTP codes and object
# names only (names are stamps and part numbers); the service key is masked and never printed.

# Reads the staging service key through the Management API (API Key Secrets Read, the scope
# `supabase link` already needs) into SKEY, and sets SURL. A legacy service_role key is preferred;
# otherwise a secret key (sb_secret_...), sent in the apikey header only.
staging_key() {
  [ -n "${STAGING_TOKEN:-}" ] || { echo "::error::no staging access token"; return 1; }
  local f="$RUNNER_TEMP/staging-key" code
  code=$(curl -sS -o "$f" -w '%{http_code}' --max-time 30 -H "Authorization: Bearer $STAGING_TOKEN" \
    "https://api.supabase.com/v1/projects/$STAGING_PROJECT_REF/api-keys?reveal=true" || echo "000")
  if [ "$code" != 200 ]; then rm -f "$f"; echo "::error::reading the staging keys answered HTTP $code"; return 1; fi
  SKEY=$(jq -r '[.[] | select(.name == "service_role" and (.api_key // "") != "")][0].api_key // empty' "$f")
  SKEY_KIND=jwt
  if [ -z "$SKEY" ]; then
    SKEY=$(jq -r '[.[] | select(.type == "secret" and (.api_key // "") != "")][0].api_key // empty' "$f")
    SKEY_KIND=secret
  fi
  rm -f "$f"
  [ -n "$SKEY" ] || { echo "::error::no staging service key could be read (the token needs API Key Secrets Read)"; return 1; }
  echo "::add-mask::$SKEY"
  SURL="https://$STAGING_PROJECT_REF.supabase.co"
}

# The auth headers for Storage, as curl arguments.
_auth() {
  if [ "$SKEY_KIND" = jwt ]; then
    printf '%s\n' -H "apikey: $SKEY" -H "Authorization: Bearer $SKEY"
  else
    printf '%s\n' -H "apikey: $SKEY"
  fi
}

# put <object path> <local file> <content type>: uploads one object (no overwrite).
put() {
  local code
  mapfile -t auth < <(_auth)
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 600 --retry 2 -X POST "${auth[@]}" \
    -H "Content-Type: $3" -H "x-upsert: false" --data-binary @"$2" \
    "$SURL/storage/v1/object/$BACKUP_BUCKET/$1" || echo "000")
  [ "$code" = 200 ] || { echo "::error::upload of $1 answered HTTP $code"; return 1; }
}

# list_names <prefix ending in / or empty>: the names directly under it, one per line.
list_names() {
  local f="$RUNNER_TEMP/list.json" code
  mapfile -t auth < <(_auth)
  code=$(curl -sS -o "$f" -w '%{http_code}' --max-time 60 -X POST "${auth[@]}" -H "Content-Type: application/json" \
    --data "$(jq -nc --arg p "$1" '{prefix: $p, limit: 1000, offset: 0, sortBy: {column: "name", order: "asc"}}')" \
    "$SURL/storage/v1/object/list/$BACKUP_BUCKET" || echo "000")
  if [ "$code" != 200 ]; then rm -f "$f"; echo "::error::listing $BACKUP_BUCKET/$1 answered HTTP $code" >&2; return 1; fi
  jq -r '.[].name' "$f"
  rm -f "$f"
}

# remove_paths <object path>...: deletes those objects.
remove_paths() {
  local code
  mapfile -t auth < <(_auth)
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X DELETE "${auth[@]}" -H "Content-Type: application/json" \
    --data "$(jq -nc '{prefixes: $ARGS.positional}' --args "$@")" \
    "$SURL/storage/v1/object/$BACKUP_BUCKET" || echo "000")
  [ "$code" = 200 ] || { echo "::error::delete answered HTTP $code"; return 1; }
}
