# Terrastep — Build Plan (from the Product & Technical Plan v1.0, 3 Oct 2026)

Assessment by Muse after reading all 33 pages (page 2 is just the contents page — nothing was missing).

## Verdict on the blueprint
Unusually complete for a build spec. It fixes the game rules numerically (Section 9),
the API contracts (Section 16), the data model (Section 15), privacy/retention
(Section 19), and quality gates (Section 21). It is buildable as written.
Sections marked "proposed/prototype" in the plan are treated as v1 decisions, not blockers.

## What the blueprint itself says to build first (Section 27, "first complete build")
One adult can: create an account → choose privacy → start a walk → record screen-off →
finish offline → reconnect → see a preserved personal record → receive an explained
server decision → see a consistent local board. A second adult can challenge the same
cell with no double owner. Either can report a problem and delete their account.

## Build stages (following the plan's own delivery order)
- **Stage 1 — Game core / authoritative referee (IN PROGRESS)**
  Deterministic rules engine implementing Section 9 exactly (points, caps, 7-day decay,
  thresholds, takeover margin, tie-breaks) in fixed-point micro-points; fitness math from
  Section 12 (filtered distance, MET calories); H3 attribution at resolution 9;
  tests built from the Section 10 worked examples; simulation harness for Section 10
  scenarios (20/100/1,000 players, newcomer mid-season, volume player).
- **Stage 2 — Server**: Postgres schema from Section 15 (Supabase), session lifecycle +
  idempotent ingest from Sections 16–17, sanitized map/board APIs, privacy projections.
- **Stage 3 — Android app**: Flutter UI (Start / League / Me per Sections 5–7) + native
  Kotlin tracker module (foreground service, Section 13). Needs the Flutter/Android
  toolchain — not installed in this workspace yet (see gaps).
- **Stage 4 — Hardening**: anti-cheat signals, moderation/report/block, export/deletion,
  quality-gate test matrix (Section 21), pilot prep (Section 26).

## Open items the blueprint leaves to the team (Section 27) — need the user's input
1. Academic deadline and weekly hours available (drives how much of Stages 2–4 fits).
2. The plan references an **existing Flutter prototype/APK** ("existing Flutter foundation").
   If it exists, share the code/APK so Stage 3 builds on it instead of starting over.
3. A **Supabase project** (or decision to run local Postgres first) for Stage 2 —
   account/keys must be the team's own.
4. Map provider choice (MapLibre vs Mapbox) is explicitly a field-trial decision in the
   plan; Stage 3 can start with one and keep the renderer swappable.
5. Reviewed Abbottabad pilot region cell set (needed for ranked play in Stage 2/3;
   personal tracking works without it).

## Environment notes (this workspace)
- Available now: Python 3.12, Node 24. Not installed: Flutter/Dart, JDK/Android SDK,
  Postgres, Docker. Stage 1 is therefore built in Python (the referee logic is
  transport-independent by design, per Section 14) and will port 1:1 to the server.
- No device testing is possible here; battery/GPS gates (Section 21) need real phones.
