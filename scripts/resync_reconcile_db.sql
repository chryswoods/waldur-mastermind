-- One-time database reconciliation for the upstream resync.
--
-- This fork is the only deployment, so rather than merging two migration
-- histories, it adopts upstream's history wholesale and reconciles the
-- database to match. Run this ONCE, against a restored production dump
-- first, before ever running it against the live database.
--
-- Order of operations:
--
--   1. Take a full dump.
--   2. Run this script. It is a single transaction, so it either applies
--      completely or not at all.
--   3. Run:  python -m waldur_core.server.manage migrate
--      which replays upstream's proposal 0047-0077 and anything else new.
--   4. Verify:  python -m waldur_core.server.manage makemigrations --check --dry-run
--      must report "No changes detected".
--
-- Every drop uses IF EXISTS and every delete is keyed on rows that may
-- already be gone, so the script can be re-run safely.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. waldur_openportal: almost all bookkeeping, with one exception.
--
-- The local 0034-0043 series and upstream's 0035-0039 reach the same objects
-- by a different route, so those five are recorded here as already-applied
-- rather than deleted, which would make step 3 re-run them against tables
-- that already exist:
--
--   upstream 0035  creates the two cached report tables and their indexes,
--                  which local 0034, 0035 and 0036 already created
--   upstream 0036  creates RemoteProject, RemoteProjectAllocationEntry,
--                  RemoteProjectAuditEntry, RemoteProjectAttachment and
--                  ManagedProjectAuditEntry, which local 0037-0043 created
--   upstream 0037-0039  AlterModelOptions only, so no DDL either way
--
-- Upstream 0034 is deliberately NOT in that list. It adds can_be_managed to
-- allocation and remoteallocation, which upstream's Allocation and
-- RemoteAllocation gain from core_models.AvailableMixin - a base class this
-- fork's models never had. Those two columns genuinely do not exist here, so
-- 0034 must be allowed to run for real in step 3. Faking it would leave the
-- columns missing and the schema quietly wrong.
--
-- AvailableMixin is the only base-class difference between the two trees'
-- openportal models; every other model has identical bases and identical
-- declared fields, which is why the rest of the series is safe to fake.
-- ---------------------------------------------------------------------------

DELETE FROM django_migrations
WHERE app = 'waldur_openportal'
  AND name IN (
    '0034_cachedprojectusagereport',
    '0035_cachedprojectstoragereport',
    '0036_cachedprojectstoragereport_waldur_open_project_077226_idx_and_more',
    '0037_remoteproject_remoteprojectallocationentry_and_more',
    '0038_alter_remoteproject_unique_together_and_more',
    '0039_alter_remoteprojectauditentry_event_type_and_more',
    '0040_remoteproject_error_message',
    '0041_alter_remoteprojectauditentry_event_type',
    '0042_alter_remoteproject_notes',
    '0043_alter_remoteproject_allowed_domains'
  );

INSERT INTO django_migrations (app, name, applied)
SELECT 'waldur_openportal', upstream_migrations.name, now()
FROM (
    VALUES
      -- 0034 is intentionally absent: it carries real DDL. See above.
      ('0035_add_cached_reports_and_available_mixin'),
      ('0036_remote_projects'),
      ('0037_alter_allocation_options_and_more'),
      ('0038_alter_managedprojectauditentry_options_and_more'),
      ('0039_alter_remoteprojectattachment_options')
) AS upstream_migrations(name)
WHERE NOT EXISTS (
    SELECT 1 FROM django_migrations dm
    WHERE dm.app = 'waldur_openportal' AND dm.name = upstream_migrations.name
);

-- ---------------------------------------------------------------------------
-- 2. proposal: clean reset.
--
-- The portal holds no proposals, so the local 0047-0054 series is undone
-- entirely and upstream's 0047-0077 replays from scratch in step 3.
--
-- Checked for collisions before writing this: none of these names clash with
-- upstream's proposal schema. Upstream's only submitted_at is on ReviewerBid,
-- not Proposal, and its notes fields are internal_notes, review_notes and
-- manager_notes - all distinct from the local Proposal.notes.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS proposal_proposalresourceadjustment;
DROP TABLE IF EXISTS proposal_proposalidgenerator;

ALTER TABLE proposal_proposal DROP COLUMN IF EXISTS stale_reminder_sent_at;
ALTER TABLE proposal_proposal DROP COLUMN IF EXISTS submitted_at;
ALTER TABLE proposal_proposal DROP COLUMN IF EXISTS notes;

ALTER TABLE proposal_round DROP COLUMN IF EXISTS minimum_required_uploads;
ALTER TABLE proposal_round DROP COLUMN IF EXISTS default_allowed_domains;
ALTER TABLE proposal_round DROP COLUMN IF EXISTS default_membership_control;
ALTER TABLE proposal_round DROP COLUMN IF EXISTS default_reapply_text;
ALTER TABLE proposal_round DROP COLUMN IF EXISTS default_reapply_url;
ALTER TABLE proposal_round DROP COLUMN IF EXISTS fixed_review_end_date;

DELETE FROM django_migrations
WHERE app = 'proposal'
  AND name IN (
    '0047_proposal_stale_reminder_sent_at',
    '0048_proposalidgenerator',
    '0049_round_minimum_required_uploads',
    '0050_proposal_submitted_at',
    '0051_proposalresourceadjustment',
    '0052_proposal_notes_round_default_allowed_domains_and_more',
    '0053_round_default_reapply_text_round_default_reapply_url',
    '0054_round_fixed_review_end_date'
  );

-- ---------------------------------------------------------------------------
-- 3. Vestigial columns: core.User.unix_username, structure.Project.short_name.
--
-- Superseded by shortname handling inside waldur_openportal
-- (UserInfo.shortname and ProjectInfo.shortname, synced to User.slug and
-- Project.slug). Upstream's OpenPortal code guards both with hasattr and falls
-- back to slug, so dropping them changes no upstream behaviour.
--
-- BEFORE RUNNING: confirm every user and project has its shortname migrated
-- into waldur_openportal. Both queries below must return zero; the data is not
-- recoverable once the columns are gone.
--
--   SELECT count(*) FROM core_user u
--   WHERE u.unix_username IS NOT NULL
--     AND NOT EXISTS (SELECT 1 FROM waldur_openportal_userinfo i
--                     WHERE i.user_id = u.id AND i.shortname = u.unix_username);
--
--   SELECT count(*) FROM structure_project p
--   WHERE p.short_name IS NOT NULL
--     AND NOT EXISTS (SELECT 1 FROM waldur_openportal_projectinfo i
--                     WHERE i.project_id = p.id AND i.shortname = p.short_name);
-- ---------------------------------------------------------------------------

ALTER TABLE core_user DROP COLUMN IF EXISTS unix_username;
ALTER TABLE structure_project DROP COLUMN IF EXISTS short_name;

-- The migrations that added those columns, and the merge nodes that stitched
-- the local branch into upstream's history, are gone from the tree; their rows
-- must go too, or migrate will fail on unknown nodes.
DELETE FROM django_migrations
WHERE (app = 'core' AND name = '0011_user_unix_username')
   OR (app = 'structure' AND name IN (
        '0046_project_short_name',
        '0053_alter_project_short_name',
        '0054_merge_20250612_0633',
        '0062_merge_20251006_0729',
        '0063_merge_20251014_0410',
        '0067_merge_20251110_0435'
      ));

-- ---------------------------------------------------------------------------
-- 4. Broadcast message attachments.
--
-- Dropped along with the feature. The attached files themselves stay in media
-- storage; remove them separately if that storage matters.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS notifications_broadcastmessageattachment;

DELETE FROM django_migrations
WHERE app = 'notifications' AND name = '0010_broadcastmessageattachment';

COMMIT;

-- After step 3, this should show a plausible count per app and nothing for the
-- removed local migrations:
--
--   SELECT app, count(*) FROM django_migrations GROUP BY app ORDER BY app;
