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

### 6.1 OpenPortal — bookkeeping only

Migration *numbers* collide (local `0034`–`0043` against upstream
`0034`–`0039`) but the end state is provably identical, so there is **no DDL
at all**:

1. Delete the `waldur_openportal` rows for local `0034`–`0043` from
   `django_migrations`.
2. `migrate waldur_openportal --fake` to record upstream `0034`–`0039`.
3. Verify with `makemigrations --check --dry-run` that no changes are pending.

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
