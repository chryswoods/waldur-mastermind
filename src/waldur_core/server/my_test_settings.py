# Local test settings: use a local PostgreSQL instance instead of the "db" host
# used by the containerised test setup.
from waldur_core.server.test_settings import *  # noqa: F401,F403

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "HOST": "127.0.0.1",
        "PORT": "5432",
        "NAME": "test_postgres",
        "USER": "postgres",
        "PASSWORD": "postgres",
    },
}

# Building this test database takes ~15 minutes (700-odd migrations), so pass
# --reuse-db to keep it between runs; --create-db without it drops the database
# at teardown and the next run pays the full cost again.
