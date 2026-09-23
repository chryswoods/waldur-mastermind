"""Who can read what.

The archive is read-only, which makes the interesting question access rather
than behaviour: proposals carry ``project_is_confidential``, and reviews carry
reviewer identities and candid private comments that the applicant was never
meant to see. Each test below is one row of §4.2 of the upgrade plan.
"""

from django.urls import reverse
from rest_framework import status, test

from waldur_core.structure.tests import factories as structure_factories
from waldur_core.structure.tests import fixtures as structure_fixtures

from . import factories


def url_for(basename, obj=None, action=None):
    if obj is None:
        return reverse(f"{basename}-list")
    if action:
        return reverse(f"{basename}-{action}", kwargs={"uuid": obj.uuid.hex})
    return reverse(f"{basename}-detail", kwargs={"uuid": obj.uuid.hex})


class ArchiveAccessTest(test.APITransactionTestCase):
    def setUp(self):
        self.fixture = structure_fixtures.CustomerFixture()
        self.customer = self.fixture.customer
        self.call_manager = self.fixture.owner

        self.staff = structure_factories.UserFactory(is_staff=True)
        self.support = structure_factories.UserFactory(is_support=True)
        self.applicant = structure_factories.UserFactory()
        self.stranger = structure_factories.UserFactory()

        self.call = factories.ArchivedCallFactory(
            customer_uuid=self.customer.uuid, customer_name=self.customer.name
        )
        self.round = factories.ArchivedRoundFactory(call=self.call)
        self.proposal = factories.ArchivedProposalFactory(
            round=self.round,
            call=self.call,
            created_by_uuid=self.applicant.uuid,
            created_by_username=self.applicant.username,
            notes=[{"timestamp": "2026-01-01T00:00:00Z", "text": "borderline"}],
        )
        self.review = factories.ArchivedReviewFactory(proposal=self.proposal)

        # A second call, belonging to nobody in this test, to prove the filters
        # exclude rather than merely include.
        self.other_call = factories.ArchivedCallFactory()
        self.other_proposal = factories.ArchivedProposalFactory(
            round=factories.ArchivedRoundFactory(call=self.other_call),
            call=self.other_call,
        )

    def listed(self, user, basename):
        self.client.force_authenticate(user)
        response = self.client.get(url_for(basename))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return {row["uuid"] for row in response.data}

    # -- calls ------------------------------------------------------------

    def test_staff_sees_every_call(self):
        self.assertEqual(
            self.listed(self.staff, "proposal-archive-call"),
            {self.call.uuid.hex, self.other_call.uuid.hex},
        )

    def test_support_sees_every_call(self):
        self.assertIn(
            self.call.uuid.hex, self.listed(self.support, "proposal-archive-call")
        )

    def test_a_call_manager_sees_only_their_organisation_s_calls(self):
        self.assertEqual(
            self.listed(self.call_manager, "proposal-archive-call"),
            {self.call.uuid.hex},
        )

    def test_a_stranger_sees_no_calls(self):
        self.assertEqual(self.listed(self.stranger, "proposal-archive-call"), set())

    def test_an_anonymous_visitor_is_turned_away(self):
        response = self.client.get(url_for("proposal-archive-call"))
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    # -- proposals --------------------------------------------------------

    def test_an_applicant_sees_their_own_proposal(self):
        self.assertEqual(
            self.listed(self.applicant, "proposal-archive-proposal"),
            {self.proposal.uuid.hex},
        )

    def test_an_applicant_does_not_see_the_call_it_belongs_to(self):
        """Reading your own proposal does not make you a call manager."""
        self.assertEqual(self.listed(self.applicant, "proposal-archive-call"), set())

    def test_a_call_manager_sees_the_proposals_to_their_call(self):
        self.assertEqual(
            self.listed(self.call_manager, "proposal-archive-proposal"),
            {self.proposal.uuid.hex},
        )

    def test_a_stranger_cannot_fetch_a_proposal_directly(self):
        self.client.force_authenticate(self.stranger)
        response = self.client.get(url_for("proposal-archive-proposal", self.proposal))
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    # -- reviews ----------------------------------------------------------

    def test_the_applicant_never_sees_reviews_of_their_own_proposal(self):
        self.assertEqual(self.listed(self.applicant, "proposal-archive-review"), set())

    def test_the_applicant_cannot_fetch_a_review_directly_either(self):
        self.client.force_authenticate(self.applicant)
        response = self.client.get(url_for("proposal-archive-review", self.review))
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_a_call_manager_sees_reviews_of_their_call(self):
        self.assertEqual(
            self.listed(self.call_manager, "proposal-archive-review"),
            {self.review.uuid.hex},
        )

    def test_staff_sees_reviews(self):
        self.assertIn(
            self.review.uuid.hex, self.listed(self.staff, "proposal-archive-review")
        )

    # -- notes ------------------------------------------------------------

    def test_notes_are_not_on_the_proposal_the_applicant_can_read(self):
        self.client.force_authenticate(self.applicant)
        response = self.client.get(url_for("proposal-archive-proposal", self.proposal))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotIn("notes", response.data)

    def test_the_applicant_cannot_reach_the_notes_endpoint(self):
        self.client.force_authenticate(self.applicant)
        response = self.client.get(
            url_for("proposal-archive-proposal", self.proposal, "notes")
        )
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_a_call_manager_can_read_the_notes(self):
        self.client.force_authenticate(self.call_manager)
        response = self.client.get(
            url_for("proposal-archive-proposal", self.proposal, "notes")
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["notes"][0]["text"], "borderline")

    # -- memberships ------------------------------------------------------

    def test_memberships_follow_the_call(self):
        membership = factories.ArchivedMembershipFactory(
            proposal=self.proposal, call=self.call, user_username="someone"
        )
        self.assertEqual(
            self.listed(self.call_manager, "proposal-archive-membership"),
            {membership.uuid.hex},
        )
        self.assertEqual(
            self.listed(self.stranger, "proposal-archive-membership"), set()
        )


class ResolveTest(test.APITransactionTestCase):
    """Old /proposals/<uuid> links keep working because the UUIDs are kept."""

    def setUp(self):
        self.staff = structure_factories.UserFactory(is_staff=True)
        self.stranger = structure_factories.UserFactory()
        self.proposal = factories.ArchivedProposalFactory()
        self.call = self.proposal.call
        self.client.force_authenticate(self.staff)

    def resolve(self, uuid):
        return self.client.get(
            reverse("proposal-archive-resolve-detail", kwargs={"uuid": uuid})
        )

    def test_a_proposal_uuid_resolves_to_its_proposal(self):
        response = self.resolve(self.proposal.uuid.hex)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["kind"], "proposal")
        self.assertEqual(response.data["name"], self.proposal.name)

    def test_a_call_uuid_resolves_to_its_call(self):
        response = self.resolve(self.call.uuid.hex)
        self.assertEqual(response.data["kind"], "call")

    def test_an_unknown_uuid_is_a_404(self):
        response = self.resolve("0" * 32)
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_a_uuid_the_caller_may_not_see_is_also_a_404(self):
        """Indistinguishable from unknown, deliberately."""
        self.client.force_authenticate(self.stranger)
        response = self.resolve(self.proposal.uuid.hex)
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)


class ReadOnlyTest(test.APITransactionTestCase):
    def setUp(self):
        self.staff = structure_factories.UserFactory(is_staff=True)
        self.proposal = factories.ArchivedProposalFactory()
        self.client.force_authenticate(self.staff)

    def test_an_archive_cannot_be_written_to(self):
        detail = url_for("proposal-archive-proposal", self.proposal)
        for method, target in (
            (self.client.post, url_for("proposal-archive-proposal")),
            (self.client.put, detail),
            (self.client.patch, detail),
            (self.client.delete, detail),
        ):
            with self.subTest(method=method.__name__):
                response = method(target, {})
                self.assertEqual(
                    response.status_code, status.HTTP_405_METHOD_NOT_ALLOWED
                )
