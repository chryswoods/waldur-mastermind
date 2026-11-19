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

# Feature names a site portal reports through get_supported_features.
AWARD_SPEND_MINIMUMS = "award_spend_minimums"
AWARD_SPEND_MAXIMUMS = "award_spend_maximums"


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
