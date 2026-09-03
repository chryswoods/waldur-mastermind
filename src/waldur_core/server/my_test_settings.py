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
