"""Serializers for the read-only proposal archive.

Everything here is read-only: there is no create or update path, and the
viewsets disable those actions.  Fields are plain rather than hyperlinked,
because an archive row's references point at UUIDs that may no longer resolve
to anything -- a user who has left, a project that was deleted.  A dangling
hyperlink is worse than a recorded name, which is the whole reason §4.1
denormalised them in the first place.

Reviews are a separate serializer rather than a nested field on the proposal:
§4.2 makes them visible to a narrower audience than the proposal itself, and a
nested field would have to re-apply that check on every parent.
"""

import logging

from drf_spectacular.utils import extend_schema_field
from rest_framework import serializers

from . import models

logger = logging.getLogger(__name__)


class ArchivedDocumentSerializer(serializers.ModelSerializer):
    """Shared shape for both kinds of archived document.

    ``file`` is the storage path; the bytes are served by ``/api/media/<uuid>/``
    under the rules in ``media_access.py``.

    Both derived fields are methods rather than ``source="file.name"`` /
    ``source="file.size"``, because an archived document may legitimately have
    no file. ``FieldFile.size`` calls ``_require_file()`` and raises

        ValueError: The 'file' attribute has no file associated with it.

    which DRF does not catch -- so one document with a blank path 500s the
    whole response rather than rendering as a row without a download. The
    archive is a record of what was there; a document row whose bytes never
    made it, or were removed, is still part of that record and has to
    serialize.
    """

    file_name = serializers.SerializerMethodField()
    file_size = serializers.SerializerMethodField()

    class Meta:
        fields = ["uuid", "file", "file_name", "file_size", "created"]

    @extend_schema_field(serializers.CharField(allow_null=True))
    def get_file_name(self, document):
        return document.file.name or None

    @extend_schema_field(serializers.IntegerField(allow_null=True))
    def get_file_size(self, document):
        if not document.file:
            return None
        try:
            return document.file.size
        except (OSError, ValueError):
            # DatabaseStorage answers 0 for a path with no bytes behind it
            # rather than raising, so this is defence for storages that do
            # raise -- not the empty-path case above, which is the one that
            # actually bites.
            logger.warning(
                "Archived document %s points at missing storage: %s",
                document.uuid,
                document.file.name,
            )
            return None


class ArchivedCallDocumentSerializer(ArchivedDocumentSerializer):
    class Meta(ArchivedDocumentSerializer.Meta):
        model = models.ArchivedCallDocument
        fields = ArchivedDocumentSerializer.Meta.fields + ["description"]


class ArchivedProposalDocumentSerializer(ArchivedDocumentSerializer):
    class Meta(ArchivedDocumentSerializer.Meta):
        model = models.ArchivedProposalDocument


class ArchivedRoundSerializer(serializers.ModelSerializer):
    call_uuid = serializers.UUIDField(source="call.uuid", read_only=True)
    call_name = serializers.CharField(source="call.name", read_only=True)

    class Meta:
        model = models.ArchivedRound
        fields = [
            "uuid",
            "slug",
            "call_uuid",
            "call_name",
            "start_time",
            "cutoff_time",
            "review_strategy",
            "deciding_entity",
            "allocation_time",
            "allocation_date",
            "review_duration_in_days",
            "fixed_review_end_date",
            "minimum_number_of_reviewers",
            "minimal_average_scoring",
            "minimum_required_uploads",
            "created",
        ]


class ArchivedCallSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.ArchivedCall
        fields = [
            "uuid",
            "name",
            "slug",
            "description",
            "state",
            "external_url",
            "fixed_duration_in_days",
            "reviewer_identity_visible_to_submitters",
            "reviews_visible_to_submitters",
            "customer_uuid",
            "customer_name",
            "created_by_uuid",
            "created_by_username",
            "created_by_full_name",
            "created",
            "modified",
        ]


class ArchivedCallDetailSerializer(ArchivedCallSerializer):
    rounds = ArchivedRoundSerializer(many=True, read_only=True)
    documents = ArchivedCallDocumentSerializer(many=True, read_only=True)
    proposal_count = serializers.IntegerField(read_only=True)

    class Meta(ArchivedCallSerializer.Meta):
        fields = ArchivedCallSerializer.Meta.fields + [
            "rounds",
            "documents",
            "proposal_count",
        ]


class ArchivedRequestedResourceSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.ArchivedRequestedResource
        fields = [
            "uuid",
            "offering_uuid",
            "offering_name",
            "plan_uuid",
            "plan_name",
            "template_name",
            "attributes",
            "limits",
            "resource_uuid",
            "created_by_username",
            "created",
        ]


class ArchivedMembershipSerializer(serializers.ModelSerializer):
    call_uuid = serializers.UUIDField(
        source="call.uuid", read_only=True, allow_null=True
    )
    proposal_uuid = serializers.UUIDField(
        source="proposal.uuid", read_only=True, allow_null=True
    )

    class Meta:
        model = models.ArchivedMembership
        fields = [
            "uuid",
            "scope_kind",
            "call_uuid",
            "proposal_uuid",
            "organisation_customer_uuid",
            "organisation_customer_name",
            "role_name",
            "role_description",
            "user_uuid",
            "user_username",
            "user_full_name",
            "is_active",
            "expiration_time",
            "granted_by_username",
            "revoked_by_username",
            "revoke_reason",
            "created",
        ]


class ArchivedProposalSerializer(serializers.ModelSerializer):
    call_uuid = serializers.UUIDField(source="call.uuid", read_only=True)
    call_name = serializers.CharField(source="call.name", read_only=True)
    round_uuid = serializers.UUIDField(source="round.uuid", read_only=True)

    class Meta:
        model = models.ArchivedProposal
        fields = [
            "uuid",
            "name",
            "slug",
            "state",
            "call_uuid",
            "call_name",
            "round_uuid",
            "project_uuid",
            "project_name",
            "created_by_uuid",
            "created_by_username",
            "created_by_full_name",
            "submitted_at",
            "created",
            "modified",
        ]


class ArchivedProposalDetailSerializer(ArchivedProposalSerializer):
    requested_resources = ArchivedRequestedResourceSerializer(many=True, read_only=True)
    documents = ArchivedProposalDocumentSerializer(many=True, read_only=True)
    memberships = ArchivedMembershipSerializer(many=True, read_only=True)

    class Meta(ArchivedProposalSerializer.Meta):
        fields = ArchivedProposalSerializer.Meta.fields + [
            "description",
            "project_summary",
            "project_duration",
            "project_is_confidential",
            "project_has_civilian_purpose",
            "oecd_fos_2007_code",
            "duration_in_days",
            "allocation_comment",
            "approved_by_uuid",
            "approved_by_username",
            "requested_resources",
            "documents",
            "memberships",
        ]


class ArchivedProposalNotesSerializer(serializers.ModelSerializer):
    """Call-manager notes, kept off the proposal serializer on purpose.

    ``notes`` were only ever visible to call managers and staff, so they get
    their own endpoint with the review-level check rather than riding along on
    a proposal the applicant can read.
    """

    class Meta:
        model = models.ArchivedProposal
        fields = ["uuid", "notes"]


class ArchivedReviewSerializer(serializers.ModelSerializer):
    proposal_uuid = serializers.UUIDField(source="proposal.uuid", read_only=True)
    proposal_name = serializers.CharField(source="proposal.name", read_only=True)

    class Meta:
        model = models.ArchivedReview
        fields = [
            "uuid",
            "proposal_uuid",
            "proposal_name",
            "state",
            "summary_score",
            "summary_public_comment",
            "summary_private_comment",
            "comment_project_title",
            "comment_project_summary",
            "comment_project_description",
            "comment_project_duration",
            "comment_project_is_confidential",
            "comment_project_has_civilian_purpose",
            "comment_project_supporting_documentation",
            "comment_resource_requests",
            "comment_team",
            "reviewer_uuid",
            "reviewer_username",
            "reviewer_full_name",
            "comments",
            "created",
            "modified",
        ]


class ArchiveResolveSerializer(serializers.Serializer):
    """What an old ``/proposals/<uuid>`` link resolves to.

    ``kind`` says which archive endpoint holds it, so the frontend can redirect
    without guessing.
    """

    kind = serializers.ChoiceField(choices=["call", "round", "proposal"])
    uuid = serializers.UUIDField()
    name = serializers.CharField()
