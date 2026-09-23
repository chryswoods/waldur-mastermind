from waldur_core.core import WaldurExtension


class ProposalArchiveExtension(WaldurExtension):
    class Settings:
        pass

    @staticmethod
    def django_app():
        return "waldur_mastermind.proposal_archive"

    @staticmethod
    def is_assembly():
        return True
