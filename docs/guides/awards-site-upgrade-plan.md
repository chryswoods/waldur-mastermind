# Awards site: upgrade plan

The awards site is a separate Waldur deployment from the OpenPortal portal. It
runs only the proposal app, and reaches the other sites through OpenPortal
remote offerings. It was deployed from the fork's own proposal code, which the
upstream resync deleted wholesale in favour of upstream's far more advanced
version (`upstream-resync-plan.md` §3.3).

So this site cannot take the portal's upgrade path. The portal held no
proposals; this one holds two and a half thousand.

The plan here is to **archive rather than migrate**. Calls can all be closed
before the upgrade and new ones created afterwards, so no proposal has to
survive as a *working* proposal — only as a readable record.

## 1. What is actually there

Measured September 2026:

| Table | Rows |
|---|---|
| `proposal_proposaldocumentation` | 3403 |
| `proposal_requestedresource` | 2271 |
| `proposal_proposal` | 2258 |
| `proposal_review` | 1780 |
| `proposal_proposalresourceadjustment` | 223 |
| `proposal_call_documents` | 22 |
| `proposal_calldocument` | 22 |
| `proposal_proposalprojectrolemapping` | 18 |
| `proposal_requestedoffering` | 16 |
| `proposal_round` | 11 |
| `proposal_callresourcetemplate` | 8 |
| `proposal_call` | 7 |
| `proposal_callmanagingorganisation` | 3 |
| `proposal_proposalidgenerator` | 2 |
| `proposal_resourceallocator` | 0 |
| `proposal_reviewcomment` | 0 |

About 7,700 rows in total, across 16 tables. That is small enough that the
archive can be real models with real columns and a copy script, rather than
opaque JSON blobs: the copy will run in seconds and can be re-run as often as
it takes to get right.

Two shapes are worth noticing. **Seven calls and eleven rounds** carry all of
it, so the call- and round-level archive can afford to be generous. And
`proposal_reviewcomment` is empty while `proposal_review` holds 1,780 rows, so
the review conversation feature was never used — the reviews themselves are
where the sensitive text lives.

### 1.1 The migration history

All 56 `proposal` rows are applied, up to and including
`0054_round_fixed_review_end_date`. Note that this differs from the portal,
which stopped at seven of the eight local migrations and therefore never
gained the `fixed_review_end_date` column.

The history is also not linear. Both `0001_initial` and
`0001_initial_squashed_0033_call_organizer` are recorded, and there are two
`0027` nodes (`0027_call_manager_role` and `0027_proposal_member_role`) from a
branch point in the fork's history.

Under the portal's in-place reconciliation that would all need unpicking.
Under the approach below it is simply deleted, which is one of the reasons to
prefer it.

### 1.2 What must not be run here

`scripts/resync_reconcile_db.sql` §2 is written for a portal with no
proposals. It keeps the proposal tables and strips the fork's columns from
them:

```sql
ALTER TABLE proposal_proposal DROP COLUMN IF EXISTS notes;
ALTER TABLE proposal_proposal DROP COLUMN IF EXISTS submitted_at;
ALTER TABLE proposal_round DROP COLUMN IF EXISTS fixed_review_end_date;
```

Run unmodified on the awards site, that destroys the columns this plan exists
to preserve, before anything has been archived. **The awards site needs its own
reconciliation script.** It is a different script, not a flag on the existing
one, so that neither can be pointed at the wrong database by accident.

## 2. The approach

Three components, in this order of confidence:

1. **Rename the old tables out of the way** during the upgrade window. This is
   the mechanical trick that makes everything else unhurried.
2. **An archive app** — real models, no foreign keys to live data — plus a copy
   script that fills it from the renamed tables.
3. **A read-only API and a HomePort viewer**, so archived calls, rounds and
   proposals stay browsable.

### 2.1 Why renaming works

**Nothing outside the proposal app points into it.** Checked on both the fork's
code and upstream's: no other app's models declare a foreign key to
`proposal.Call`, `Round`, `Proposal` or `Review`. Every dependency runs
outward — proposal → `structure.Customer`/`Project`, `marketplace.Offering`/
`Plan`, `core.User`.

So `ALTER TABLE proposal_call RENAME TO ...` is a metadata-only operation that
breaks no constraint and rewrites no data. It is instant on tables this size
(and would be instant on tables a thousand times this size), and it is
reversible by renaming back.

That decouples the upgrade from the archive. The upgrade window needs only the
rename; the copy happens afterwards, at leisure, against a database that is
already serving the new code. Nothing is dropped until the copy has been
verified — and dropping is a separate decision that can wait months.

## 3. The upgrade sequence

1. **Close all open calls** and let any in-flight work settle.
2. **Take a dump.** This is the archive's backstop: every later step is
   recoverable from it.
3. **Rename** all 16 `proposal_*` tables to `old_proposal_*` (including the
   `proposal_call_documents` and `proposal_call_offerings` through-tables).
4. **Delete every `proposal` row** from `django_migrations` — all 56, not just
   the fork's `0047`–`0054`.
5. **Deploy the new code and migrate.** With no tables and no history,
   upstream's `0001_squashed_0074` applies as a single unit against a clean
   slate. This is the easiest case for the squash, not the hardest.
6. **Migrate the archive app**, which creates its own tables.
7. **Run the copy script** against the renamed tables. Re-runnable; verifies
   counts per model against the source and refuses to report success on a
   mismatch.
8. **Move the documents' media rows** to the archive's prefix — see §5.
9. **Leave the renamed tables in place** until the archive has been exercised
   in anger. Dropping them is a later, separate change.

Steps 3–5 are the only ones inside the maintenance window.

## 4. The archive app

A new app, `waldur_mastermind.proposal_archive`, holding what the old app held,
flattened:

| Archive model | Source | Notes |
|---|---|---|
| `ArchivedCall` | `Call`, `CallManagingOrganisation` | organisation denormalised onto the call |
| `ArchivedRound` | `Round` | |
| `ArchivedProposal` | `Proposal` | the fork's `notes`, `submitted_at`, `allocation_comment` all preserved |
| `ArchivedRequestedResource` | `RequestedResource`, `RequestedOffering`, `CallResourceTemplate` | offering and plan denormalised to uuid + name |
| `ArchivedReview` | `Review`, `ReviewComment` | staff-only, see §4.2 |
| `ArchivedDocument` | `CallDocument`, `ProposalDocumentation` | one model, `kind` discriminates |

`ProposalIDGenerator` (2 rows, a counter) and `ProposalResourceAdjustment` (223
rows) are judgement calls — the generator is certainly not worth archiving; the
adjustments probably are, folded into `ArchivedProposal.payload`.

### 4.1 No foreign keys to live data

Every reference out of the archive is denormalised to a UUID plus a display
value: `customer_uuid` + `customer_name`, `created_by_uuid` +
`created_by_username`, `project_uuid` + `project_name`, `offering_uuid` +
`offering_name`.

This matters more than it looks. A real FK would mean an archived proposal
`PROTECT`s the user who wrote it, or worse, gets `CASCADE`-deleted when someone
tidies up a customer years from now. Denormalised, the archive is inert: it
cannot block a deletion and cannot be destroyed by one.

Each archive row also carries a `payload` JSONB column holding the original row
verbatim, including any column not modelled explicitly. It costs almost
nothing at this scale and it is the difference between "we didn't archive that
field" and "it's in the payload".

**The original UUIDs are preserved**, which is what makes §6 possible.

### 4.2 Who can read what

The archive is read-only, but it is not public: proposals carry
`project_is_confidential`, and reviews carry reviewer identities and candid
private comments.

| Object | Visible to |
|---|---|
| Archived call, round | staff, support, the call's managing organisation |
| Archived proposal | the above, plus the proposal's creator |
| Archived document | as for its parent call or proposal |
| Archived review, review comment | staff, support, the call's managing organisation only |

Reviewer identity and review text are **never** exposed to applicants in the
archive, regardless of what the old call's
`reviewer_identity_visible_to_submitters` / `reviews_visible_to_submitters`
flags said. The archive is a record for administrators, not a continuation of
the review process, and the cost of being wrong is asymmetric.

This is the one place a read-only archive still needs real access control, and
it is why §4.1's denormalised `created_by_uuid` and the call's organisation
uuid have to be captured during the copy rather than inferred later.

## 5. Documents, and a collision to avoid

Uploaded files in Waldur live **in the database** — `media_file.content` is a
`BinaryField` — and are served by `/api/media/<uuid>/`, which is deny by
default. A `FileField` stores the path; `media_file.name` matches it.

That is good news: archiving documents moves no bytes. But there is a trap.

Upstream's proposal app already registers media access rules for exactly the
prefixes the old documents sit under:

```python
access.register_public(access.upload_prefix(CallDocument, "file"))
access.register(access.upload_prefix(ProposalDocumentation, "file"),
                user_can_access_proposal_documentation)
```

and `access.register()` **raises `ImproperlyConfigured` on a duplicate
prefix**. So the archive cannot declare `upload_to="call_documents"` or
`upload_to="proposal_project_supporting_documentation"` to match the existing
files — the prefix is taken. Worse, if it did nothing, the old files would be
resolved by *upstream's* rule, which queries upstream's now-empty tables and
returns False: every archived document would 403.

So the copy renames the media rows onto the archive's own prefixes:

```
call_documents/<file>                          -> archived_call_documents/<file>
proposal_project_supporting_documentation/<f>  -> archived_proposal_documentation/<f>
```

`media_file.name` is unique and indexed, the update touches ~3,425 rows, and
the bytes are untouched. The archive app then declares those prefixes as its
own and registers a rule matching §4.2. Without this step `CoverageTest` fails
and every document download 403s.

Note also that upstream registers call documents as **public**. Archived call
documents should not be: default them to the §4.2 rule and revisit only if
someone asks.

## 6. URLs

Proposal links are `/proposals/{proposal_uuid}` (the shape is confirmed by the
formbricks `FRONTEND_FLOW_COMPLETE_URL_TEMPLATE` default).

Because archive rows keep the original UUIDs, old links can keep working
without touching any stored data: the resolver looks for a live proposal, and
falls back to the archive when there is no match. Either HomePort's proposal
route handles the 404 by redirecting to the archive view, or the backend
exposes `GET /api/proposal-archive/resolve/<uuid>/` returning the kind and the
archive URL.

A database search-and-replace is the fallback, not the plan: it can only fix
links already stored in Waldur, and does nothing for the ones in people's
email, tickets and bookmarks.

## 7. Formbricks

The formbricks work on `isambard/application_forms` (~1,900 lines over 11
files, 723 of them tests) was never deployed, so there is no data to migrate —
only code to re-point at upstream's proposal app.

**It moves to its own app.** Its couplings to the proposal app are just two
model-level things:

- `Call.formbricks_flow_key` — a column on the old `Call`;
- `FormStepResponse.proposal` — a FK to the old `Proposal`.

In its own app the first becomes a `CallFormConfig` row (call uuid → flow key)
and the second keeps a FK to upstream's `Proposal`. `formbricks_client.py`,
`formbricks_flows.py` and `formbricks_mapper.py` (557 lines) port unchanged;
the work is in the ~380 lines of views, which have to be re-pointed at
upstream's proposal states.

The reason to do this rather than re-apply the patch to `proposal/` is the one
the resync just taught: fork code living inside an app that is adopted wholesale
from upstream has to be re-merged, by hand, every time upstream moves. Formbricks
in its own app never conflicts again. It also dissolves a collision that exists
today — the branch carries
`0054_call_formbricks_flow_key_formstepresponse`, the same number as the
deployed `0054_round_fixed_review_end_date`.

Its configuration lives in the `WALDUR_PROPOSAL` extension settings
(`FORMBRICKS_BASE_URL`, `FORMBRICKS_MANAGEMENT_API_URL`,
`FORMBRICKS_WEBHOOK_SECRET`, `FORMBRICKS_API_KEY`), all placeholders at
present. They move with the app.

### 7.1 The end-of-project survey is separate, and is in neither merge

There is a second piece of Formbricks work, unrelated to application forms: the
project dashboard renders an end-of-project feedback survey once a project
reaches its end date. It is worth being precise about where it lives, because
it is **not** in either repository's merged history.

It is one file — `src/project/ProjectDashboard.tsx` on the
`end-project-form` branch of `isambard-sc/waldur-homeport` (`eed730330`,
29 July 2026, "update to production formbricks link"). Frontend only: there is
no backend code for it anywhere, in any branch of this repository.

What it does: shows an `<iframe>` of a hardcoded Formbricks survey when
`project.end_date` has passed and the viewer holds
`CREATE_PROJECT_PERMISSION` on the project or its customer (the PI or an
organisation owner). The survey URL carries the project name and slug, the
user's name and email, and a call reference assembled from the proposal call's
`reference_code` and the round's start date.

Three consequences:

- **It has to be re-applied by hand** to the resynced HomePort, or it is lost
  at the next deployment from a mainline branch. It is small — roughly forty
  lines in one component — but `ProjectDashboard.tsx` moved a long way in the
  resync, so this is a re-write against the new file, not a cherry-pick.
- **Check what the awards portal actually deploys.** The survey is not on that
  fork's `prod` branch, yet it is live; so either the awards site is deployed
  from `end-project-form` directly, or `prod` is not its branch. Work that is
  live only on a feature branch is one deployment away from disappearing, and
  worth resolving regardless of this upgrade.
- **The survey URL is hardcoded in the component.** Moving it to a setting
  served to HomePort would let test and production point at different surveys,
  which they cannot today.

It also wants its own gate rather than sharing the application-forms one:
`project.show_end_of_project_survey` in `ProjectSection` describes what it is
and where it renders, and keeps the two Formbricks features independently
switchable. Its dependency on `proposalCall.reference_code` and the round start
time is worth re-checking against upstream's proposal API when it is re-applied
— those fields come from the proposal app, which is exactly what changed.

### 7.2 Three gates, not one

As written, formbricks has exactly one switch: `Call.formbricks_flow_key`, null
meaning "use the legacy Waldur-native form". It is **not** behind a feature
flag today, though it is often described as if it were.

Per-call is the right granularity for choosing a form, but it is the wrong
granularity for two other questions, so the port adds two more gates. The
codebase already has the pattern for an integration — see
`sram.integration` and `project.show_matrix_chat`, both of which say in their
own description that backend access is gated separately:

| Gate | Answers | Where |
|---|---|---|
| `proposal.formbricks_forms` feature | Does this portal offer Formbricks forms at all? | `core/features.py`, new `ProposalSection` |
| `FORMBRICKS_ENABLED` setting | May the backend talk to Formbricks and accept its webhooks? | the new app's extension settings |
| `formbricks_flow_key` | Which survey chain does *this call* use? | per call, as now |

The feature flag is presentational, as core features are: HomePort reads it
through `isFeatureVisible` to decide whether to offer a Formbricks form when
configuring a call, and whether to render the survey step in the applicant's
flow. Its one backend consequence is the same as everywhere else — none.

**The backend gate is the one that matters, and it is not the feature flag.**
The integration exposes an inbound webhook that accepts survey responses and
writes them against proposals. That is an ingress point, so it must be off by
default and gated server-side, on a setting an operator controls, rather than
on a feature entry that staff can flip from the UI. The precedent is exact:
`invoices.utils.affiliates_feature_enabled()` reads the Constance setting and
says in its docstring that the matching core feature "only controls homeport
element visibility and is not consulted here". Formbricks should read the same
way: views and tasks check the setting; nothing server-side reads the feature.

With all three in place the rollout is stepwise — deploy dormant, enable the
backend setting once the Formbricks instance and webhook secret are real, turn
the feature on to expose it in HomePort, and then opt calls in one at a time.
Any of the three turns it off again.

Adding the flag means regenerating HomePort's `src/FeaturesEnums.ts` and
`src/features/FeaturesDescription.ts` with `waldur print_features_enums` and
`waldur print_features_description`; the descriptions must match HomePort's
copy exactly or the next regeneration shows a spurious diff. Both generators
sort alphabetically, so declaration order in `features.py` does not matter.

Sequencing: formbricks lands **after** the upgrade. It has no bearing on the
archive, and mixing the two means debugging a survey integration and a
migration at the same time.

## 8. Sanitising this site

The rehearsal needs a sanitised copy, the same way the portal's did — see
`production-data-sanitisation.md` for the method and the lessons.

`scripts/sanitise_production_dump.sql` is written for the portal and does not
know about the proposal tables. The awards site needs its own script, or a
proposal stage added to that one. What it has to cover:

- **Free text written by people** — `proposal_proposal.project_summary`,
  `.allocation_comment`, `proposal_review.summary_public_comment`,
  `.summary_private_comment` and the nine `comment_*` columns,
  `proposal_reviewcomment.message`. These go in the stage-5 filler list, which
  replaces prose with same-length filler rather than trying to rewrite names
  out of it.
- **`proposal_proposal.notes`** is a JSONB column and will be walked by the
  stage-7b JSON sweep, but the sweep scrubs emails rather than prose: the notes
  need explicit treatment.
- **Documents are blanked.** `sanitise.blank('proposal_calldocument', 'file')`
  and the same for `proposal_proposaldocumentation`, which empty the path
  columns; `media_file.content` is already blanked by the existing script. The
  sanitised copy therefore has document *rows* with no document behind them,
  which is the right trade — it exercises the listing and the permission rules
  without carrying 3,425 real uploads around.
- **Names and emails** are handled by the existing identity map and the
  stage-7b sweep, as long as the script is run against this database with those
  stages intact.

Two lessons from the portal's sanitiser apply directly and are worth
re-reading before writing this one: anything blanked because it is a
*credential* will be missed by some feature that assumes it exists, and the
error will name something other than the credential; and a pseudonym has to be
valid in every format the real value was.

## 9. Rehearsal

The whole sequence in §3 should be rehearsed end to end on the sanitised copy
before it is run anywhere else, and the rehearsal should include the parts that
are easy to skip:

- the count verification in step 7, with a deliberate mismatch introduced once
  to prove it fails;
- a document download through `/api/media/<uuid>/` as each class of user in
  §4.2 — this is where the prefix collision of §5 shows up if it has been got
  wrong;
- an old `/proposals/{uuid}` link, to prove the fallback resolves;
- `waldur check`, `makemigrations --check`, and schema generation with
  `--fail-on-warn`, as for any change.

## 10. Open questions

- **`ProposalResourceAdjustment`** (223 rows): archived as its own model, folded
  into `ArchivedProposal.payload`, or dropped? Folding is the default.
- **Dropping the renamed tables**: after how long, and on whose say-so?
- **Archived call documents**: upstream serves the live ones publicly. Is
  anything lost by making the archived ones authenticated-only?
- **Retention**: is there a point at which archived proposals should be deleted
  outright — and does anything (funding body, institutional policy) require
  them to be kept for a set period?
- **Which branch the awards portal's HomePort is deployed from** (§7.1): the
  end-of-project survey is live but is not on that fork's `prod` branch.
