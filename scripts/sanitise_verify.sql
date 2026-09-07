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
-- Names.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- names -----------------------------------------------------------'
SELECT 'user_names_pseudonymised' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS users
FROM public.core_user
WHERE first_name <> 'Person' OR last_name !~ '^Number[0-9]+$';

SELECT 'user_native_names_pseudonymised' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS users
FROM public.core_user
WHERE nullif(native_name, '') IS NOT NULL
  AND native_name !~ '^Person Number[0-9]+$';

SELECT 'usernames_pseudonymised' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS users
FROM public.core_user WHERE username !~ '^person[0-9]+$';

SELECT 'slugs_pseudonymised' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS users
FROM public.core_user WHERE slug !~ '^person[0-9]+$';

SELECT 'invitation_names_pseudonymised' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS invitations
FROM public.users_invitation
WHERE nullif(full_name, '') IS NOT NULL
  AND full_name !~ '^Person (Number[0-9]+|Redacted)$';

-- Every login-name column that other tables join on.
\echo ''
\echo '-- login names across tables ---------------------------------------'
WITH targets AS MATERIALIZED (
    SELECT tbl, col
    FROM (VALUES
        ('marketplace_offeringuser', 'username'),
        ('marketplace_componentuserusage', 'username'),
        ('marketplace_customerserviceaccount', 'username'),
        ('marketplace_projectserviceaccount', 'username'),
        ('waldur_openportal_association', 'username'),
        ('waldur_openportal_allocationuserusage', 'username'),
        ('waldur_openportal_userinfo', 'shortname'),
        ('waldur_slurm_association', 'username'),
        ('waldur_slurm_allocationuserusage', 'username'),
        ('waldur_freeipa_profile', 'username'),
        ('waldur_rancher_keycloakusergroupmembership', 'username'),
        ('marketplace_robotaccount', 'username'),
        ('core_user', 'unix_username')
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
               -- Compound account names keep the project and system parts:
               -- personN, personN.project, personN.project.cluster.
               '^person[0-9]+([._-][A-Za-z0-9][A-Za-z0-9._-]*)?$'),
               false, true, '')))[1]::text::bigint AS bad
    FROM targets
)
SELECT 'login_name_shape' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS offending_columns,
       coalesce(string_agg(col_name || '=' || bad, ', ' ORDER BY col_name), '')
           AS detail
FROM counted WHERE bad > 0;

-- ---------------------------------------------------------------------------
-- Other personal attributes that must be empty.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- other personal attributes ---------------------------------------'
SELECT 'civil_numbers_cleared' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.core_user WHERE civil_number IS NOT NULL;

SELECT 'birth_dates_cleared' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.core_user WHERE birth_date IS NOT NULL;

SELECT 'phone_numbers_cleared' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.core_user WHERE nullif(phone_number, '') IS NOT NULL;

SELECT 'idp_claim_blobs_cleared' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.core_user
WHERE details IS NOT NULL AND details::text NOT IN ('{}', 'null');

SELECT 'passwords_unusable' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.core_user WHERE password <> '!';

SELECT 'search_field_pseudonymised' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.core_user
WHERE nullif(query_field, '') IS NOT NULL
  AND query_field !~ '^Person Number[0-9]+ person[0-9]+$';

-- ---------------------------------------------------------------------------
-- Deployment configuration and credentials.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- deployment configuration ----------------------------------------'
SELECT 'no_identity_providers' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.waldur_auth_social_identityprovider;

-- Constance stores its values as plain JSON, so they can be read here rather
-- than trusted. Checking the VALUES rather than the key names is what catches
-- a setting nobody thought about: a key name can be innocuous while the value
-- is a production endpoint.
SELECT 'constance_holds_no_endpoints' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows,
       coalesce(string_agg(key, ', ' ORDER BY key), '') AS detail
FROM public.constance_constance
WHERE (value ~ 'https?://'
       AND value !~ 'localhost|127\.0\.0\.1|example\.(com|org|net)')
   OR value ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}';

-- A cross-check on the keys that must not survive whatever their value.
SELECT 'constance_deployment_keys_removed' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows,
       coalesce(string_agg(key, ', ' ORDER BY key), '') AS detail
FROM public.constance_constance
WHERE key IN ('HOMEPORT_URL', 'SITE_EMAIL', 'SITE_PHONE', 'TELEMETRY_URL',
              'DOCS_URL', 'SUPPORT_PORTAL_URL', 'K8S_NAMESPACE',
              'DOCKER_SCRIPT_DIR', 'COMMON_FOOTER_TEXT', 'COMMON_FOOTER_HTML',
              'JIRA_WEBHOOK_SHARED_SECRET', 'ORCID_CLIENT_SECRET',
              'SEMANTIC_SCHOLAR_API_KEY', 'SCIM_API_URL', 'SCIM_API_KEY')
   OR key LIKE 'ATLASSIAN\_%' OR key LIKE 'ZAMMAD\_%'
   OR key LIKE 'SMAX\_%';

SELECT 'django_site_is_local' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.django_site WHERE domain <> 'localhost:8000';

SELECT 'no_sessions' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.django_session;

SELECT 'no_api_tokens' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.authtoken_token;

SELECT 'no_object_version_history' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.reversion_version;

SELECT 'service_settings_secrets_cleared' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.structure_servicesettings
WHERE nullif(password, '') IS NOT NULL
   OR nullif(token, '') IS NOT NULL
   OR nullif(backend_url, '') IS NOT NULL;

SELECT 'stored_file_contents_dropped' AS check,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       count(*) AS rows
FROM public.media_file WHERE octet_length(content) > 0;

-- ---------------------------------------------------------------------------
-- Scale, so the copy can be compared against production for realism.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- scale -----------------------------------------------------------'
SELECT 'people' AS metric, count(*) AS value FROM public.core_user
UNION ALL SELECT 'domains',
    count(DISTINCT split_part(email, '@', 2)) FROM public.core_user
UNION ALL SELECT 'organisations', count(*) FROM public.structure_customer
UNION ALL SELECT 'projects', count(*) FROM public.structure_project
UNION ALL SELECT 'resources', count(*) FROM public.marketplace_resource
UNION ALL SELECT 'events', count(*) FROM public.logging_event
UNION ALL SELECT 'invoices', count(*) FROM public.invoices_invoice
ORDER BY 1;

\echo ''
\echo 'Any FAIL above means the dump must not be used. Fix the sanitiser and'
\echo 're-run the whole pipeline from the original production dump.'
\echo ''

COMMIT;
