# Sanitising a production dump for local testing

A production database makes far better test data than anything generated: real
row counts, real distributions, real awkward records. Two things stop you
loading one into a local deployment.

1. **It is that deployment.** Constance keeps the portal's settings in the
   database, so a restored dump points your local instance at the production
   homeport, the production helpdesk, and the production identity provider,
   with the client secrets to reach them.
2. **It is personal data.** Names, addresses, national identity numbers, dates
   of birth, phone numbers, identity-provider claim sets, and the whole audit
   trail of who did what.

`scripts/sanitise_production_dump.sh` produces a dump with neither.

## Running it

```bash
# On a machine that can reach a PostgreSQL server. The scratch database is
# created and dropped for you.
scripts/sanitise_production_dump.sh production.sql.gz sanitised.sql.gz
```

Take the input with `pg_dump`, not `pg_dumpall` -- a cluster dump carries
`CREATE DATABASE` and cannot be restored into one database:

```bash
pg_dump -d waldur -Fp | gzip > production.sql.gz
```

The script restores the dump into a scratch database, rewrites it, verifies the
result, and only writes the output dump if every check passes. On failure it
leaves the scratch database behind so you can look at it.

Loading the result is the same rehearsal the resync plan describes -- bring up
only the database, load, reconcile, then start the rest:

```bash
docker compose up -d waldur-db
docker compose exec -T waldur-db psql -U waldur -d postgres \
    -c 'DROP DATABASE waldur' -c 'CREATE DATABASE waldur OWNER waldur'
gzip -dc sanitised.sql.gz | docker compose exec -T waldur-db psql -U waldur -d waldur
docker compose exec -T waldur-db psql -U waldur -d waldur < scripts/resync_reconcile_db.sql
docker compose up -d
```

No password in the copy is usable and there is no identity provider, so make an
account:

```bash
docker compose exec waldur-mastermind-api \
    waldur createsuperuser --username admin --email admin@example.com
```

## What the pseudonyms look like

Every individual becomes `Person NumberN`, addressed as
`personN@example_orgM.com`, where `N` counts individuals and `M` counts
distinct email domains -- so two people at the same institution share a
domain:

| before | after |
| --- | --- |
| `Ada Lovelace <ada@some.ac.uk>` | `Person Number1 <person1@example_org1.com>` |
| `Alan Turing <alan@other.ac.uk>` | `Person Number2 <person2@example_org2.com>` |
| `Grace Hopper <grace@some.ac.uk>` | `Person Number3 <person3@example_org1.com>` |

`N` follows `core_user.id`, so `Person Number1` is the oldest account and the
numbering is the same every time you run the script against the same dump.
People who never became users -- an invitation nobody accepted, a service
account's contact address -- are numbered after the registered ones.

The mapping is consistent across the whole database. One person keeps one
identity in `core_user`, in their OpenPortal shortname, in their SLURM and
FreeIPA and per-offering account names, in the invitation that created them,
and in the rendered text of their event log. **Accounting that joins users to
allocations by account name still joins**, which is the point: the data has to
stay usable.

Compound account names keep their non-personal parts, because everything
downstream is keyed on them:

```text
jsmith                             ->  person12
jsmith.someproject                 ->  person12.someproject
jsmith.someproject.somecluster     ->  person12.someproject.somecluster
```

## What is removed rather than rewritten

Some things have no pseudonym worth having.

- **Prose.** Support tickets, comments, broadcast messages, staff notes and
  audit notes are replaced with filler of the same length. Substituting the
  names we know about would leave everything else the writer typed, so the
  text goes and the shape stays: a description that filled a panel still
  fills it.
- **Deployment settings.** `constance_constance` is reduced to a named
  allowlist of keys that only affect how data is presented. A deleted key
  falls back to the default in the local `CONSTANCE_CONFIG`, which is the same
  as adopting the local value -- there is nothing to merge in from a local
  dump.
- **Identity providers**, including the keycloak client secret and every realm
  endpoint.
- **Credentials and telemetry**: sessions, API tokens, personal access tokens,
  passkeys, OAuth tokens, service-settings passwords and backend URLs, login
  attempt logs.
- **`django-reversion` history**, which is a serialised snapshot of every
  earlier version of every object -- a complete second copy of the
  pre-sanitisation data with no way to rewrite it reliably.
- **File contents** stored in `media_file`. The rows stay so references
  resolve; the bytes could be anything a user uploaded.
- **URLs**, rewritten to `https://example.com/redacted` unless the host is
  localhost, an `example.*` domain, or a well-known public one.

Mail relay credentials were never in the database: Waldur reads `EMAIL_HOST`,
`EMAIL_HOST_USER` and `EMAIL_HOST_PASSWORD` from settings and the environment
(see `src/waldur_core/core/email_diagnostics.py`).

## What is *not* removed, deliberately

- **Organisation and project names**, and their slugs. They are what makes the
  copy recognisable enough to debug against. A project named after its
  principal investigator would carry that name through; if that matters for
  your data, extend the sanitiser.
- **Cluster and system identifiers** such as an OpenPortal `destination`.
  Deployment-specific, but not a secret, and the accounting views are hard to
  read without them.
- **Everything structural**: dates, costs, usage, quotas, states, row counts,
  and `django_migrations`. The migration history is left strictly alone --
  rehearsing the migration is what this data is for.

## Why not merge two dumps

The obvious approach is to splice the local dump's settings into the production
dump. That means editing `COPY` blocks as text, keeping foreign keys in order
and fixing up sequences, and one missed row leaks exactly the thing the
exercise was meant to remove. Restoring into a scratch database and rewriting
it with SQL lets the database enforce consistency, and lets the result be
checked before anyone sees it.

## How it avoids missing a column

Naming the columns that hold personal data does not work: the leaks are not in
the columns anyone would name. In this codebase they were in

- OpenPortal's project payloads, which keep membership as a JSON object whose
  **keys** are addresses -- a walk that rewrites JSON values leaves every one
  of them;
- a job queue whose payload is a JSON document embedded in a command string,
  so the addresses and note authors inside it are two levels down;
- `core_user.query_field`, a denormalised search string, and
  `core_user.details`, the raw claim set from the identity provider;
- a database cache table keyed on `LOGIN_FAILURES_OF_<address>`.

So the script works by shape, in three layers:

1. **Named columns**, for the fields that hold a person's details directly.
2. **A sweep**, over every JSON column and every text column in the database,
   whatever app declared it. The JSON walk recurses through objects, arrays,
   keys, and documents nested inside strings, mapping a leaf when the whole
   leaf is recognisable. This is the slowest step; on a large installation
   expect it to dominate the run.
3. **Two independent checks.** `scripts/sanitise_verify.sql` asserts that
   every remaining address matches `personN@example_orgM.com` and every
   remaining name matches `Person NumberN` -- so a column nobody thought about
   fails rather than passing quietly. Then the driver greps the bytes of the
   finished dump for anything address- or URL-shaped that is not on an
   allowlist, and refuses to hand over a dump that still has any.

Every one of the leaks listed above was found by layer 3, not by reading the
schema. If you extend the script, keep that order: add the column, then check
that the scan agrees.

## Rehearsed against

A full run against a real dump: 188 JSON columns walked, 29 identifier columns
mapped, 1,555 text columns swept, both checks clean, and the result loads,
reconciles and migrates to the resynced schema with `makemigrations --check`
reporting no changes. Re-running the sanitiser over its own output changes
nothing, so an interrupted run can simply be repeated.
