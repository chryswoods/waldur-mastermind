# Award spend profiles

An award can carry a **spend profile**: dated periods, each with an optional
minimum and maximum spend. The awarding portal (AIRR) sets it on a
`RemoteProject` and sends it to the site in `AwardDetails.spend_profile`
(OpenPortal 0.94). The site (a `ManagedProject`) enforces it. Code:
`src/waldur_openportal/spend_profiles.py`.

## The profile

- Each entry applies from its `from` date until the day before the next
  entry's; the last runs to the award's end date.
- Amounts are in the award's allocation units, and dates fall within the
  award.
- A control an entry leaves out does not apply in its period. Nothing
  carries over from an earlier entry. An entry with neither control means
  "no controls from this date".
- Days start at midnight UTC.
- A period that has begun is not rewritten. Entries dated today or earlier
  keep their dates; those whose period has ended keep their controls; new
  entries start today or later. To end the controls early, add an entry
  with no controls from today.

## The rules both portals agree

**The award's allocation is never changed by a profile.** Every charge
(usage, and later forfeits) counts against the whole award.

**Maximums.** During a period, the award behaves as if its allocation were
its *cap*:

- the cap is the sum of the maximums so far, never more than the award;
- the days before the first period, and any period with no maximum, count
  towards later caps at what they actually charged;
- a period with no maximum has no cap: the whole award is available.

Overspend is not double-counted: it is already in the charges, so it
already reduces what is left under the cap. Unspent cap is not carried
forward as such; under-spend against a minimum becomes a forfeit (below).

**Minimums** (not yet enforced). On the first day of a new period the site
charges a forfeit of the sum of the minimums so far, less everything charged
so far (usage and earlier forfeits), if that is positive. A period with no
minimum adds nothing to the sum, so no forfeit is charged at its end.
Spending above a minimum counts towards later periods. The forfeit is dated
the last day of the period that ended.

## How the site enforces maximums

The project's credits stay the award's: the awarding portal reads the
allocation back from them, and allocation review compares against them.
Instead, `sync_allocation_limits` (every 17 minutes) takes
`withheld_credits()` (the award less the current cap, in credits) off the
credits it lets the project use on the cluster. A new period's cap
therefore applies within 17 minutes of UTC midnight.

## Features

A site answers `is_feature_supported` / `get_supported_features` from
`spend_profiles.SUPPORTED_FEATURES`. It claims `award_spend_maximums` now and
will claim `award_spend_minimums` only once forfeits are charged and
reported. The awarding portal records a site's answer on each
`RemoteProject` (`site_features`), refreshed daily.

## Progress

`/api/openportal-managed-project-accounting-summary/<project_uuid>/` has a
`spend_profile` field: each period's dates, controls and status, its spend,
the cumulative spend and minimums, the cap, the headroom, and (later) the
forfeit. Amounts are in the award's units, converted from node-hours with
the project template's factor, as the usage reports are.
