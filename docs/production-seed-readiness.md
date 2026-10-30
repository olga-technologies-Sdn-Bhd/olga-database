# Production seed readiness

This checklist compares the production seed request with the PostgreSQL schema and the canonical
`050_seed.sql`. It is intended for the one-time manual DBeaver activity against
`olga_connect_prod`.

## Already defined in the database source

Running the normal full setup already seeds these rows:

| Table | Current source | Production action |
|---|---|---|
| `core.community` | `olga`, locale `en-IN` | Confirm only. Existing production values are preserved. |
| `iam.role` | Seven application/admin roles | Use as defined. Reruns refresh role descriptions and privilege flags. |
| `iam.permission` | Twenty-two permissions | Use as defined. Reruns refresh metadata and set the rows active. |
| `iam.role_permission` | Baseline role grants | Use as defined. Reruns restore revoked baseline grants. |
| `nlp.nlp_model_version` | `azure-text-embedding-3-small-1536-v1` | Confirm Azure deployment name and preprocessing contract. |
| `nlp.nlp_ranking_config` | `ranking-v1`, threshold `0.35000` | Do not change without evaluation/calibration approval. |
| `notification.notification_policy` | Six baseline policies | Not inserted unless `olga.seed_mvp_policies=1`; Product/Ops must approve the limits first. |

The manual seed template reuses `050_seed.sql`, so these values have one source of truth.

## Data required before the production seed can run

Ask the Product, Legal/Privacy, Security, and Event Operations owners for:

1. `consent.consent_policy`
   - Final displayed text for `LIVE_MODE` and `MATCHING` in each supported locale.
   - Stable policy ID, version, locale, effective timestamp, and lowercase SHA-256 of the exact
     displayed UTF-8 text.
   - Whether `TERMS`, `LOCATION`, `NOTIFICATIONS`, or `ANALYTICS` policies are launch requirements.
   - The development `MATCHING` text/hash is evidence only and must not be promoted as production
     approval.
2. `core.sector`
   - Final codes, labels, parent codes, status, and sort order.
   - The client currently shows Telecom, Government, Venture, and Education, but those four values
     are not yet an approved complete taxonomy.
3. `event.venue`
   - Stable venue ID, official name, ISO country, region/city, IANA timezone, and approved coarse
     geo cell for each launch venue.
4. `event.event_matching_policy`
   - One version for every published/active event using Live Mode: registration/check-in rules,
     proximity mode, presence age, threshold override, alert threshold/caps, and effective time.
   - This is event-dependent configuration, not a universal static seed. Event creation should
     create it transactionally in the admin workflow in the longer term.
5. `ops.retention_policy`
   - Complete governed resource/data-class list, retention days, `DELETE`/`ANONYMIZE`/`ARCHIVE`,
     legal-hold support, effective time, and approving production member ID.
6. `moderation.content_rule`
   - Approved file-type, term, rate, and policy rules as the exact JSON contract expected by the
     moderation worker/API, plus the production administrator member ID recorded as creator.
7. Notifications and ranking
   - Approve or revise the six notification policies before enabling them.
   - Reconcile the app's 74% default minimum-match filter with the database threshold of 35%; the
     observed development scores in the supplied note (35-41%) indicate a launch-blocking UX/config
     mismatch unless calibrated.

## Schema gaps: no seed can be created yet

| Product concept | Current schema result | Required decision/work |
|---|---|---|
| Role categories | `core.member_profile.role_category` is free text; there is no lookup table. | Approve codes and add a reference table/API if centrally managed values are required. |
| Meeting spots per event | No meeting-spot table exists. | Define table/API and ownership, then seed spots per event. |
| Looking-for and seniority options | No lookup tables; currently client constants. | Confirm they remain versioned client constants or add managed reference tables/APIs. |
| Commit timing, room limit, Live Mode duration, tips, colours, badges | No matching configuration tables. | Confirm code/config ownership; add schema only if admins must manage the values. |

Members, events, registrations, connections, and member consent decisions are operational data and
must not be bulk-seeded. Events should be created through the admin workflow; the one-time template
only accepts policies for event rows that already exist.

## Manual run

1. Copy `seed_production_once.template.sql` to a working SQL file and populate every required input
   section with approved literal values.
2. Keep `activate_baseline_notification_policies` false until the six existing policies are approved;
   change it to true in the approved run file if notifications must launch.
3. Connect with the migration identity to exactly `olga_connect_prod`.
4. Use DBeaver **Execute SQL Script** (`Alt+X`). Do not execute individual statements.
5. Save the filled, approved run file and the final count result as deployment evidence in the
   team's controlled operational location.

The script takes a transaction advisory lock, refuses other database names, validates inputs before
including the canonical seed, never updates an existing versioned row, verifies exact values, and
rolls back on any conflict.
