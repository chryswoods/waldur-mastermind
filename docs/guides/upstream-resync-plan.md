# Upstream Resync Plan

Resynchronising this fork (`chryswoods/waldur-mastermind`) against
`waldur/waldur-mastermind` `develop`.

## 1. Situation

| Fact | Value |
| --- | --- |
| Fork point | `8da8593be`, 2025-11-02 |
| This fork ahead | 604 commits |
| Upstream ahead | 3358 commits |
| Trial-merge conflicts | 66 files (29 `add/add`, 37 content) |

Upstream absorbed the OpenPortal extension from this fork in three passes:

| Commit | Date | Description |
| --- | --- | --- |
| `ac3a13b6f` | 2026-04-15 | Merge isambard changes into `waldur_openportal` [1/3] |
| `9b68095b7` | 2026-04-20 | Final merge of OpenPortal extension from Isambard fork |
| `912542505` | 2026-08-05 | Port OpenPortal 0.90 features and enhancements from Isambard fork |

`waldur_openportal/models.py` has **identical class sets, identical field
names and identical field definitions** between this fork and upstream, so the
OpenPortal database schema has genuinely converged. Upstream additionally
contributes `config.py`, `exceptions.py` and 13 test modules where this fork
had one.

## 2. Strategy

Reset onto `upstream/develop` and treat upstream as the source of truth.
Re-apply only a small, explicitly enumerated set of local changes on top.

Four categories:

1. **Adopt upstream wholesale** — `waldur_openportal`,
   `marketplace_openportal`, `marketplace_openportal_remote`,
   `waldur_mastermind/proposal`.
2. **Delete permanently** — `unix_username`, `short_name`, all proposal work,
   `BroadcastMessageAttachment`, `waldur_openportal/op.py`.
3. **Carry forward** — local bug fixes, feature flags, and the endpoints that
   waldur-homeport's visualisations depend on.
4. **One-time database reconciliation** — a script, not a merged migration
   history.

## 3. Adopt upstream wholesale

### 3.1 OpenPortal

Take upstream's tree for all three modules, then re-apply the only two local
commits that postdate upstream's 2026-08-05 port:

- `ae6a7628a` — offering filter on the allocation fetch, plus the project
  accounting summary view and serializer fields.
- `54854f7bb` — one-line `tasks.py` bug fix.

These need reshaping onto upstream's refactored code rather than a clean
cherry-pick.

### 3.2 The `openportal` client library

This fork imports a vendored 602-line shim, `waldur_openportal/op.py`, via
`from . import op as openportal` in every module. Upstream deleted the shim
and imports the real package: `import openportal`, pinned `openportal>=0.91.0`
against this fork's `>=0.32.2`.

Adopt upstream's approach and move the pin to `openportal>=0.92.0`. The
deployed OpenPortal *service* must be upgraded in step — this is a
coordinated, cross-repository change and the main scheduling risk in the whole
resync.

### 3.3 Proposal

Upstream's proposal app is a different and far more advanced system
(`views.py` 2,388 → 6,770 lines; `models.py` 1,051 → 3,132; 56 → 83
migrations) with reviewer pools, bids, conflict-of-interest detection, ORCID
integration, affinity matrices, compliance checklists and workflow steps.

Bespoke proposal development lives in a separate fork. Here, upstream's
version is adopted in full and all local proposal work is discarded.

## 4. Delete permanently

### 4.1 `unix_username` and `short_name`

Superseded by shortname handling inside `waldur_openportal` (`UserInfo.shortname`
and `ProjectInfo.shortname`, synced to `User.slug` / `Project.slug`). Remove:

- `core.User.unix_username` — field, `save()` sync logic, `core/admin.py`,
  `permissions/serializers.py` (`user_unix_username`),
  `structure/serializers.py`.
- `structure.Project.short_name` — field, `save()` sync logic,
  `structure/admin.py`, `structure/filters.py` search field,
  `structure/serializers.py`.

Upstream's OpenPortal code guards both with `hasattr`, so removing the columns
makes it fall back to `slug` with no code change on upstream's side. Upstream
files are deliberately left untouched.

No migration is needed for either removal. Adopting upstream's model state and
migration graph wholesale means neither column was ever part of that state, and
`makemigrations --check` confirms nothing is pending. The deployed database
keeps the columns until the reconciliation script drops them.

### 4.2 Proposal

All of `waldur_mastermind/proposal`, plus the local changes that only exist to
serve it:

- `notifications/utils.py` — `get_proposal_team_members`, `get_proposal_reviewers`
- `notifications/serializers.py` — `round`, `proposal_states`, `include_reviewers`
- `structure/notifications.py` — `StaleProposalReminderContext` and related
- `users/filters.py` — Call-invitation manager filtering
- `users/serializers.py` — `PROPOSAL.MANAGER` invitation guard
- `permissions/enums.py` — `MANAGE_PROPOSAL` remapping

### 4.3 `BroadcastMessageAttachment`

The whole `notifications` app is reset to upstream. The local delta there was
the attachment model, serializer and `attach_file` action, `format_attachment_links`
in `tasks.py`, and the proposal-round recipient targeting in `utils.py` and
`serializers.py` — all of it dropped. `format_mastermind_link` in
`core/utils.py` was its only remaining consumer and is removed as dead code.

This also drops three generic broadcast conveniences that came in on the same
serializer and have no upstream equivalent: `send_to_me`,
`additional_recipients` and `excluded_recipients`. Confirmed with the fork
owner that the homeport broadcast composer does not use them, so they are gone
for good rather than pending a decision.

### 4.4 Obsolete Dockerfile hack

`RUN pip install django-cors-headers` is no longer needed: upstream's
`pyproject.toml` now declares `django-cors-headers>=4.5.0,<5.0.0`.

## 5. Carry forward

Local bug fixes and homeport support. None of these are present upstream
unless noted.

### 5.1 Bug fixes

| Location | Change |
| --- | --- |
| `core/utils.py` | Collapse blank lines in rendered email templates; warn instead of failing on an unknown notification key; double-slash hardening in `format_homeport_link`. |
| `billing/serializers.py` | `_original_eager_load` fix so credit and billing eager-load optimisations compose instead of double-applying. |

The local `Token.objects.get_or_create` race fix in `core/authentication.py` is
**not** carried forward: upstream's own fix wraps the rotation in a savepoint
and tolerates a concurrent rotation via `IntegrityError`, covering the call
site the local fix missed.

### 5.2 Homeport support

| Location | Change |
| --- | --- |
| `structure/filters.py` | Project date filters: `start_date_after/before`, `end_date_after/before`, `active_during`, `started`, `ended`, `in_grace`. |
| `structure/serializers.py` | Grace-period-aware project end date (commit `95486ab`). |
| `invoices/views.py` | `ProjectCredit.list` so project members can read their own credits — needed by the homeport accounting widget. |
| `core/features.py` | 8 feature flags, none upstream: `show_openportal_remote_projects`, `enforce_allowed_domains`, `show_openportal_accounting_pages`, `credentials`, `disable_long_tokens`, `show_slug_as_id`, `minimal_user_profile`, `allow_user_creation`. |
| `users/templates` | Invitation email template improvements. |

Two items in this group turned out to be superseded rather than carried:

- **Grace periods.** Upstream implements them per project with a
  customer-level fallback (`Project.grace_period_days`,
  `Customer.grace_period_days`, `get_grace_period_days()`,
  `get_effective_end_date()`, `is_in_grace_period`, `end_date_with_grace`),
  exposes them on the serializer including a staff-only write path, and covers
  them with a `GracePeriodTest` suite. That is strictly better than the local
  hardcoded `PROJECT_GRACE_PERIOD_DAYS = 30`, which is dropped. The two local
  dependents are reworked onto upstream's API: `validate_end_date` reads
  `self.instance.get_grace_period_days()` (a project being created has no
  grace period, so a past end date is rejected as upstream does), and
  `filter_in_grace` resolves each project's own grace period in the database
  via `Coalesce` over the project and customer columns.
- **The project-ending notification and grace-period-aware termination.**
  Upstream reimplemented all of this more thoroughly — deletion moved to a
  Celery task, resources paused while inside the grace period where the
  offering supports it, and a per-offering opt-out — so `marketplace/`
  handlers, tasks, templates and tests are all upstream's.

### 5.3 OpenPortal domain enforcement

Upstream took `assert_email_allowed_for_project` and
`check_managed_project_membership_control` into `waldur_openportal/utils.py`,
but **not the callers**. Upstream only mentions `enforce_allowed_domains` in a
docstring, and never declares the feature flag, so the functionality is
currently unreachable upstream. Carry forward:

- `permissions/views.py` — enforcement on role grant and role change
- `users/views.py` — enforcement on invitation
- `core/features.py` — the `enforce_allowed_domains` flag itself

Good candidate to offer upstream as a follow-up.

### 5.4 Operations

| Location | Change |
| --- | --- |
| `logging/tasks.py` | `purge_old_events` batched cleanup task. |
| `server/celery_settings.py` | `purge-old-events` schedule, every 3 days. |
| `server/admin/menu.py` | `waldur_openportal.*` admin menu entry. |
| `docker/rootfs/etc/nginx/*` | Local nginx configuration. |
| `docker/rootfs/etc/waldur/` | `permissions.yaml`, `notifications.json`. |

### 5.5 Known duplication

Upstream inlined its own `PROJECT_GRACE_PERIOD_DAYS = 30` in
`waldur_openportal/board.py` rather than importing from
`structure/models.py`. Both values agree at 30. Leave upstream's copy alone
and propose the shared import upstream later.

## 6. Database reconciliation

A one-time script, `scripts/resync_reconcile_db.sql`, run against a restored
production dump before going near the live database. This fork is the only
deployment, so recording upstream's migrations as applied plus targeted DDL is
sufficient. The script is one transaction and is safe to re-run.

### 6.1 OpenPortal — almost all bookkeeping

Migration *numbers* collide (local `0034`–`0043` against upstream
`0034`–`0039`), and the two routes reach the same objects with one exception:

1. Delete the `waldur_openportal` rows for local `0034`–`0043` from
   `django_migrations`.
2. Record upstream `0035`–`0039` as already-applied. Upstream `0035` creates
   the two cached report tables and their indexes, which local `0034`–`0036`
   already created; `0036` creates the five remote-project models that local
   `0037`–`0043` created; `0037`–`0039` are `AlterModelOptions` only.
3. Let upstream `0034` **run for real**. It adds `can_be_managed` to
   `allocation` and `remoteallocation`, which upstream's models inherit from
   `core_models.AvailableMixin` — a base class this fork never had, so those
   columns genuinely do not exist here.
4. Verify with `makemigrations --check --dry-run` that no changes are pending.

The `AvailableMixin` case is worth dwelling on, because the original analysis
missed it and only `migrate` on a real database caught it. Comparing the two
trees' `models.py` showed identical class sets and identical field
*definitions*, which was read as "the schema has converged". That comparison
only saw fields **declared in that file**; it was blind to fields arriving
through a base class, and `can_be_managed` is declared on `AvailableMixin` in
`waldur_core`.

Diffing the model **base classes** as well as their declared fields catches
this, and confirms `AvailableMixin` on `Allocation` and `RemoteAllocation` is
the only such difference in the app.

### 6.2 Proposal — clean reset

The portal holds no proposals, so the app is reset rather than migrated:

1. Drop the tables and columns added by local `0047`–`0054`, including
   `ProposalIdGenerator` and `ProposalResourceAdjustment`.
2. Delete the local `0047`–`0054` rows from `django_migrations`.
3. `migrate proposal` to replay upstream `0047`–`0077`.

Verified safe: there are **no column-name collisions** on the same model.
Upstream's `submitted_at` is on `ReviewerBid`, not `Proposal`, and its notes
fields are `internal_notes` / `review_notes` / `manager_notes`, distinct from
the local `Proposal.notes`.

### 6.3 Dropped columns

`core.User.unix_username`, `structure.Project.short_name` and the broadcast
attachment table are dropped by the script rather than by migrations — the
adopted model state never contained them, so there is nothing for Django to
generate. The migration rows that added them, and the merge nodes that
stitched the local branch into upstream's history, are deleted with them.

Confirm OpenPortal shortnames have fully migrated to `UserInfo.shortname` /
`ProjectInfo.shortname` **before** dropping; the script carries the two
verification queries in a comment, and the data is not recoverable afterwards.

### 6.4 Squashes

Upstream added `0001_squashed_0039` (openportal) and `0001_squashed_0074`
(proposal), regenerated as state diffs in `80437de2c`. Harmless for an
existing database, but confirm a fresh `migrate` does not take a different
route than the reconciled one.

## 6.5 Production scale

Measured from the sanitised copy of production (September 2026), so these are
the real numbers the deployment has to get through:

| | rows |
| --- | --- |
| people (`core_user`) | 4,276 |
| organisations | 23 |
| projects | 1,651 |
| resources | 1,956 |
| events (`logging_event`) | 2,851,926 |
| invoices | 473 |

What that means for the migration window:

- **No expensive DDL lands on the big table.** The recent `logging` migrations
  touch `emaillog` and model options, not `event`, so the 2.85 million events
  are not rewritten or reindexed. The index-creating migrations on `event`
  (`0015`, `0018`) long predate this branch and are already applied.
- **The proposal replay is free**, however long the series. Production holds no
  proposals, so upstream's `0047`-`0077` run against empty tables.
- **The two column drops are cheap.** `ALTER TABLE ... DROP COLUMN` in
  PostgreSQL only marks the attribute dropped; it does not rewrite the table.
  1,651 projects and 4,276 users would be quick even if it did.
- **The data migrations that scale with these counts** are
  `core/0041_backfill_user_initial_revisions` (one revision per user, so 4,276)
  and `core/0048_backfill_notificationtemplate_initial_revisions`. Both are
  exercised representatively by the sanitised copy, since it keeps the user and
  template counts.

### What the sanitised copy does NOT rehearse

The sanitiser empties or blanks three things, so the copy cannot time the
migrations that read them. All three are worth knowing before the deployment
rather than during it:

| dropped by the sanitiser | migration that reads it | risk |
| --- | --- | --- |
| `reversion_version`, `reversion_revision` | `marketplace/0270_scrub_secret_options_from_reversion` | Low. It filters with `serialized_data__contains` and walks id-ordered keyset batches, so only Offering versions mentioning the key reach Python. But the copy has no history at all, so the copy proves nothing either way. |
| `structure_servicesettings.password`, `.token`, `.options` | `structure/0080`, `structure/0081` (encrypt in place) | Low: few rows. |
| `marketplace_offering.secret_options` | `marketplace/0269_encrypt_existing_secret_options` | Low: few rows. |

`reversion_version` is the one to check, because it is plausibly the second
largest table in production after `logging_event` and nothing here measures it.
`scripts/resync_preflight_check.sql` reports the ten largest tables with sizes,
which settles it.

## 7. Sequencing

1. Scope the OpenPortal 0.32 → 0.92 library and service upgrade. This can
   change the whole timeline, so settle it first.
2. Reset onto `upstream/develop`; adopt upstream for openportal, marketplace
   openportal modules, and proposal.
3. Re-apply the two OpenPortal tail commits.
4. Re-apply the section 5 carry-forward set.
5. Add migrations dropping `unix_username`, `short_name` and the attachment
   table.
6. Write and rehearse the reconciliation script against a production dump.
   For a rehearsal at production scale rather than against dev data, sanitise
   a production dump first - see `docs/guides/production-data-sanitisation.md`.
7. Run and extend the test suite.
8. Resync waldur-homeport, per `homeport-resync-plan.md`. The removed-endpoint
   inventory that step depended on is done and recorded there: every dropped
   endpoint homeport calls sits inside `src/proposals`, which is replaced
   wholesale, so nothing outside it needs reworking.

## 8. Testing

Upstream requires Python 3.13 (`requires-python = ">=3.13,<3.14"`, from
`bbc7909be`, which also moved to Debian Bookworm), so the toolchain moves with
the resync.

Upstream ships `waldur_core.server.test_settings`, which points at a `db`
host. `waldur_core/server/my_test_settings.py` overrides that to a local
PostgreSQL instance, keeping the command in `CLAUDE.md` working:

```bash
DJANGO_SETTINGS_MODULE=waldur_core.server.my_test_settings uv run pytest
uv run pre-commit run --all-files
```

Note that `uv sync` needs LDAP headers (`libldap2-dev`, `libsasl2-dev`) to
build `python-ldap`.

### Generate the OpenAPI schema — treat this as a required gate

```bash
DJANGO_SETTINGS_MODULE=waldur_core.server.doc_settings \
  uv run waldur spectacular --api-version "$VERSION" \
  --file waldur-openapi-schema.yaml --fail-on-warn
```

This is what CI runs (`.gitlab-ci.yml`, the `spectacular` job, which also does
a second pass with `SKIP_MAKE_FIELDS_OPTIONAL=true` for the TypeScript
schema). It takes ~10 minutes and it is the **only** check that exercises the
whole API surface, which is also the contract waldur-homeport consumes through
the generated `waldur-js-client`.

It earned its place here. After the merge, the migration graph built, Django
system checks passed, `makemigrations --check` reported nothing pending, ruff
was clean, the tree byte-compiled and the test subset passed — and schema
generation still failed with four errors. The cause was residue: where a file
changed on both sides without a textual conflict, git auto-merged it and kept
the local lines, so `proposal/filters.py` carried a stray `project_uuid`
filter with no `view_name` and a fields entry for the dropped `submitted_at`.
None of the other checks can see a filter on a column that no longer exists.

Two habits follow from that:

- After adopting a directory wholesale, verify it: diff every file in it
  against `upstream/develop` and reset anything that differs. A clean merge is
  not evidence that a file matches upstream.
- Regenerate the schema before asking anyone to build a client from the
  branch.

Coverage to add for the carried-forward code, which currently has little:

- `structure/filters.py` — the project date filters, especially
  `active_during` boundaries and `in_grace`, whose database-resolved grace
  period should be checked against `Project.get_grace_period_days()` for the
  project-level, customer-fallback and zero cases.
- `invoices/views.py` — that a project member can list their own project
  credits and cannot see another project's.
- `permissions/views.py` and `users/views.py` — domain enforcement both on and
  off, given upstream has no coverage for these paths.
- `billing/serializers.py` — that the composed eager-load runs the original
  method exactly once.

`validate_end_date` is already covered: the local test was rewritten as
`test_validate_end_date_on_creation_has_no_grace_period`,
`test_validate_end_date_uses_project_grace_period` and
`test_validate_end_date_falls_back_to_customer_grace_period`. Upstream's own
`GracePeriodTest` covers the model-level grace behaviour.

## 8.1 Rehearsing against production-scale data

`scripts/resync_rehearse_migration.sh` runs the whole deployment sequence
against a copy of the sanitised production database:

```bash
scripts/resync_rehearse_migration.sh --datadir <the sanitise cluster>
```

Pre-flight, reconcile, `migrate`, `makemigrations --check`. It works on
`waldur_rehearsal`, created from `waldur_sanitise` with `CREATE DATABASE ...
TEMPLATE` -- a filesystem copy, so it costs disk rather than the hours a
re-restore would, and the sanitised database is left untouched. The rehearsal
is therefore repeatable: every fix gets a clean starting point in seconds.

Two things it gives that a rehearsal against dev data cannot:

- **The pre-flight's verdict on real data.** Whether any of the 1,651 projects
  would lose a `short_name` that is not recoverable from a slug or a
  `ProjectInfo` row. On the dev database 16 of 31 projects had `short_name` and
  `slug` differing, so this is not hypothetical, and the drop is irreversible.
- **Per-migration timings**, which is what a deployment window is built from.
  Django does not report them, so the script timestamps each `Applying ...` line
  and reports the slowest by subtraction.

It runs with `waldur_core.server.rehearsal_settings`, which is `base_settings`
plus a database connection from the environment. Deliberately **not**
`test_settings`: that adds `waldur_core.quotas.tests`,
`waldur_core.structure.tests` and `waldur_pid.tests` to `INSTALLED_APPS`, whose
migrations would then run and create tables production never has -- which
applies migrations the real deployment does not, and can mask a real one. If
the deployment's own settings module is importable, `DJANGO_SETTINGS_MODULE`
overrides it and is closer still.

Steps 1 and 2 need only `psql`. If no Python that can import waldur is found,
the script stops after them with the reconciled copy in place and prints what
to run -- worth doing on its own, since the pre-flight is the part that decides
whether the irreversible drops are safe.

## 9. Effort

| Task | Estimate |
| --- | --- |
| OpenPortal adoption + 2 tail commits | ~1 day |
| Carry-forward set (~40 hunks, mostly additive) | 1–2 days |
| Deletions (proposal, `unix_username`, `short_name`, attachments) | ~0.5 day |
| Reconciliation script + dump rehearsal | 1–2 days |
| Test suite and Python 3.13 | 1–3 days |
| **Total** | **~1–2 weeks** |

Excludes the OpenPortal service upgrade, which is scoped separately and is the
main unknown.

Net gain: 13 upstream test modules covering OpenPortal code written here that
previously had almost no coverage, and a base from which `waldur_openportal`
can be developed against upstream directly.

## 10. The upstream base is pinned to a release candidate

This branch tracks the tag **`8.1.3-rc.8`** (`f76a0bbce`, 2026-09-01), not
`develop`. Merging a moving branch head is not reproducible: the same command a
day later gives a different base, and the delta measured against it silently
changes shape. A tag fixes that.

Regenerate the audit below against the tag, not the branch:

```bash
git fetch upstream --tags
git diff --name-status 8.1.3-rc.8 HEAD
git diff --shortstat 8.1.3-rc.8 HEAD
```

The resync was originally merged against `b00cd9b18` (2026-09-03), 23 commits
past the tag, and was rewound onto it. `rc.8` is an ancestor of that commit, so
the rewind removed upstream work and added none: 59 files, mostly the VMware
pyVmomi backend rewrite, Nova instance metadata, ToS consent gating and two
migrations (`logging.0028`, `openstack.0082`) that no longer exist here.

**One consequence to be aware of.** `rc.8` predates `8a474ddcb`, which bumped
djangorestframework to 3.18.0, so this branch ships **DRF 3.16.1**. The two
advisories that bump addressed, both published 2026-08-05 and both affecting
3.17.1 and earlier:

| Advisory | Severity | Applies here? |
| --- | --- | --- |
| [CVE-2026-73228](https://github.com/encode/django-rest-framework/security/advisories/GHSA-2m8g-3cmr-wg3w) — DRF's JSON and urlencoded parsers read the request stream directly, bypassing Django's `DATA_UPLOAD_MAX_MEMORY_SIZE` on `request.data` | Moderate, CVSS 5.3 | **Yes**, but bounded. Availability only — no authentication, authorization, disclosure or integrity impact — and the local nginx caps bodies at `client_max_body_size 10M`, so the memory a request can provoke is bounded by that rather than unbounded. Multipart is unaffected, since DRF delegates it to Django. |
| [CVE-2026-73229](https://github.com/encode/django-rest-framework/security/advisories/GHSA-g47c-3xmw-q6m2) — `AdminRenderer` calls the view's GET handler without a permission check when rendering an invalid write, disclosing GET-protected data | Moderate, CVSS 4.3 | **No.** It requires `AdminRenderer` to be enabled; Waldur's `DEFAULT_RENDERER_CLASSES` are `WaldurORJSONRenderer` and `BrowsableAPIRenderer`, and `AdminRenderer` appears nowhere in the tree. |

So the residual exposure from pinning to `rc.8` is one moderate availability
issue, already bounded by the proxy's body limit. Still worth taking the next
release candidate or `8.1.3` promptly, since both carry the fix.

**Django, by contrast, is improved substantially by the resync.** The fork ran
**4.2.24** (published 2025-09-03) on a branch whose extended support ended
**2026-04-07**, with 4.2.30 as its final release — so it had missed the 4.2
patches issued after 4.2.24 and, from April 2026 onwards, was receiving nothing
at all. Django's own advisories now carry the line that unsupported series
"were not evaluated and may also be affected", which is the real problem with
sitting on 4.2: the exposure is not a list you can enumerate.

This branch runs **6.0.8** (2026-08-04), which is the newest 6.0.x on PyPI and
postdates every published Django advisory — the most recent, CVE-2026-53877,
is patched in 6.0.7. Django is identical between `rc.8` and `develop`, so the
tag choice does not affect this.

`openportal` is pinned at **>=0.93.0** and locked to 0.93.0, the version
released and tested on 2026-09-04. Because the pin is a floor rather than an
equality, re-locking will drift to whatever is newest; move it deliberately
with `uv lock --upgrade-package openportal`, and re-run the API surface check
afterwards — every `openportal.*` attribute the OpenPortal modules reference
must still resolve:

```bash
grep -rhoP "(?<![\w.])openportal\.\K[A-Za-z_][A-Za-z0-9_]*" \
    src/waldur_openportal/ src/waldur_mastermind/marketplace_openportal*/ | sort -u
```

That check is what caught `Status.PENDING` no longer existing in 0.92, which
upstream still calls in `sync_board`. Two names it reports are false
positives: a notification key in a test, and a mention in a comment.

Moving to a newer tag is cheap: the delta is 37 files, and the same rewind is
`git read-tree -u --reset <tag>` followed by re-checking out those files.

## 11. Current delta versus upstream

An audit of where the branch actually sits, rather than what was intended.
Regenerate it with:

```bash
git fetch upstream --tags
git diff --name-status 8.1.3-rc.8 HEAD
git diff --shortstat 8.1.3-rc.8 HEAD
```

At the time of writing: **37 files, +2,926 / -37**, and — importantly —
**nothing upstream has that this branch deletes**. Every difference is either
an addition or a local modification, so there is no risk of having silently
dropped upstream code.

### Files only in this branch (13)

| File | Purpose |
| --- | --- |
| `docs/guides/upstream-resync-plan.md` | This document |
| `docs/guides/homeport-resync-plan.md` | The frontend companion, temporary |
| `scripts/resync_reconcile_db.sql` | One-time database reconciliation |
| `scripts/resync_preflight_check.sql` | Read-only pre-flight for the above |
| `scripts/resync_rehearse_migration.sh` | Rehearses the whole sequence against a copy of production |
| `src/waldur_core/server/rehearsal_settings.py` | Settings for that rehearsal |
| `scripts/sanitise_production_dump.sh` | Turning a production dump into local test data |
| `scripts/sanitise_production_dump.sql` | The sanitisation itself |
| `scripts/sanitise_verify.sql` | Proving the sanitised copy carries nothing |
| `docs/guides/production-data-sanitisation.md` | How to use the three above |
| `scripts/docker-test-entrypoint.sh` | Stale-image guard for the test container |
| `docker-compose.test.yml` | Running the suite in Docker |
| `src/waldur_core/server/my_test_settings.py` | Test database from the environment |
| `src/waldur_core/structure/tests/test_project_date_filters.py` | Coverage for the project date filters |
| `src/waldur_mastermind/invoices/tests/test_project_credit_list_scoping.py` | Coverage for the ProjectCredit list scoping |
| `src/waldur_openportal/tests/test_project_accounting_summary.py` | Coverage for the accounting summary additions |
| `docker/rootfs/etc/nginx/*` (3 files) | Local nginx configuration |

The first six and `my_test_settings.py` are resync scaffolding: the two plans
and the homeport companion are deletable once the work is done, the rest are
worth keeping.

### Files modified (25)

Functional carry-forwards:

| File | Change |
| --- | --- |
| `structure/filters.py` | Project date filters, `in_grace` resolving grace per row |
| `structure/serializers.py` | Grace-aware `validate_end_date`, `disable_long_tokens` |
| `structure/tests/test_project.py` | End-date tests rewritten for per-project grace |
| `billing/serializers.py`, `invoices/serializers.py` | Composed eager-load fix |
| `invoices/views.py` | `ProjectCredit` list scoped by role |
| `core/features.py`, `core/tests/test_features.py` | 8 feature flags and their coverage |
| `core/utils.py` | Email blank-line collapsing, unknown-key warning, link hardening |
| `permissions/views.py`, `users/views.py` | `enforce_allowed_domains` enforcement |
| `permissions/serializers.py` | `user_slug`, pairing with `show_slug_as_id` |
| `logging/tasks.py`, `server/celery_settings.py` | `purge_old_events` and its schedule |
| `users/templates/invitation_created_message.*` | Invitation email improvements |
| `openportal/{views,serializers,filters}.py` | The `offering_name` filter and `include_offering_names` |
| `openportal/tasks.py` | `Status.pending()` fix for openportal 0.92 |

Configuration and packaging:

| File | Change |
| --- | --- |
| `pyproject.toml`, `uv.lock` | `openportal>=0.92.0` |
| `docker/rootfs/etc/waldur/notifications.json` | Local notification configuration |
| `docs/guides/build-commands.md` | Running the suite in Docker |

### Auditing for residue

Most defects found after the merge were residue: a file changed on both sides
without a textual conflict, auto-merged, keeping the local version. A clean
merge is not evidence that a file matches upstream.

The check that finds it is to diff **every** file present in both trees, not
just the directories adopted wholesale, and to account for each difference:

```bash
git diff --name-only upstream/develop HEAD | while read f; do
    [ -f "$f" ] || continue
    git cat-file -e "upstream/develop:$f" 2>/dev/null && echo "$f"
done
```

Anything on that list without a reason in the tables above is residue. That
sweep found the project-ending notification templates (which failed upstream's
own test), Call-scope filtering in `logging/filters.py`, a proposal-creator
guard in `permissions/serializers.py`, a `PROPOSAL.DELETE_PERMISSION` grant in
`permissions.yaml`, and two stray blank lines.
