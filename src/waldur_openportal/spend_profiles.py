"""Award spend profiles: dated minimum and/or maximum spends on an award.

An awarding portal (AIRR) sets a profile on a RemoteProject and sends it to
the site in AwardDetails.spend_profile; the site (a ManagedProject) enforces
it. OpenPortal carries the profile and checks only that it is well formed
(valid dates and allocations, no duplicate dates, maximum >= minimum, the
same units within an entry). The rules here are the ones the portals agree:

- each entry applies from its date until the next entry's (the last until the
  award's end date), and a control an entry leaves out does not apply in its
  period;
- the amounts are in the award's allocation units, and the dates fall within
  the award;
- a period that has ended, or begun, is not rewritten: entries dated today or
  earlier keep their dates, those whose period has ended keep their controls,
  and new entries start today or later.

Entries are held as JSON, [{"from": "YYYY-MM-DD", "minimum": "250 NHR",
"maximum": "250 NHR"}, ...], sorted by date, exactly as AwardDetails sends
them. Needs an openportal release with spend profiles (0.94); with an older
one a profile cannot be set or read.
"""

import datetime

import openportal
from django.utils import timezone

from . import utils

# Feature names a site portal reports through get_supported_features.
AWARD_SPEND_MINIMUMS = "award_spend_minimums"
AWARD_SPEND_MAXIMUMS = "award_spend_maximums"

# What this portal, as a site, does with an award's spend profile: a feature
# is added here only once it is enforced. Answered to is_feature_supported
# and get_supported_features.
SUPPORTED_FEATURES: frozenset[str] = frozenset()


def today() -> datetime.date:
    """Today, in UTC: a period's days start at midnight UTC."""
    return timezone.now().astimezone(datetime.UTC).date()


class SpendProfileError(ValueError):
    """A spend profile that cannot be accepted; the message says why."""


def is_supported() -> bool:
    """Whether the installed openportal library knows spend profiles. Without
    it a profile would be dropped silently when an award is sent or read."""
    return hasattr(openportal, "SpendProfileEntry")


def _date(value) -> datetime.date:
    if isinstance(value, datetime.date):
        return value
    try:
        return datetime.date.fromisoformat(str(value))
    except ValueError:
        raise SpendProfileError(f"'{value}' is not a date (YYYY-MM-DD).")


def entry_json(entry) -> dict:
    """An openportal.SpendProfileEntry as the JSON AwardDetails carries."""
    data = {"from": entry.from_date.isoformat()}
    if entry.minimum is not None:
        data["minimum"] = str(entry.minimum)
    if entry.maximum is not None:
        data["maximum"] = str(entry.maximum)
    return data


def parse(raw) -> list:
    """The profile's entries as openportal.SpendProfileEntry, sorted by date,
    checked as OpenPortal checks them. ``raw`` is the JSON list."""
    if not is_supported():
        raise SpendProfileError(
            "This portal's OpenPortal library does not support spend profiles "
            "(it needs openportal 0.94 or later)."
        )
    entries = []
    for item in raw or []:
        if not isinstance(item, dict) or "from" not in item:
            raise SpendProfileError("Each entry needs a 'from' date.")
        from_date = _date(item["from"])
        try:
            entries.append(
                openportal.SpendProfileEntry(
                    from_date,
                    item.get("minimum") or None,
                    item.get("maximum") or None,
                )
            )
        except Exception as e:
            raise SpendProfileError(f"Invalid entry from {from_date}: {e}")
    entries.sort(key=lambda e: e.from_date)
    for earlier, later in zip(entries, entries[1:]):
        if earlier.from_date == later.from_date:
            raise SpendProfileError(f"Two entries start on {later.from_date}.")
    return entries


def normalise(raw) -> list:
    """The profile as canonical JSON: checked, sorted, and spelt as
    AwardDetails spells it."""
    return [entry_json(e) for e in parse(raw)]


def _units(allocation) -> str:
    return str(allocation.units).strip().lower()


def validate_for_award(entries, details) -> None:
    """The portals' rules for a profile on this award: amounts in the award's
    allocation units, dates within the award."""
    allocation = getattr(details, "allocation", None)
    start = getattr(details, "start_date", None)
    end = getattr(details, "end_date", None)
    for entry in entries:
        for name in ("minimum", "maximum"):
            amount = getattr(entry, name)
            if amount is not None and allocation is not None:
                if _units(amount) != _units(allocation):
                    raise SpendProfileError(
                        f"The {name} from {entry.from_date} is in "
                        f"{amount.units}, but the award is in {allocation.units}."
                    )
        if start is not None and entry.from_date < start:
            raise SpendProfileError(
                f"The entry from {entry.from_date} starts before the award ({start})."
            )
        if end is not None and entry.from_date > end:
            raise SpendProfileError(
                f"The entry from {entry.from_date} starts after the award ends ({end})."
            )


def periods(raw, end_date=None) -> list[dict]:
    """Each entry as a period: {"from", "to" (inclusive, or None if open),
    "minimum", "maximum"}. An entry runs until the day before the next one's,
    the last until ``end_date``."""
    items = sorted(raw or [], key=lambda item: str(item["from"]))
    result = []
    for index, item in enumerate(items):
        start = _date(item["from"])
        if index + 1 < len(items):
            to = _date(items[index + 1]["from"]) - datetime.timedelta(days=1)
        else:
            to = end_date
        result.append(
            {
                "from": start,
                "to": to,
                "minimum": item.get("minimum"),
                "maximum": item.get("maximum"),
            }
        )
    return result


def validate_change(old_raw, new_raw, today: datetime.date) -> None:
    """Refuse a change that rewrites a period already begun.

    Every entry dated today or earlier stays, with its date; one whose period
    has ended keeps its controls (the current period's may change); and any
    new entry starts today or later. To end controls early, add an entry with
    no controls from today rather than removing the profile."""
    old = {_date(item["from"]): item for item in (old_raw or [])}
    new = {_date(item["from"]): item for item in (new_raw or [])}
    old_periods = {p["from"]: p for p in periods(old_raw)}
    for start, item in sorted(old.items()):
        if start > today:
            continue
        if start not in new:
            raise SpendProfileError(
                f"The period from {start} has begun, so it cannot be removed. "
                "To end the controls, add an entry with no controls from today."
            )
        ended = (
            old_periods[start]["to"] is not None and old_periods[start]["to"] < today
        )
        if ended and (
            (item.get("minimum") or None) != (new[start].get("minimum") or None)
            or (item.get("maximum") or None) != (new[start].get("maximum") or None)
        ):
            raise SpendProfileError(
                f"The period from {start} has ended, so its controls cannot change."
            )
    for start in new:
        if start not in old and start < today:
            raise SpendProfileError(
                f"A new period cannot start in the past ({start}); start it "
                f"today ({today}) or later."
            )


def _amount(value) -> float | None:
    """An entry's amount ("250 NHR") as a number in the award's units; the
    units were checked against the award's when the profile was set."""
    if not value:
        return None
    return float(openportal.Allocation.from_string(str(value)).size)


def _award_scale(managed_project, units: str) -> float:
    """Award units per node-hour of usage, as the project template converts
    them (ProjectTemplate.convert_to_credits divides by the same factor)."""
    template = managed_project.project_template
    if template is None:
        return 1.0
    scale = (template.allocation_units_mapping or {}).get(units)
    if scale is None:
        return 1.0
    return float(scale) if scale > 0 else 0.0


def progress(managed_project, today: datetime.date) -> dict | None:
    """The award's spend profile, period by period, with its spend so far.

    None if the award has no profile. Otherwise {"units", "allocation",
    "spend", "periods": [...]}, every amount in the award's units, where each
    period has:

    - "from", "to" (inclusive), "minimum", "maximum": the profile's entry;
    - "status": "ended", "current" or "upcoming";
    - "spend": what was charged on the period's days, up to today;
    - "cumulative_spend": what was charged from the award's start to the end
      of the period (or today), the charges the period's controls compare to;
    - "cumulative_minimum": the minimums so far, None if there are none;
    - "cap": the limit during the period: the maximums so far, with a period
      that had no maximum, and the days before the first, counted at what
      they charged; the whole award if the period has no maximum;
    - "headroom": cap less cumulative_spend, for a period begun;
    - "forfeit": the forfeit charged when the period ended, None until
      forfeits are charged.

    Charges are the award's usage (utils.get_award_usage_hours, in node-hours
    converted to the award's units with the project template's factor).
    """
    details = managed_project.details or {}
    raw = details.get("spend_profile")
    if not raw:
        return None

    award_details = managed_project.get_details()
    award = getattr(award_details, "allocation", None)
    units = str(award.units) if award is not None else None
    award_size = float(award.size) if award is not None else None
    scale = _award_scale(managed_project, units) if units else 1.0
    end_date = getattr(award_details, "end_date", None)

    def charged(start=None, end=None) -> float:
        hours = utils.get_award_usage_hours(
            managed_project, range_start=start, range_end=end
        )
        return hours * scale

    award_spend = charged(end=today)
    result_periods = []
    first = periods(raw, end_date)
    # The days before the first period are uncontrolled, and count towards
    # later caps at what they charged.
    counted = charged(end=first[0]["from"] - datetime.timedelta(days=1))
    cumulative_minimum = None

    for period in first:
        start, to = period["from"], period["to"]
        minimum = _amount(period["minimum"])
        maximum = _amount(period["maximum"])
        if start > today:
            status = "upcoming"
        elif to is not None and to < today:
            status = "ended"
        else:
            status = "current"

        if minimum is not None:
            cumulative_minimum = (cumulative_minimum or 0.0) + minimum

        if status == "upcoming":
            spend = None
            cumulative_spend = None
        else:
            last = to if status == "ended" else today
            spend = charged(start, last)
            cumulative_spend = charged(end=last)

        if maximum is None:
            cap = award_size
        else:
            cap = counted + maximum
            if award_size is not None:
                cap = min(cap, award_size)

        # What the period adds to the caps after it: its maximum, or, with
        # none, what it charged (an upcoming period without one is unknown,
        # and every later cap is then the award's or its own maximum's).
        if maximum is not None:
            counted += maximum
        else:
            counted += spend or 0.0

        result_periods.append(
            {
                "from": start,
                "to": to,
                "minimum": period["minimum"],
                "maximum": period["maximum"],
                "status": status,
                "spend": spend,
                "cumulative_spend": cumulative_spend,
                "cumulative_minimum": cumulative_minimum,
                "cap": cap,
                "headroom": (
                    cap - cumulative_spend
                    if cap is not None and cumulative_spend is not None
                    else None
                ),
                "forfeit": None,
            }
        )

    return {
        "units": units,
        "allocation": award_size,
        "spend": award_spend,
        "periods": result_periods,
    }
