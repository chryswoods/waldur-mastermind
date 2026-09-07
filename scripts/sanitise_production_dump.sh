#!/bin/bash
# Turn a production Waldur dump into test data that can be loaded locally.
#
#   scripts/sanitise_production_dump.sh production.sql.gz sanitised.sql.gz
#
# It restores the production dump into a throwaway database, rewrites it, checks
# the result, and only then writes the output dump. If any check fails it stops
# and writes nothing.
#
# WHY NOT MERGE TWO DUMPS
#
# The obvious shape for this is "splice the local dump's settings into the
# production dump", but that means editing COPY blocks as text, keeping foreign
# keys in order and fixing up sequences, and a single missed row leaks the thing
# the exercise was meant to remove. Restoring into a scratch database and
# rewriting it with SQL gets the database itself to enforce consistency, and the
# result can be verified before anyone sees it.
#
# NOTHING FROM THE LOCAL DUMP IS NEEDED
#
# The deployment-specific settings you were worried about are not merged in from
# the local dump - they are removed, and a local instance then falls back to its
# own configuration:
#
#   * Constance settings (HOMEPORT_URL, the helpdesk URLs and tokens, the SCIM
#     and ORCID credentials) live in constance_constance. Deleting a row makes
#     Constance use the default from the local CONSTANCE_CONFIG, so removing
#     them is the same as adopting the local values, without having to graft
#     rows between two databases.
#   * The identity providers, including the keycloak client secret and every
#     realm endpoint, are deleted. Configure the local instance's own.
#   * Mail relay credentials are NOT in the database at all. Waldur reads
#     EMAIL_HOST, EMAIL_HOST_USER and EMAIL_HOST_PASSWORD from settings and the
#     environment (see src/waldur_core/core/email_diagnostics.py), so a dump
#     never carried them.
#
# You will have no way to log in to the result, because every password is
# replaced with an unusable hash and every identity provider is gone. Create an
# account after loading it:
#
#   docker compose exec waldur-mastermind-api \
#       waldur createsuperuser --username admin --email admin@example.com
#
# REQUIREMENTS
#
#   psql, pg_dump and a PostgreSQL server you can create databases on. The
#   scratch database is created and dropped by this script.
#
# ENVIRONMENT
#
#   PGHOST, PGPORT, PGUSER, PGPASSWORD  as for any libpq client
#   SANITISE_DB      name of the scratch database (default waldur_sanitise)
#   KEEP_SCRATCH=1   leave the scratch database behind for inspection
#   SKIP_RESTORE=1   the scratch database is already populated; just sanitise
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'
    exit "${1:-1}"
}

case "${1:-}" in
    -h|--help|"") usage 0 ;;
esac

INPUT="$1"
OUTPUT="${2:-}"
if [ -z "$OUTPUT" ]; then
    echo "ERROR: give an output path for the sanitised dump." >&2
    usage
fi

if [ ! -r "$INPUT" ]; then
    echo "ERROR: cannot read input dump $INPUT" >&2
    exit 1
fi
if [ -e "$OUTPUT" ]; then
    echo "ERROR: $OUTPUT already exists; refusing to overwrite." >&2
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SANITISE_DB="${SANITISE_DB:-waldur_sanitise}"

# The scratch database name has to contain "sanitise": the SQL script refuses to
# run anywhere else unless explicitly overridden, which is what stops this being
# pointed at a live database by mistake.
case "$SANITISE_DB" in
    *sanitise*) ;;
    *) echo "ERROR: SANITISE_DB must contain 'sanitise'." >&2; exit 1 ;;
esac

say() { printf '\n==> %s\n' "$*"; }

decompress() {
    case "$1" in
        *.gz)  gzip -dc  -- "$1" ;;
        *.bz2) bzip2 -dc -- "$1" ;;
        *.xz)  xz -dc    -- "$1" ;;
        *.zst) zstd -dc  -- "$1" ;;
        *)     cat       -- "$1" ;;
    esac
}

cleanup() {
    local rc=$?
    if [ "${KEEP_SCRATCH:-0}" = "1" ]; then
        echo "Scratch database $SANITISE_DB left in place (KEEP_SCRATCH=1)."
    elif [ "$rc" -ne 0 ]; then
        echo "Failed; scratch database $SANITISE_DB left in place so you can" \
             "look at it. Drop it with: dropdb $SANITISE_DB" >&2
    else
        psql -q -d postgres -c "DROP DATABASE IF EXISTS \"$SANITISE_DB\"" \
            >/dev/null
    fi
}
trap cleanup EXIT

if [ "${SKIP_RESTORE:-0}" != "1" ]; then
    say "Creating scratch database $SANITISE_DB"
    psql -q -d postgres -c "DROP DATABASE IF EXISTS \"$SANITISE_DB\""
    psql -q -d postgres -c "CREATE DATABASE \"$SANITISE_DB\""

    say "Restoring $INPUT"
    # A pg_dumpall cluster dump carries CREATE DATABASE and \connect, so it has
    # to be restored at the cluster level rather than into one database. A
    # per-database pg_dump restores straight into the scratch database.
    if decompress "$INPUT" | head -200 | grep -q '^CREATE DATABASE'; then
        echo "ERROR: $INPUT looks like a pg_dumpall cluster dump." >&2
        echo "       Take a single-database dump instead:" >&2
        echo "         pg_dump -d waldur -Fp | gzip > production.sql.gz" >&2
        echo "       or restore the cluster dump yourself and re-run with" >&2
        echo "       SKIP_RESTORE=1 SANITISE_DB=<the restored database>." >&2
        exit 1
    fi
    # ON_ERROR_STOP is deliberately off: a dump taken as a non-superuser
    # normally fails on extension and ownership statements that do not matter
    # here. Missing tables would be caught by the sanitiser and the verifier.
    decompress "$INPUT" | psql -q -d "$SANITISE_DB" >/dev/null
fi

say "Sanitising"
psql -v ON_ERROR_STOP=1 -d "$SANITISE_DB" \
     -c "ALTER DATABASE \"$SANITISE_DB\" SET waldur.sanitise_confirmed = 'yes'"
PGOPTIONS="-c waldur.sanitise_confirmed=yes" \
    psql -v ON_ERROR_STOP=1 -d "$SANITISE_DB" \
         -f "$HERE/sanitise_production_dump.sql"

say "Verifying"
VERIFY_OUT="$(mktemp)"
psql -v ON_ERROR_STOP=1 -d "$SANITISE_DB" \
     -f "$HERE/sanitise_verify.sql" | tee "$VERIFY_OUT"

# Match the status cell of a result row, not the word FAIL in the closing
# explanation the verifier prints.
if grep -qE '\| *FAIL *\|' "$VERIFY_OUT"; then
    echo >&2
    echo "ERROR: verification reported FAIL. No dump written." >&2
    echo "       The scratch database is kept so you can investigate." >&2
    KEEP_SCRATCH=1
    rm -f "$VERIFY_OUT"
    exit 1
fi
rm -f "$VERIFY_OUT"

say "Writing $OUTPUT"
# --no-owner and --no-privileges so the result loads as whatever role the local
# deployment uses, rather than needing production's roles to exist.
case "$OUTPUT" in
    *.gz) pg_dump --no-owner --no-privileges -d "$SANITISE_DB" | gzip > "$OUTPUT" ;;
    *)    pg_dump --no-owner --no-privileges -d "$SANITISE_DB" > "$OUTPUT" ;;
esac

# A last belt-and-braces pass over the bytes that are actually leaving. The SQL
# checks assert on shape per column; this catches an address or a URL in a
# column nobody thought to check.
say "Scanning the output for anything that looks like a live address or URL"
leaks=0
scan() {
    local label="$1" pattern="$2" allow="${3:-}"
    local n
    if [ -n "$allow" ]; then
        n="$(decompress "$OUTPUT" | grep -Eo "$pattern" | grep -Evc "$allow" \
             || true)"
    else
        n="$(decompress "$OUTPUT" | grep -Eoc "$pattern" || true)"
    fi
    if [ "${n:-0}" -gt 0 ]; then
        printf '  LEAK  %-24s %s occurrences\n' "$label" "$n"
        leaks=$((leaks + 1))
    else
        printf '  ok    %-24s\n' "$label"
    fi
}
scan "email addresses" \
     '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
     '^person[0-9]+@example_org[0-9]+\.com$|^admin@example\.com$'
scan "http(s) URLs" \
     'https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+' \
     'localhost|127\.0\.0\.1|example\.(com|org|net)|www\.w3\.org|schemas\.|creativecommons\.org|docs\.waldur\.com|waldur\.com|github\.com|opensource\.org|json-schema\.org'

if [ "$leaks" -gt 0 ]; then
    echo >&2
    echo "ERROR: the output dump still contains addresses or URLs that are" >&2
    echo "       not on the allowlist. It has been left in place so you can" >&2
    echo "       look at what matched:" >&2
    echo >&2
    echo "         zgrep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'" \
         "$OUTPUT | sort -u | head" >&2
    echo >&2
    echo "       Either add the column to the sanitiser or add the host to the" >&2
    echo "       allowlist in this script, then re-run from the original dump." >&2
    KEEP_SCRATCH=1
    exit 1
fi

say "Done: $OUTPUT"
cat <<'EOT'

Load it into a local deployment with the containers down apart from the
database, since Waldur migrates at startup:

  docker compose up -d waldur-db
  docker compose exec -T waldur-db psql -U waldur -d postgres \
      -c 'DROP DATABASE waldur' -c 'CREATE DATABASE waldur OWNER waldur'
  gzip -dc sanitised.sql.gz | docker compose exec -T waldur-db \
      psql -U waldur -d waldur

Then run the resync reconciliation and let the rest of the stack start, which
is the migration rehearsal this data is for:

  docker compose exec -T waldur-db psql -U waldur -d waldur \
      < scripts/resync_preflight_check.sql
  docker compose exec -T waldur-db psql -U waldur -d waldur \
      < scripts/resync_reconcile_db.sql
  docker compose up -d

Finally, make an account, since no password in the copy is usable:

  docker compose exec waldur-mastermind-api \
      waldur createsuperuser --username admin --email admin@example.com
EOT
