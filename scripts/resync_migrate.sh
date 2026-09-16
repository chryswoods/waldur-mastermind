#!/bin/bash
# Apply the upstream-resync migration, in the one order that works.
#
# Run this AFTER scripts/resync_reconcile_db.sql, instead of a plain `migrate`.
#
#   scripts/resync_migrate.sh --manage \
#       'docker compose run --rm --no-deps -T --entrypoint waldur waldur-mastermind-api'
#
#   scripts/resync_migrate.sh --manage 'uv run python -m waldur_core.server.manage'
#
# RUN THIS WITH THE APPLICATION DOWN, DATABASE ONLY
#
# `run --rm`, not `exec`: exec needs a container already running, and a running
# API container is precisely what you do not want. Waldur migrates at startup,
# so an API container that is up has already migrated - or tried to and failed -
# and this script would be racing it. The workers and beat are worse: they would
# be reading and writing a schema that is changing underneath them.
#
# --no-deps stops `docker compose run` starting the queue, worker and beat as
# linked services. Bring up waldur-db on its own, run the reconciliation, run
# this, then `docker compose up -d`. By then every migration is applied and the
# API's own startup migrate is a no-op.
#
# WHY NOT JUST `migrate`
#
# Five upstream waldur_openportal migrations (0035-0039) create objects this
# fork's own 0034-0043 already created, so they have to be recorded as applied
# without running. The obvious way to do that - INSERT the rows into
# django_migrations alongside the rest of the reconciliation - is wrong:
#
#   upstream 0036_remote_projects depends on
#   structure.0078_alter_servicesettings_certificate
#
# which production has not applied. Django checks that every applied migration
# has its dependencies applied, before doing anything at all, so inserting
# those rows makes EVERY migrate invocation fail - including migrate --plan:
#
#   InconsistentMigrationHistory: Migration waldur_openportal.0036_remote_projects
#   is applied before its dependency structure.0078_alter_servicesettings_certificate
#
# Only Django knows the dependency graph, so only Django can fake a migration
# at a point where the graph is satisfied. Hence this script rather than more
# SQL.
#
# THE ORDER
#
#   1. migrate structure          forward, no target. This brings in
#                                 0078_alter_servicesettings_certificate, which
#                                 openportal 0036 depends on. That migration is
#                                 an AlterField adding validators to a
#                                 FileField, so it is DDL-free - but Django
#                                 still requires it recorded before anything
#                                 that depends on it.
#   2. migrate waldur_openportal 0034
#                                 for real: it adds can_be_managed to allocation
#                                 and remoteallocation, columns this fork never
#                                 had, because upstream's models gain them from
#                                 core_models.AvailableMixin. Faking it would
#                                 leave the columns missing and the schema
#                                 quietly wrong.
#   3. migrate waldur_openportal 0039 --fake
#                                 records 0035-0039 without running them.
#   4. migrate                    everything else, including upstream's
#                                 proposal 0047-0077 against empty tables.
#   5. grace period backfill      structure/0067 added Customer.grace_period_days
#                                 and Project.grace_period_days as nullable
#                                 columns with no default, replacing a property
#                                 that returned a fixed 30 days. Every existing
#                                 row is therefore NULL, which means zero, and
#                                 everything sitting in its grace period expires
#                                 the moment this deployment lands. Backfilled
#                                 here rather than in a migration under
#                                 waldur_core/structure: that directory is
#                                 upstream's, and a local migration in it is one
#                                 stray merge request away from being pushed
#                                 back. scripts/ is unambiguously ours.
#   6. makemigrations --check     proves the result matches the models, which
#                                 is what catches a fake whose objects did not
#                                 actually match.
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'
    exit "${1:-1}"
}

MANAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --manage) MANAGE="${2:-}"; shift 2 ;;
        *) echo "ERROR: unexpected argument $1" >&2; usage ;;
    esac
done

if [ -z "$MANAGE" ]; then
    MANAGE="${WALDUR_MANAGE:-}"
fi
if [ -z "$MANAGE" ]; then
    echo "ERROR: give --manage with whatever runs Waldur's manage command," >&2
    echo "       e.g. --manage 'docker compose exec -T waldur-mastermind-api waldur'" >&2
    exit 1
fi

START_EPOCH=$(date +%s)
say() {
    local secs=$(( $(date +%s) - START_EPOCH ))
    printf '\n==> [%s | +%dm%02ds] %s\n' "$(date +%H:%M:%S)" \
        $((secs / 60)) $((secs % 60)) "$*"
}

# `migrate app NNNN` migrates TO that migration - which on a database already
# past it means UNAPPLYING everything after it. On a production database
# behind 0078 that is what we want; on one already ahead it would start
# reversing real migrations and removing fields. So every step checks first,
# which also makes the script safe to re-run after a failure part-way through.
is_applied() {
    $MANAGE showmigrations "$1" 2>/dev/null | grep -qE "^ *\[X\] $2"
}

run() {
    echo "    \$ $MANAGE $*"
    # Timestamped, so subtracting gives the per-migration cost that a
    # deployment window is built from. Django does not report it.
    $MANAGE "$@" 2>&1 | while IFS= read -r line; do
        printf '    %s %s\n' "$(date +%H:%M:%S)" "$line"
    done
    return "${PIPESTATUS[0]}"
}

say "1/6  structure forward (brings in openportal 0036's dependency)"
# `migrate structure` with no target, deliberately. Naming 0078 would be
# precise but breaks two ways: on a database already past it, migrating TO a
# migration means UNAPPLYING everything after it - Django starts reversing real
# migrations and removing fields - and structure is squashed
# (0041_squashed_0085 replaces 0042-0085, 0078 among them), so the name may not
# even be a node Django will accept as a target. Migrating the app forward is
# idempotent, never unapplies, and needs no knowledge of the squash.
run migrate structure

say "2/6  openportal 0034 for real (adds can_be_managed)"
if is_applied waldur_openportal 0034_allocation_can_be_managed; then
    echo "    already applied, skipping"
else
    run migrate waldur_openportal 0034
fi

say "3/6  openportal 0035-0039 faked (their objects already exist)"
if is_applied waldur_openportal 0039_alter_remoteprojectattachment_options; then
    echo "    already recorded, skipping"
else
    run migrate waldur_openportal 0039 --fake
fi

say "4/6  everything else"
run migrate --noinput

say "5/6  restore the 30-day grace period"
# scripts/set_default_grace_period.py reads GRACE_APPLY from the environment,
# and $MANAGE may well be a `docker compose run` that passes none through, so
# the variable is set in the payload itself rather than around the command.
# Only NULL rows are touched, so this is idempotent and safe to re-run.
GRACE_SCRIPT="$(dirname "$0")/set_default_grace_period.py"
if [ ! -f "$GRACE_SCRIPT" ]; then
    echo "ERROR: cannot find $GRACE_SCRIPT" >&2
    exit 1
fi
run shell -c "import os; os.environ['GRACE_APPLY'] = '1'
$(cat "$GRACE_SCRIPT")"

say "6/6  does the schema match the models?"
if run makemigrations --check --dry-run; then
    say "Done. No changes detected: the schema matches the models."
else
    echo >&2
    echo "ERROR: makemigrations wants to create a migration, so the schema" >&2
    echo "       does not match the models. Something that was faked did not" >&2
    echo "       in fact already exist in the shape upstream expects. Do not" >&2
    echo "       deploy on this result; send the diff for a look." >&2
    exit 1
fi
