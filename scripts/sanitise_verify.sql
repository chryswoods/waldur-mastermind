-- Verify that a sanitised database carries nothing from production.
--
-- Read-only. Run after scripts/sanitise_production_dump.sql, against the same
-- throwaway database. scripts/sanitise_production_dump.sh runs it for you and
-- refuses to write the output dump if anything FAILs.
--
-- The checks assert on SHAPE, not on a list of things to look for: every
-- remaining address must match personN@example_orgM.com and every remaining
-- personal name must match "Person NumberN". A column that the sanitiser does
-- not know about therefore fails these checks rather than passing silently,
-- which is the property that matters as upstream adds columns.
--
--   FAIL  a real leak; do not use the dump
--   WARN  needs a look, not necessarily a leak
--   PASS  nothing found
--
-- Output is counts and check names only, so it is safe to paste anywhere.

\pset border 2
\pset format aligned
\timing off

BEGIN;
SET TRANSACTION READ ONLY;

\echo ''
\echo '=================================================================='
\echo ' Sanitisation verification (read-only)'
\echo '=================================================================='
\echo ''

-- ---------------------------------------------------------------------------
-- The mapping schema must be gone: it is the one place original values were
-- held.
-- ---------------------------------------------------------------------------
\echo '-- mapping schema --------------------------------------------------'
SELECT 'sanitise_schema_removed' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS objects
FROM information_schema.tables WHERE table_schema = 'sanitise';

-- ---------------------------------------------------------------------------
-- Addresses. Anything that is not personN@example_orgM.com is a leak.
-- person0@example_org0.com is the sink the sanitiser folds unrecognised
-- addresses onto; a non-zero count there means a column holds addresses that
-- the harvest step does not read, so add it to that list.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- addresses -------------------------------------------------------'
-- Counting through query_to_xml keeps the whole check inside a read-only
-- transaction: a temp table or a helper function would both be writes.
WITH targets AS MATERIALIZED (
    SELECT tbl, col
    FROM (VALUES
        ('core_user', 'email'),
        ('core_changeemailrequest', 'email'),
        ('users_invitation', 'email'),
        ('structure_customer', 'email'),
        ('structure_affiliatedorganization', 'email'),
        ('marketplace_serviceprovider', 'lead_email'),
        ('marketplace_courseaccount', 'email'),
        ('marketplace_customerserviceaccount', 'email'),
        ('marketplace_projectserviceaccount', 'email'),
        ('proposal_callreviewerpool', 'invited_email'),
        ('logging_emailhook', 'email'),
        ('support_providerhelpdesk', 'notification_email'),
        ('waldur_rancher_keycloakusergroupmembership', 'email'),
        ('structure_customer', 'notification_emails')
    ) AS t(tbl, col)
    WHERE to_regclass('public.' || quote_ident(tbl)) IS NOT NULL
      AND EXISTS (SELECT 1 FROM information_schema.columns c
                  WHERE c.table_schema = 'public' AND c.table_name = t.tbl
                    AND c.column_name = t.col)
), counted AS (
    SELECT tbl || '.' || col AS col_name,
           (xpath('/row/c/text()', query_to_xml(format(
               'SELECT count(*) AS c FROM public.%I
                WHERE nullif(%I, '''') IS NOT NULL AND %I !~ %L',
               tbl, col, col,
               '^person[0-9]+@example_org[0-9]+\.com'
               '(, person[0-9]+@example_org[0-9]+\.com)*$'),
               false, true, '')))[1]::text::bigint AS bad
    FROM targets
)
SELECT 'address_shape' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS offending_columns,
       coalesce(string_agg(col_name || '=' || bad, ', ' ORDER BY col_name), '')
           AS detail
FROM counted WHERE bad > 0;

SELECT 'unmapped_address_sink' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'WARN' END AS status,
       count(*) AS users
FROM public.core_user WHERE email = 'person0@example_org0.com';

-- Free text must not contain an @ that looks like an address either.
SELECT 'no_addresses_in_event_log' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS events
FROM public.logging_event
WHERE message ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
  AND message !~ 'person[0-9]+@example_org[0-9]+\.com';

-- ---------------------------------------------------------------------------
-- Row-level checks.
--
-- Each names a table, the columns it needs, and a predicate that must match
-- NO rows. A check whose table or columns are absent is reported as SKIP
-- rather than failing: this has to run against whatever release the dump came
-- from, and an installation that predates a column cannot be leaking through
-- it. The verifier hard-coding column names is how a run once got all the way
-- through the sanitiser and then died here.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- names and personal attributes ------------------------------------'
WITH checks(name, tbl, cols, pred) AS (
    VALUES
    ('user_names_pseudonymised', 'core_user',
     ARRAY['first_name', 'last_name'],
     $p$first_name <> 'Person' OR last_name !~ '^Number[0-9]+$'$p$),
    ('user_native_names_pseudonymised', 'core_user', ARRAY['native_name'],
     $p$nullif(native_name, '') IS NOT NULL
       AND native_name !~ '^Person Number[0-9]+$'$p$),
    ('usernames_pseudonymised', 'core_user', ARRAY['username'],
     $p$username !~ '^person[0-9]+$'$p$),
    ('slugs_pseudonymised', 'core_user', ARRAY['slug'],
     $p$slug !~ '^person[0-9]+$'$p$),
    ('invitation_names_pseudonymised', 'users_invitation',
     ARRAY['full_name'],
     $p$nullif(full_name, '') IS NOT NULL
       AND full_name !~ '^Person (Number[0-9]+|Redacted)$'$p$),
    ('civil_numbers_cleared', 'core_user', ARRAY['civil_number'],
     $p$civil_number IS NOT NULL$p$),
    ('birth_dates_cleared', 'core_user', ARRAY['birth_date'],
     $p$birth_date IS NOT NULL$p$),
    ('phone_numbers_cleared', 'core_user', ARRAY['phone_number'],
     $p$nullif(phone_number, '') IS NOT NULL$p$),
    ('idp_claim_blobs_cleared', 'core_user', ARRAY['details'],
     $p$details IS NOT NULL AND details::text NOT IN ('{}', 'null')$p$),
    ('passwords_unusable', 'core_user', ARRAY['password'],
     $p$password <> '!'$p$),
    ('search_field_pseudonymised', 'core_user', ARRAY['query_field'],
     $p$nullif(query_field, '') IS NOT NULL
       AND query_field !~ '^Person Number[0-9]+ person[0-9]+$'$p$),
    ('no_addresses_in_event_log', 'logging_event', ARRAY['message'],
     $p$message ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
       AND message !~ 'person[0-9]+@example_org[0-9]+\.com'$p$),
    ('constance_holds_no_endpoints', 'constance_constance',
     ARRAY['key', 'value'],
     $p$(value ~ 'https?://'
         AND value !~ 'localhost|127\.0\.0\.1|example\.(com|org|net)')
        OR value ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'$p$),
    ('constance_deployment_keys_removed', 'constance_constance',
     ARRAY['key'],
     $p$key IN ('HOMEPORT_URL', 'SITE_EMAIL', 'SITE_PHONE', 'TELEMETRY_URL',
                'DOCS_URL', 'SUPPORT_PORTAL_URL', 'K8S_NAMESPACE',
                'DOCKER_SCRIPT_DIR', 'COMMON_FOOTER_TEXT',
                'COMMON_FOOTER_HTML', 'JIRA_WEBHOOK_SHARED_SECRET',
                'ORCID_CLIENT_SECRET', 'SEMANTIC_SCHOLAR_API_KEY',
                'SCIM_API_URL', 'SCIM_API_KEY')
        OR key LIKE 'ATLASSIAN\_%' OR key LIKE 'ZAMMAD\_%'
        OR key LIKE 'SMAX\_%'$p$),
    ('django_site_is_local', 'django_site', ARRAY['domain'],
     $p$domain <> 'localhost:8000'$p$),
    ('service_settings_secrets_cleared', 'structure_servicesettings',
     ARRAY['password', 'token', 'backend_url'],
     $p$nullif(password, '') IS NOT NULL
        OR nullif(token, '') IS NOT NULL
        OR nullif(backend_url, '') IS NOT NULL$p$),
    ('stored_file_contents_dropped', 'media_file', ARRAY['content'],
     $p$octet_length(content) > 0$p$),
    ('unmapped_address_sink', 'core_user', ARRAY['email'],
     $p$email = 'person0@example_org0.com'$p$)
), resolved AS MATERIALIZED (
    SELECT name, tbl, pred,
           to_regclass('public.' || quote_ident(tbl)) IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM unnest(cols) AS c
               WHERE NOT EXISTS (
                   SELECT 1 FROM information_schema.columns ic
                   WHERE ic.table_schema = 'public' AND ic.table_name = tbl
                     AND ic.column_name = c)
           ) AS present
    FROM checks
), counted AS (
    SELECT name, present,
           CASE WHEN present THEN
               (xpath('/row/c/text()', query_to_xml(
                   format('SELECT count(*) AS c FROM public.%I WHERE %s',
                          tbl, pred),
                   false, true, '')))[1]::text::bigint
           END AS bad
    FROM resolved
)
SELECT name AS check,
       CASE
           WHEN NOT present THEN 'SKIP'
           WHEN bad = 0 THEN 'PASS'
           -- The sink is where an address the harvest step does not read ends
           -- up. Safe, but it collapses distinct people onto one pseudonym,
           -- so it is worth a look rather than a failure.
           WHEN name = 'unmapped_address_sink' THEN 'WARN'
           ELSE 'FAIL'
       END AS status,
       coalesce(bad::text, 'n/a') AS rows
FROM counted
ORDER BY (CASE WHEN NOT present THEN 2
               WHEN bad > 0 THEN 0 ELSE 1 END), name;

-- ---------------------------------------------------------------------------
-- Tables that must be empty.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- credentials and telemetry ----------------------------------------'
WITH wanted(name, tbl) AS (
    VALUES
    ('no_identity_providers', 'waldur_auth_social_identityprovider'),
    ('no_sessions', 'django_session'),
    ('no_api_tokens', 'authtoken_token'),
    ('no_personal_access_tokens', 'core_personalaccesstoken'),
    ('no_object_version_history', 'reversion_version'),
    ('no_login_attempt_log', 'axes_accessattempt'),
    ('no_email_hooks', 'logging_emailhook'),
    ('no_database_cache', 'waldur_cache')
), resolved AS MATERIALIZED (
    SELECT name, tbl,
           to_regclass('public.' || quote_ident(tbl)) IS NOT NULL AS present
    FROM wanted
), counted AS (
    SELECT name, present,
           CASE WHEN present THEN
               (xpath('/row/c/text()', query_to_xml(
                   format('SELECT count(*) AS c FROM public.%I', tbl),
                   false, true, '')))[1]::text::bigint
           END AS n
    FROM resolved
)
SELECT name AS check,
       CASE WHEN NOT present THEN 'SKIP'
            WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       coalesce(n::text, 'n/a') AS rows
FROM counted
ORDER BY (CASE WHEN NOT present THEN 2 WHEN n > 0 THEN 0 ELSE 1 END), name;

-- ---------------------------------------------------------------------------
-- Scale, so the copy can be compared against production for realism.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- scale -----------------------------------------------------------'
WITH wanted(metric, tbl) AS (
    VALUES ('people', 'core_user'),
           ('organisations', 'structure_customer'),
           ('projects', 'structure_project'),
           ('resources', 'marketplace_resource'),
           ('events', 'logging_event'),
           ('invoices', 'invoices_invoice')
)
SELECT metric,
       CASE WHEN to_regclass('public.' || quote_ident(tbl)) IS NULL THEN 'n/a'
            ELSE (xpath('/row/c/text()', query_to_xml(
                format('SELECT count(*) AS c FROM public.%I', tbl),
                false, true, '')))[1]::text
       END AS value
FROM wanted
ORDER BY 1;

\echo ''
\echo 'Any FAIL above means the dump must not be used. Fix the sanitiser and'
\echo 're-run the whole pipeline from the original production dump.'
\echo ''

COMMIT;
