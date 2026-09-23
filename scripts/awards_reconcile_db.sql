-- Move the awards site's old proposal app out of the way, so upstream's can
-- be created in its place.
--
-- Run this against the AWARDS SITE only, on the old code, immediately before
-- deploying the resynced code. See docs/guides/awards-site-upgrade-plan.md.
--
--   psql -h 127.0.0.1 -p 5432 -U waldur -d waldur -f scripts/awards_reconcile_db.sql
--
-- This is NOT scripts/resync_reconcile_db.sql, which is the portal's. That one
-- strips the fork's columns from proposal tables it expects to be empty, which
-- on this database would destroy the data this exists to preserve. The two are
-- deliberately separate files so that neither can be pointed at the wrong
-- database by accident, and this one refuses to run on a portal anyway.
--
-- What it does, in one transaction:
--
--   1. renames every proposal_* table to old_proposal_*, with its indexes,
--      constraints and sequences, so upstream's migrations can create their
--      own objects under the original names;
--   2. deletes every proposal row from django_migrations, so the app replays
--      from nothing.
--
-- Renaming is metadata only: no data is rewritten and nothing is dropped, so
-- the whole thing is reversible and takes the same time on seven rows as on
-- seven million. Nothing outside the proposal app holds a foreign key into it
-- -- checked on both the fork's code and upstream's -- so no other table is
-- affected.
--
-- Afterwards `migrate` creates upstream's proposal schema against a clean
-- slate, and the copy into the archive app reads from the old_* tables at
-- leisure. Drop them only once the archive has been verified; that is a
-- separate, later change.

\set ON_ERROR_STOP on

BEGIN;

-- The new name for an object being moved aside. PostgreSQL identifiers stop at
-- 63 bytes and several of Django's generated constraint names are close to it,
-- so a plain 'old_' || name would be silently truncated - and two long names
-- that differ only at the end would truncate onto each other. Past the limit,
-- keep a readable prefix and make it unique with a hash of the original.
--
-- pg_temp so it disappears with the session; nothing is left behind.
CREATE FUNCTION pg_temp.rename_target(name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT CASE
        WHEN length($1) <= 59 THEN 'old_' || $1
        ELSE 'old_' || substr($1, 1, 46) || '_' || substr(md5($1), 1, 8)
    END
$fn$;

DO $$
DECLARE
    tbl text;
    targets text[];
    obj record;
    new_name text;
    tables_renamed int := 0;
    objects_renamed int := 0;
    rows_deleted int;
    already int;
BEGIN
    ------------------------------------------------------------------
    -- Refuse to run anywhere but the awards site.
    --
    -- The fork's proposal app has columns upstream's does not. Their presence
    -- is what says "this database still holds the old app", and their absence
    -- says either that this is a portal or that this script has already run.
    ------------------------------------------------------------------
    SELECT count(*) INTO already
    FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'old\_proposal\_%';
    IF already > 0 THEN
        RAISE EXCEPTION
            'Found % old_proposal_* tables already: this script has run '
            'before. Renaming again would bury the first archive.', already;
    END IF;

    IF to_regclass('public.proposal_proposal') IS NULL THEN
        RAISE EXCEPTION
            'No proposal_proposal table: this database has no proposal app to '
            'move aside.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'proposal_proposal'
          AND column_name = 'notes'
    ) OR NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'proposal_round'
          AND column_name = 'fixed_review_end_date'
    ) THEN
        RAISE EXCEPTION
            'proposal_proposal.notes or proposal_round.fixed_review_end_date '
            'is missing, so this is not the awards site''s proposal app. '
            'Refusing to rename anything. (On a portal, use '
            'scripts/resync_reconcile_db.sql instead.)';
    END IF;

    ------------------------------------------------------------------
    -- Rename, one table at a time.
    --
    -- The indexes, constraints and sequences have to move too. Renaming only
    -- the table leaves proposal_call_pkey, proposal_call_id_seq and the rest
    -- attached to it, and the CREATE TABLE that upstream's migrations run next
    -- wants those very names: index and sequence names are unique per schema,
    -- so the migration would fail on "relation already exists" with no obvious
    -- connection to what this script did.
    ------------------------------------------------------------------
    -- Collected before any renaming rather than iterated as a cursor: the
    -- loop body renames the very rows the query selects from, and a scan that
    -- reads the catalogue as it changes underneath itself is not something to
    -- depend on.
    SELECT array_agg(tablename ORDER BY tablename) INTO targets
    FROM pg_tables
    WHERE schemaname = 'public' AND tablename LIKE 'proposal\_%';

    FOREACH tbl IN ARRAY coalesce(targets, ARRAY[]::text[])
    LOOP
        -- Constraints first: renaming a constraint renames the index that
        -- backs it, so doing indexes first would rename some of them twice.
        FOR obj IN
            SELECT conname AS name FROM pg_constraint
            WHERE conrelid = ('public.' || quote_ident(tbl))::regclass
        LOOP
            new_name := pg_temp.rename_target(obj.name);
            EXECUTE format('ALTER TABLE public.%I RENAME CONSTRAINT %I TO %I',
                           tbl, obj.name, new_name);
            objects_renamed := objects_renamed + 1;
        END LOOP;

        FOR obj IN
            SELECT indexname AS name FROM pg_indexes
            WHERE schemaname = 'public' AND tablename = tbl
              AND indexname NOT LIKE 'old\_%'
        LOOP
            new_name := pg_temp.rename_target(obj.name);
            EXECUTE format('ALTER INDEX public.%I RENAME TO %I',
                           obj.name, new_name);
            objects_renamed := objects_renamed + 1;
        END LOOP;

        -- Sequences owned by this table's columns, which is how Django's
        -- AutoField primary keys are backed.
        FOR obj IN
            SELECT s.relname AS name
            FROM pg_class s
            JOIN pg_depend d ON d.objid = s.oid AND d.deptype = 'a'
            JOIN pg_class t ON t.oid = d.refobjid
            WHERE s.relkind = 'S' AND t.relname = tbl
              AND t.relnamespace = 'public'::regnamespace
        LOOP
            new_name := pg_temp.rename_target(obj.name);
            EXECUTE format('ALTER SEQUENCE public.%I RENAME TO %I',
                           obj.name, new_name);
            objects_renamed := objects_renamed + 1;
        END LOOP;

        EXECUTE format('ALTER TABLE public.%I RENAME TO %I',
                       tbl, pg_temp.rename_target(tbl));
        tables_renamed := tables_renamed + 1;
        RAISE NOTICE 'renamed %  ->  %', tbl, pg_temp.rename_target(tbl);
    END LOOP;

    ------------------------------------------------------------------
    -- Forget the app's migration history entirely.
    --
    -- Not just the fork's 0047-0054: the whole series. The awards site's
    -- history is not linear -- it records both 0001_initial and
    -- 0001_initial_squashed_0033_call_organizer, and two 0027 nodes -- and
    -- with the tables gone there is nothing for any of it to describe.
    -- Deleting all of it lets upstream's 0001_squashed_0074 apply as a single
    -- unit against a clean slate, which is the easiest case for a squash
    -- rather than the hardest.
    ------------------------------------------------------------------
    DELETE FROM django_migrations WHERE app = 'proposal';
    GET DIAGNOSTICS rows_deleted = ROW_COUNT;

    RAISE NOTICE '';
    RAISE NOTICE '% tables renamed, % indexes/constraints/sequences with them,'
        ' % migration rows deleted.',
        tables_renamed, objects_renamed, rows_deleted;
    RAISE NOTICE 'Next: deploy the resynced code and migrate. The old data is '
        'in the old_proposal_* tables; nothing has been dropped.';
END $$;

COMMIT;
