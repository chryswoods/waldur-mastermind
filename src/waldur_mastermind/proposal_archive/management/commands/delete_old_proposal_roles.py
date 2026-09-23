"""Delete the fork's proposal roles, so upstream's replay can create its own.

``proposal.0001_squashed_0074`` -> ``0040_migrate_default_project_role`` does
``Role.objects.get(name="PROPOSAL.MANAGER", content_type=proposal_ct)`` and dies
with ``MultipleObjectsReturned`` when the fork's role is still there.  Roles live
in ``permissions_role``, which the reconciliation script does not touch, so on a
site that ran the fork's proposal app they survive and block the replay.

Deleting a role cascades its ``UserRole`` rows away, and those rows are the only
record of who managed, co-led and reviewed each proposal.  So this command
refuses to run until ``archive_old_proposals`` has captured them.
"""

from django.contrib.contenttypes.models import ContentType
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from waldur_core.permissions import models as permission_models
from waldur_mastermind.proposal_archive import models


class Command(BaseCommand):
    help = "Delete the fork's proposal-scoped roles ahead of the upstream replay."

    def add_arguments(self, parser):
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="Report what would be deleted, and delete nothing.",
        )
        parser.add_argument(
            "--force",
            action="store_true",
            help=(
                "Delete even though no memberships have been archived. Only for "
                "a site that never had any -- the assignments are not "
                "recoverable afterwards."
            ),
        )

    def handle(self, *args, **options):
        content_types = ContentType.objects.filter(app_label="proposal")
        if not content_types.exists():
            self.stdout.write("No proposal content types: nothing to delete.")
            return

        roles = permission_models.Role.objects.filter(content_type__in=content_types)
        if not roles.exists():
            self.stdout.write("No proposal-scoped roles: nothing to delete.")
            return

        assignments = permission_models.UserRole.objects.filter(role__in=roles)
        archived = models.ArchivedMembership.objects.count()

        self.stdout.write("Roles to delete:")
        for role in roles.order_by("name"):
            count = assignments.filter(role=role).count()
            system = "system" if role.is_system_role else "custom"
            self.stdout.write(
                f"  {role.name:<30} {role.content_type.model:<26} {system:<7} {count}"
            )
        total = assignments.count()
        self.stdout.write(f"\nAssignments that would be cascaded away: {total}")
        self.stdout.write(f"Memberships already archived:             {archived}")

        if total and not archived and not options["force"]:
            raise CommandError(
                "Refusing to delete: these roles carry assignments and the "
                "archive is empty. Run `waldur archive_old_proposals` first, or "
                "pass --force if losing them is intended."
            )

        if options["dry_run"]:
            self.stdout.write(self.style.WARNING("\nDry run: nothing deleted."))
            return

        with transaction.atomic():
            assignments.delete()
            deleted, _ = roles.delete()
        # The manager caches roles by name; a stale entry would hand the replay
        # a deleted row.
        permission_models.Role.objects.clear_cache()
        self.stdout.write(
            self.style.SUCCESS(
                f"\nDeleted {total} assignments and {deleted} role records."
            )
        )
