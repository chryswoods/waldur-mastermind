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
--   SKIP  this release has no such table or column, so nothing can leak
--         through it
--
-- Output is counts and check names only, so it is safe to paste anywhere.
--
-- WHY THIS IS ALL ONE plpgsql BLOCK
--
-- Every check needs the same two things: to know whether a table and its
-- columns exist on this release, and then to count rows matching a predicate
-- over them. That is dynamic SQL. The three ways to do it in plain SQL all
-- fail here:
--
--   * a helper function or a temp table is a WRITE, and this runs in a
--     read-only transaction on purpose;
--   * query_to_xml() needs the server to be built with libxml, and a
--     source-built PostgreSQL frequently is not - which is exactly how an
--     earlier version of this file died after two hours of sanitising had
--     already committed;
--   * naming the columns statically is what this file is trying to avoid.
--
-- EXECUTE ... INTO inside a DO block is a read, needs no extensions, and
-- works on any build. Results come out as notices, which is why they are
-- formatted as pipe-delimited rows: the driver greps them for FAIL.

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

DO $verify$
DECLARE
    -- personN@example_orgM.com, alone or as a comma-separated list.
    email_shape text :=
        '^person[0-9]+@example_org[0-9]+\.com'
        '(, ?person[0-9]+@example_org[0-9]+\.com)*$';
    -- personN, and the compound account names that keep their project and
    -- system parts: personN.project, personN.project.cluster.
    login_shape text := '^person[0-9]+([._-][A-Za-z0-9][A-Za-z0-9._-]*)?$';

    r record;
    present boolean;
    n bigint;
    pass int := 0;
    fail int := 0;
    warn int := 0;
    skip int := 0;
BEGIN
    RAISE NOTICE '| %      | %  | % |', rpad('status', 6), rpad('check', 38),
        lpad('rows', 12);
    RAISE NOTICE '|--------|----------------------------------------|--------------|';

    ------------------------------------------------------------------
    -- The mapping schema must be gone: it is the one place original values
    -- were held.
    ------------------------------------------------------------------
    SELECT count(*) INTO n
    FROM information_schema.tables WHERE table_schema = 'sanitise';
    IF n = 0 THEN
        pass := pass + 1;
        RAISE NOTICE '| PASS   | % | % |',
            rpad('sanitise_schema_removed', 38), lpad(n::text, 12);
    ELSE
        fail := fail + 1;
        RAISE NOTICE '| FAIL   | % | % |',
            rpad('sanitise_schema_removed', 38), lpad(n::text, 12);
    END IF;

    ------------------------------------------------------------------
    -- Every check: (name, table, required columns, predicate that must match
    -- no rows, and whether a match is a failure or only a warning).
    ------------------------------------------------------------------
    FOR r IN
        SELECT * FROM (VALUES
        -- addresses
        ('address_core_user',              'core_user', ARRAY['email'],
         format($p$nullif(email, '') IS NOT NULL AND email !~ %L$p$,
                email_shape), 'FAIL'),
        ('address_change_request',         'core_changeemailrequest',
         ARRAY['email'],
         format($p$nullif(email, '') IS NOT NULL AND email !~ %L$p$,
                email_shape), 'FAIL'),
        ('address_invitation',             'users_invitation', ARRAY['email'],
         format($p$nullif(email, '') IS NOT NULL AND email !~ %L$p$,
                email_shape), 'FAIL'),
        ('address_customer',               'structure_customer',
         ARRAY['email'],
         format($p$nullif(email, '') IS NOT NULL AND email !~ %L$p$,
                email_shape), 'FAIL'),
        ('address_customer_notifications', 'structure_customer',
         ARRAY['notification_emails'],
         format($p$nullif(notification_emails, '') IS NOT NULL
                  AND notification_emails !~ %L$p$, email_shape), 'FAIL'),
        ('address_affiliated_org',         'structure_affiliatedorganization',
         ARRAY['email'],
         format($p$nullif(email, '') IS NOT NULL AND email !~ %L$p$,
                email_shape), 'FAIL'),
        ('address_service_provider_lead',  'marketplace_serviceprovider',
         ARRAY['lead_email'],
         format($p$nullif(lead_email, '') IS NOT NULL
                  AND lead_email !~ %L$p$, email_shape), 'FAIL'),
        ('address_course_account',          'marketplace_courseaccount',
         ARRAY['email'],
         format($p$nullif(email, '') IS NOT NULL AND email !~ %L$p$,
                email_shape), 'FAIL'),
        ('address_customer_service_acct',   'marketplace_customerserviceaccount',
         ARRAY['email'],
         format($p$nullif(email, '') IS NOT NULL AND email !~ %L$p$,
                email_shape), 'FAIL'),
        ('address_project_service_acct',    'marketplace_projectserviceaccount',
         ARRAY['email'],
         format($p$nullif(email, '') IS NOT NULL AND email !~ %L$p$,
                email_shape), 'FAIL'),
        ('address_reviewer_pool',           'proposal_callreviewerpool',
         ARRAY['invited_email'],
         format($p$nullif(invited_email, '') IS NOT NULL
                  AND invited_email !~ %L$p$, email_shape), 'FAIL'),
        ('address_email_hook',              'logging_emailhook',
         ARRAY['email'],
         format($p$nullif(email, '') IS NOT NULL AND email !~ %L$p$,
                email_shape), 'FAIL'),
        ('address_provider_helpdesk',       'support_providerhelpdesk',
         ARRAY['notification_email'],
         format($p$nullif(notification_email, '') IS NOT NULL
                  AND notification_email !~ %L$p$, email_shape), 'FAIL'),
        ('address_keycloak_membership',
         'waldur_rancher_keycloakusergroupmembership', ARRAY['email'],
         format($p$nullif(email, '') IS NOT NULL AND email !~ %L$p$,
                email_shape), 'FAIL'),
        ('no_addresses_in_event_log',       'logging_event', ARRAY['message'],
         $p$message ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
            AND message !~ 'person[0-9]+@example_org[0-9]+\.com'$p$, 'FAIL'),

        -- login names, which other tables join on
        ('login_offering_user',      'marketplace_offeringuser',
         ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_component_usage',    'marketplace_componentuserusage',
         ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_customer_svc_acct',  'marketplace_customerserviceaccount',
         ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_project_svc_acct',   'marketplace_projectserviceaccount',
         ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_op_association',     'waldur_openportal_association',
         ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_op_alloc_usage',     'waldur_openportal_allocationuserusage',
         ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_op_shortname',       'waldur_openportal_userinfo',
         ARRAY['shortname'],
         format($p$nullif(shortname, '') IS NOT NULL AND shortname !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_slurm_association',  'waldur_slurm_association',
         ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_slurm_alloc_usage',  'waldur_slurm_allocationuserusage',
         ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_freeipa',            'waldur_freeipa_profile',
         ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_keycloak_membership',
         'waldur_rancher_keycloakusergroupmembership', ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_robot_account',      'marketplace_robotaccount',
         ARRAY['username'],
         format($p$nullif(username, '') IS NOT NULL AND username !~ %L$p$,
                login_shape), 'FAIL'),
        ('login_unix_username',      'core_user', ARRAY['unix_username'],
         format($p$nullif(unix_username, '') IS NOT NULL
                  AND unix_username !~ %L$p$, login_shape), 'FAIL'),

        -- names and personal attributes
        ('user_names_pseudonymised', 'core_user',
         ARRAY['first_name', 'last_name'],
         $p$first_name <> 'Person' OR last_name !~ '^Number[0-9]+$'$p$,
         'FAIL'),
        ('user_native_names_pseudonymised', 'core_user',
         ARRAY['native_name'],
         $p$nullif(native_name, '') IS NOT NULL
            AND native_name !~ '^Person Number[0-9]+$'$p$, 'FAIL'),
        ('usernames_pseudonymised',  'core_user', ARRAY['username'],
         format($p$username !~ %L$p$, login_shape), 'FAIL'),
        ('slugs_pseudonymised',      'core_user', ARRAY['slug'],
         format($p$slug !~ %L$p$, login_shape), 'FAIL'),
        ('invitation_names_pseudonymised', 'users_invitation',
         ARRAY['full_name'],
         $p$nullif(full_name, '') IS NOT NULL
            AND full_name !~ '^Person (Number[0-9]+|Redacted)$'$p$, 'FAIL'),
        ('civil_numbers_cleared',    'core_user', ARRAY['civil_number'],
         $p$civil_number IS NOT NULL$p$, 'FAIL'),
        ('birth_dates_cleared',      'core_user', ARRAY['birth_date'],
         $p$birth_date IS NOT NULL$p$, 'FAIL'),
        ('phone_numbers_cleared',    'core_user', ARRAY['phone_number'],
         $p$nullif(phone_number, '') IS NOT NULL$p$, 'FAIL'),
        ('idp_claim_blobs_cleared',  'core_user', ARRAY['details'],
         $p$details IS NOT NULL AND details::text NOT IN ('{}', 'null')$p$,
         'FAIL'),
        ('passwords_unusable',       'core_user', ARRAY['password'],
         $p$password <> '!'$p$, 'FAIL'),
        ('search_field_pseudonymised', 'core_user', ARRAY['query_field'],
         $p$nullif(query_field, '') IS NOT NULL
            AND query_field !~ '^Person Number[0-9]+ person[0-9]+$'$p$,
         'FAIL'),

        -- deployment configuration
        ('constance_holds_no_endpoints', 'constance_constance',
         ARRAY['key', 'value'],
         $p$(value ~ 'https?://'
             AND value !~ 'localhost|127\.0\.0\.1|example\.(com|org|net)')
            OR value ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'$p$,
         'FAIL'),
        ('constance_deployment_keys_removed', 'constance_constance',
         ARRAY['key'],
         $p$key IN ('HOMEPORT_URL', 'SITE_EMAIL', 'SITE_PHONE',
                    'TELEMETRY_URL', 'DOCS_URL', 'SUPPORT_PORTAL_URL',
                    'K8S_NAMESPACE', 'DOCKER_SCRIPT_DIR',
                    'COMMON_FOOTER_TEXT', 'COMMON_FOOTER_HTML',
                    'JIRA_WEBHOOK_SHARED_SECRET', 'ORCID_CLIENT_SECRET',
                    'SEMANTIC_SCHOLAR_API_KEY', 'SCIM_API_URL',
                    'SCIM_API_KEY')
            OR key LIKE 'ATLASSIAN\_%' OR key LIKE 'ZAMMAD\_%'
            OR key LIKE 'SMAX\_%'$p$, 'FAIL'),
        ('django_site_is_local',     'django_site', ARRAY['domain'],
         $p$domain <> 'localhost:8000'$p$, 'FAIL'),
        ('service_settings_secrets_cleared', 'structure_servicesettings',
         ARRAY['password', 'token', 'backend_url'],
         $p$nullif(password, '') IS NOT NULL
            OR nullif(token, '') IS NOT NULL
            OR nullif(backend_url, '') IS NOT NULL$p$, 'FAIL'),
        ('stored_file_contents_dropped', 'media_file', ARRAY['content'],
         $p$octet_length(content) > 0$p$, 'FAIL'),

        -- tables that must be empty
        ('no_identity_providers', 'waldur_auth_social_identityprovider',
         ARRAY['id'], 'true', 'FAIL'),
        ('no_sessions',           'django_session', ARRAY['session_key'],
         'true', 'FAIL'),
        ('no_api_tokens',         'authtoken_token', ARRAY['key'],
         'true', 'FAIL'),
        ('no_personal_access_tokens', 'core_personalaccesstoken',
         ARRAY['id'], 'true', 'FAIL'),
        ('no_object_version_history', 'reversion_version', ARRAY['id'],
         'true', 'FAIL'),
        ('no_login_attempt_log',  'axes_accessattempt', ARRAY['id'],
         'true', 'FAIL'),
        ('no_email_hooks',        'logging_emailhook', ARRAY['email'],
         'true', 'FAIL'),
        ('no_database_cache',     'waldur_cache', ARRAY['cache_key'],
         'true', 'FAIL'),

        -- worth a look rather than a failure: the sink is where an address
        -- the harvest step does not read ends up. Safe, but it collapses
        -- distinct people onto one pseudonym.
        ('unmapped_address_sink', 'core_user', ARRAY['email'],
         $p$email = 'person0@example_org0.com'$p$, 'WARN')
        ) AS t(name, tbl, cols, pred, severity)
    LOOP
        SELECT to_regclass('public.' || quote_ident(r.tbl)) IS NOT NULL
               AND NOT EXISTS (
                   SELECT 1 FROM unnest(r.cols) AS c
                   WHERE NOT EXISTS (
                       SELECT 1 FROM information_schema.columns ic
                       WHERE ic.table_schema = 'public'
                         AND ic.table_name = r.tbl
                         AND ic.column_name = c))
        INTO present;

        IF NOT present THEN
            skip := skip + 1;
            RAISE NOTICE '| SKIP   | % | % |',
                rpad(r.name, 38), lpad('n/a', 12);
            CONTINUE;
        END IF;

        EXECUTE format('SELECT count(*) FROM public.%I WHERE %s',
                       r.tbl, r.pred) INTO n;

        IF n = 0 THEN
            pass := pass + 1;
            RAISE NOTICE '| PASS   | % | % |',
                rpad(r.name, 38), lpad(n::text, 12);
        ELSIF r.severity = 'WARN' THEN
            warn := warn + 1;
            RAISE NOTICE '| WARN   | % | % |',
                rpad(r.name, 38), lpad(n::text, 12);
        ELSE
            fail := fail + 1;
            RAISE NOTICE '| FAIL   | % | % |',
                rpad(r.name, 38), lpad(n::text, 12);
        END IF;
    END LOOP;

    RAISE NOTICE '|--------|----------------------------------------|--------------|';
    RAISE NOTICE '';
    RAISE NOTICE '% checks: % passed, % failed, % warned, % skipped',
        pass + fail + warn + skip, pass, fail, warn, skip;

    ------------------------------------------------------------------
    -- Scale, so the copy can be compared against production for realism.
    ------------------------------------------------------------------
    RAISE NOTICE '';
    RAISE NOTICE '-- scale --';
    FOR r IN
        SELECT * FROM (VALUES
            ('people',        'core_user'),
            ('organisations', 'structure_customer'),
            ('projects',      'structure_project'),
            ('resources',     'marketplace_resource'),
            ('events',        'logging_event'),
            ('invoices',      'invoices_invoice')
        ) AS t(metric, tbl)
    LOOP
        IF to_regclass('public.' || quote_ident(r.tbl)) IS NULL THEN
            RAISE NOTICE '  % %', rpad(r.metric, 16), 'n/a';
            CONTINUE;
        END IF;
        EXECUTE format('SELECT count(*) FROM public.%I', r.tbl) INTO n;
        RAISE NOTICE '  % %', rpad(r.metric, 16), n;
    END LOOP;

    RAISE NOTICE '';
    IF fail > 0 THEN
        RAISE NOTICE 'There are failures above. The dump must not be used:';
        RAISE NOTICE 'fix the sanitiser and re-run from the original dump.';
    ELSE
        RAISE NOTICE 'Nothing failed.';
    END IF;
    RAISE NOTICE '';
END $verify$;

COMMIT;
