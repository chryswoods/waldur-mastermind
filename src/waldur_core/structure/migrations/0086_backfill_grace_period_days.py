"""Give every existing organisation and project a 30-day grace period.

structure/0067 added Customer.grace_period_days and Project.grace_period_days
as nullable columns with no default and no backfill. Before that, the grace
period was a property returning a fixed 30 days, so it applied everywhere; after
it, Project.get_grace_period_days() falls through project -> customer -> 0, and
every pre-existing row is NULL. The effect is not a cosmetic one:

  * Project.is_in_grace_period can never be true, so
    marketplace.terminate_resources_if_project_end_date_has_been_reached never
    pauses anything;
  * a project's effective end date collapses onto its end date, so its
    resources are terminated the day it ends, and a project left with no active
    resources is then scheduled for deletion.

In other words, upgrading past 0067 silently expires everything that was sitting
in its grace period. This restores the 30 days that were in force before.

Both levels are set, not just the organisation, because that is what the
deployment asked for: a project must keep its grace period even if its
organisation's default is later changed or cleared. The consequence is that
changing an organisation's value will NOT move these projects - they now carry
their own. Clear a project's value to put it back under its organisation.

Only NULL rows are touched, so a value set deliberately before this runs is
kept, and re-running changes nothing.

Not reversible in any meaningful sense: NULL and 30 are indistinguishable
afterwards, so a reverse that blanked every 30 would destroy deliberate
settings. The reverse is a no-op.
"""

from django.db import migrations

GRACE_PERIOD_DAYS = 30


def set_default_grace_period(apps, schema_editor):
    Customer = apps.get_model("structure", "Customer")
    Project = apps.get_model("structure", "Project")

    customers = Customer.objects.filter(grace_period_days__isnull=True).update(
        grace_period_days=GRACE_PERIOD_DAYS
    )
    # Project.objects here is the historical model's default manager, which has
    # no soft-delete filtering, so terminated projects are covered too - they
    # are exactly the ones this is meant to protect.
    projects = Project.objects.filter(grace_period_days__isnull=True).update(
        grace_period_days=GRACE_PERIOD_DAYS
    )

    if customers or projects:
        print(
            f"\n  grace period set to {GRACE_PERIOD_DAYS} days on "
            f"{customers} organisations and {projects} projects"
        )


class Migration(migrations.Migration):
    dependencies = [
        ("structure", "0085_remove_project_display_credit_reports"),
    ]

    operations = [
        migrations.RunPython(
            set_default_grace_period,
            migrations.RunPython.noop,
            elidable=False,
        ),
    ]
