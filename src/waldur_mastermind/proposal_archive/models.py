"""Read-only archive of the fork's own proposal app.

The awards site ran a fork-local proposal app that the upstream resync deleted
wholesale.  Its data is not migrated forward -- it is copied into these models
and the original tables are renamed aside (see
``docs/guides/awards-site-upgrade-plan.md``).

Two rules shape everything here:

* **Nothing points at live data.**  Every reference out of the archive is
  denormalised to a UUID plus a display value, so an archived proposal can
  neither block the deletion of the user who wrote it nor be cascaded away with
  a customer years from now.
* **Nothing is lost.**  Each row carries a ``payload`` holding the original
  record verbatim, including columns not modelled explicitly.

The original UUIDs are preserved, so old ``/proposals/<uuid>`` links can still
be resolved.
"""

from django.db import models
from django.utils.translation import gettext_lazy as _
from model_utils.models import TimeStampedModel

from waldur_core.core import models as core_models


class ArchiveBase(TimeStampedModel, core_models.UuidMixin):
    """Common shape of every archived record.

    ``created``/``modified`` come from ``TimeStampedModel`` but are copied from
    the source row rather than set on insert, so the archive keeps the original
    timeline.  Both are therefore writable here, unlike on a live model.
    """

    payload = models.JSONField(
        default=dict,
        blank=True,
        help_text=_("The original database row, verbatim."),
    )

    class Meta:
        abstract = True


class ArchivedCall(ArchiveBase):
    """A call for proposals, with its managing organisation denormalised onto it."""

    name = models.CharField(max_length=150)
    slug = models.SlugField(blank=True)
    description = models.CharField(max_length=2000, blank=True)
    state = models.CharField(max_length=10, blank=True)
    external_url = models.URLField(blank=True, null=True)

    reviewer_identity_visible_to_submitters = models.BooleanField(default=False)
    reviews_visible_to_submitters = models.BooleanField(default=True)
    fixed_duration_in_days = models.PositiveIntegerField(null=True, blank=True)

    # CallManagingOrganisation, flattened.  Kept as the organisation's own uuid
    # *and* the customer's, because §4.2 grants access by customer.
    manager_uuid = models.UUIDField(null=True, blank=True)
    customer_uuid = models.UUIDField(null=True, blank=True, db_index=True)
    customer_name = models.CharField(max_length=150, blank=True)

    created_by_uuid = models.UUIDField(null=True, blank=True)
    created_by_username = models.CharField(max_length=128, blank=True)
    created_by_full_name = models.CharField(max_length=200, blank=True)

    class Meta:
        verbose_name = _("Archived call")
        ordering = ["-created"]

    def __str__(self):
        return self.name


class ArchivedRound(ArchiveBase):
    """A submission round within an archived call."""

    call = models.ForeignKey(
        ArchivedCall, on_delete=models.CASCADE, related_name="rounds"
    )
    slug = models.SlugField(blank=True)

    start_time = models.DateTimeField(null=True, blank=True)
    cutoff_time = models.DateTimeField(null=True, blank=True)
    review_strategy = models.CharField(max_length=20, blank=True)
    deciding_entity = models.CharField(max_length=20, blank=True)
    allocation_time = models.CharField(max_length=20, blank=True)
    allocation_date = models.DateTimeField(null=True, blank=True)
    review_duration_in_days = models.PositiveIntegerField(null=True, blank=True)
    fixed_review_end_date = models.DateTimeField(null=True, blank=True)
    minimum_number_of_reviewers = models.PositiveIntegerField(null=True, blank=True)
    minimal_average_scoring = models.DecimalField(
        max_digits=6, decimal_places=2, null=True, blank=True
    )
    minimum_required_uploads = models.PositiveIntegerField(null=True, blank=True)

    class Meta:
        verbose_name = _("Archived round")
        ordering = ["-start_time"]

    def __str__(self):
        return f"{self.call} / {self.slug or self.uuid}"


class ArchivedProposal(ArchiveBase):
    """A submitted proposal.

    ``call`` duplicates ``round.call`` so that the permission filter of §4.2 --
    which is by call -- does not need a join through rounds on every query.
    """

    round = models.ForeignKey(
        ArchivedRound, on_delete=models.CASCADE, related_name="proposals"
    )
    call = models.ForeignKey(
        ArchivedCall, on_delete=models.CASCADE, related_name="proposals"
    )

    name = models.CharField(max_length=150)
    slug = models.SlugField(blank=True)
    description = models.CharField(max_length=2000, blank=True)
    state = models.CharField(max_length=10, blank=True)

    duration_in_days = models.PositiveIntegerField(null=True, blank=True)
    project_summary = models.TextField(blank=True)
    project_duration = models.PositiveIntegerField(null=True, blank=True)
    project_is_confidential = models.BooleanField(default=False)
    project_has_civilian_purpose = models.BooleanField(default=False)
    oecd_fos_2007_code = models.CharField(max_length=80, blank=True)

    allocation_comment = models.CharField(max_length=150, blank=True, null=True)
    submitted_at = models.DateTimeField(null=True, blank=True)
    notes = models.JSONField(
        default=list,
        blank=True,
        help_text=_("Call-manager notes: {timestamp, author, text}."),
    )

    project_uuid = models.UUIDField(null=True, blank=True, db_index=True)
    project_name = models.CharField(max_length=150, blank=True)
    created_by_uuid = models.UUIDField(null=True, blank=True, db_index=True)
    created_by_username = models.CharField(max_length=128, blank=True)
    created_by_full_name = models.CharField(max_length=200, blank=True)
    approved_by_uuid = models.UUIDField(null=True, blank=True)
    approved_by_username = models.CharField(max_length=128, blank=True)

    class Meta:
        verbose_name = _("Archived proposal")
        ordering = ["-created"]

    def __str__(self):
        return self.name


class ArchivedRequestedResource(ArchiveBase):
    """A resource requested by an archived proposal.

    ``RequestedOffering`` and ``CallResourceTemplate`` are flattened into this,
    since neither is interesting on its own once the call is closed.
    """

    proposal = models.ForeignKey(
        ArchivedProposal, on_delete=models.CASCADE, related_name="requested_resources"
    )

    offering_uuid = models.UUIDField(null=True, blank=True)
    offering_name = models.CharField(max_length=150, blank=True)
    plan_uuid = models.UUIDField(null=True, blank=True)
    plan_name = models.CharField(max_length=150, blank=True)
    template_name = models.CharField(max_length=255, blank=True)

    attributes = models.JSONField(default=dict, blank=True)
    limits = models.JSONField(default=dict, blank=True)
    resource_uuid = models.UUIDField(null=True, blank=True)

    created_by_uuid = models.UUIDField(null=True, blank=True)
    created_by_username = models.CharField(max_length=128, blank=True)

    class Meta:
        verbose_name = _("Archived requested resource")
        ordering = ["created"]

    def __str__(self):
        return f"{self.offering_name or self.uuid}"


class ArchivedReview(ArchiveBase):
    """A review of an archived proposal.

    Reviewer identity and comment text are administrator-only in the archive,
    whatever the original call's visibility flags said -- see §4.2 of the plan.
    ``ReviewComment`` was never used in production (zero rows), so its messages
    are folded into ``comments`` rather than given a model.
    """

    proposal = models.ForeignKey(
        ArchivedProposal, on_delete=models.CASCADE, related_name="reviews"
    )

    state = models.CharField(max_length=10, blank=True)
    summary_score = models.PositiveSmallIntegerField(default=0)
    summary_public_comment = models.TextField(blank=True)
    summary_private_comment = models.TextField(blank=True)

    comment_project_title = models.CharField(max_length=255, blank=True, null=True)
    comment_project_summary = models.CharField(max_length=255, blank=True, null=True)
    comment_project_description = models.CharField(
        max_length=255, blank=True, null=True
    )
    comment_project_duration = models.CharField(max_length=255, blank=True, null=True)
    comment_project_is_confidential = models.CharField(
        max_length=255, blank=True, null=True
    )
    comment_project_has_civilian_purpose = models.CharField(
        max_length=255, blank=True, null=True
    )
    comment_project_supporting_documentation = models.CharField(
        max_length=255, blank=True, null=True
    )
    comment_resource_requests = models.CharField(max_length=255, blank=True, null=True)
    comment_team = models.CharField(max_length=255, blank=True, null=True)

    reviewer_uuid = models.UUIDField(null=True, blank=True)
    reviewer_username = models.CharField(max_length=128, blank=True)
    reviewer_full_name = models.CharField(max_length=200, blank=True)

    comments = models.JSONField(
        default=list,
        blank=True,
        help_text=_("Review conversation: {created, message}."),
    )

    class Meta:
        verbose_name = _("Archived review")
        ordering = ["created"]

    def __str__(self):
        return f"Review of {self.proposal_id}"


class ArchivedCallDocument(ArchiveBase):
    """A file attached to an archived call.

    The prefix differs from the live app's ``call_documents`` on purpose:
    ``access.register()`` raises on a duplicate prefix, and if the archive
    shared it the live rule would answer for these files and deny every one.
    The copy renames ``media_file.name`` accordingly; no bytes move.
    """

    call = models.ForeignKey(
        ArchivedCall, on_delete=models.CASCADE, related_name="documents"
    )
    description = models.CharField(max_length=2000, blank=True)
    file = models.FileField(upload_to="archived_call_documents", blank=True, null=True)

    class Meta:
        verbose_name = _("Archived call document")
        ordering = ["created"]


class ArchivedProposalDocument(ArchiveBase):
    """Supporting documentation uploaded with an archived proposal.

    Separate prefix, for the same reason as ``ArchivedCallDocument``.
    """

    proposal = models.ForeignKey(
        ArchivedProposal, on_delete=models.CASCADE, related_name="documents"
    )
    file = models.FileField(
        upload_to="archived_proposal_documentation", blank=True, null=True
    )

    class Meta:
        verbose_name = _("Archived proposal document")
        ordering = ["created"]


class ArchivedMembership(ArchiveBase):
    """Who held which role on an archived call or proposal.

    Deleting the fork's proposal roles cascades their ``UserRole`` rows away,
    and those rows are the only record of who managed, co-led and reviewed each
    proposal.  They are captured here first.

    Two of the seven roles were custom rather than system roles, so the role is
    carried as text: there is no enum to map it back to.
    """

    class Scopes:
        CALL = "call"
        PROPOSAL = "proposal"
        ORGANISATION = "organisation"

        CHOICES = (
            (CALL, "Call"),
            (PROPOSAL, "Proposal"),
            (ORGANISATION, "Call managing organisation"),
        )

    scope_kind = models.CharField(max_length=20, choices=Scopes.CHOICES, db_index=True)
    call = models.ForeignKey(
        ArchivedCall,
        on_delete=models.CASCADE,
        related_name="memberships",
        null=True,
        blank=True,
    )
    proposal = models.ForeignKey(
        ArchivedProposal,
        on_delete=models.CASCADE,
        related_name="memberships",
        null=True,
        blank=True,
    )

    # Organisation-scoped grants (CUSTOMER.CALL_ORGANIZER, "Call Reader") have
    # no archived object to hang off -- the managing organisation is flattened
    # onto each call -- so they carry the customer directly.
    organisation_customer_uuid = models.UUIDField(null=True, blank=True)
    organisation_customer_name = models.CharField(max_length=150, blank=True)

    role_name = models.CharField(max_length=150, db_index=True)
    role_description = models.CharField(max_length=255, blank=True)

    user_uuid = models.UUIDField(null=True, blank=True, db_index=True)
    user_username = models.CharField(max_length=128, blank=True)
    user_full_name = models.CharField(max_length=200, blank=True)

    is_active = models.BooleanField(null=True, default=True)
    expiration_time = models.DateTimeField(null=True, blank=True)
    granted_by_username = models.CharField(max_length=128, blank=True)
    revoked_by_username = models.CharField(max_length=128, blank=True)
    revoke_reason = models.CharField(max_length=255, blank=True)

    class Meta:
        verbose_name = _("Archived membership")
        ordering = ["-created"]

    def __str__(self):
        return f"{self.user_username} as {self.role_name}"
