# Production seed round 2 review

Source reviewed: `OLGA_Seed_Values_Round2.xlsx`, dated 13 October 2026.

## Decision

The database owner subsequently approved the 18-entry industry list and the existing production
consent wording, and excluded venues, meeting spots, retention and moderation from this one-time
activity. `seed_production_round2_once.sql` preserves each existing current consent policy. Where a
current policy is missing, it inserts the approved Round 2 text as version `prod-v1`.

The script deliberately retains the existing `ranking-v1` threshold of `0.35`. The proposed
60/70/80/90 member-facing score remains application/architecture work until a versioned conversion
from stored `final_score` is approved. Other confirmed concepts that lack database support remain
future schema/API work and are not silently stored in unrelated columns.

## Blocking approvals and values

| Area | Workbook status | Required before SQL can be finalized |
|---|---|---|
| Consent | Approved by architect | Preserve an existing current policy; otherwise insert the exact approved Round 2 text for the community default locale, with a SHA-256 hash calculated over the displayed UTF-8 text. |
| Industries | Approved by architect | Seed the 18 codes, labels and order as the Release 1 taxonomy. |
| Score threshold | Architect to confirm | Confirm that 60/70/80/90 applies to a new room-normalized score and define how it is calculated from the stored `final_score`. Do not replace the existing `0.35` raw-score threshold with `0.60` without that mapping. |
| Event venue | Awaiting details | Final venue/room names, addresses or approved coarse cells, dates/hours, timezones and stable event IDs. |
| Meeting spots | Awaiting floor plans | Final spot names per launch room/event. |
| Retention | Not supplied | Legal/Privacy-approved resource classes, days, disposition and approving member ID, unless active production policies already exist. |
| Moderation | Not supplied | Approved content/file/rate policy JSON and creator member ID, unless active production rules already exist. |
| Notifications | Business behavior confirmed, technical values incomplete | Approve deduplication windows, daily caps, retry schedules and TTLs for all channel/purpose rows. Confirm where grouping, per-session delivery, 09:00 local scheduling and the 48-hour reminder are enforced. |

## Direct conflicts with the current schema

1. The workbook's `live_presence` consent cannot be seeded with that purpose code. The current
   Live Mode session invariant requires purpose code `LIVE_MODE`. The user-facing label can be
   changed to “Go Live” while the internal code remains `LIVE_MODE`, or the invariant and API must
   be migrated together.
2. A Venue Room requires `registration_required = false` and `check_in_required = true`. The current
   event policy constraint rejects check-in unless registration is also required.
3. The workbook requires “Same Room,” but the current proximity modes are only `NONE`, `VENUE` and
   `COARSE_CELL`. There is no room entity or room foreign key.
4. Non-event Venue Rooms cannot be represented by `event.event_matching_policy`, which requires an
   existing `event.event` row.
5. The database has no managed reference tables for professional roles, looking-for/offering pairs,
   seniority levels, meeting spots, meeting timing, Go Live duration options, badges or home tips.
6. The current event policy can store hourly/event alert caps, but it cannot store exactly three
   matches per Go Live session, four sessions per event, one intent edit per session or no refresh.
7. The notification policy can store per-hour/day caps and channel behavior, but not grouped extras,
   next-morning member-local scheduling, a single 48-hour reminder or per-session delivery.
8. The current schema permits one active Live Mode session per member per event, not one concurrent
   session across all Rooms as required by Round 2.

## Confirmed values that can be implemented after schema ownership is decided

- Product name: `Ol-ga`; user-facing action: `Go Live`.
- Seventeen professional role categories.
- Twelve complementary looking-for/offering pairs.
- Six seniority levels and four filter presets.
- Go Live duration choices of 30, 60, 90 and 120 minutes, default 60, with event-close behavior.
- Four meeting timing presets and a limit of five open commitments per member per Room session.
- Five private badges.
- Six home tips.
- Nine notification purposes/channels at launch.

These should not be forced into unrelated tables or JSON fields merely to produce a seed script.
The API/client owner must decide which are server-managed reference data and which remain versioned
application configuration.

## Existing seed changes required after blockers are resolved

- Change the community display name from `OLGA` to `Ol-ga`. The existing `ON CONFLICT DO NOTHING`
  does not update an already-seeded production row, so the final one-time script needs a guarded
  exact-value update and verification.
- Replace or version the existing notification policies rather than activating the current six-row
  QA baseline unchanged.
- Create a new ranking configuration version instead of modifying `ranking-v1` in place after the
  normalized-score contract is approved.
- The 18 sectors have been approved and are included in the one-time script.
- The exact Round 2 consent texts have been approved. The script inserts them only when a current
  policy for the corresponding purpose and default locale does not already exist.
- Insert event/room policies only after the required schema and the real event/room IDs exist.

## Approved one-time artifact

Run `seed_production_round2_once.sql` manually in DBeaver against the production database. Existing
current `LIVE_MODE` and `MATCHING` policies for the community default locale are preserved; missing
policies are created from the approved workbook text. The script then enforces exactly one current
policy for each purpose before commit.
