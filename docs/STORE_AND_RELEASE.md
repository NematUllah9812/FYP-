# Terrastep — Play Store pack and release runbook
*(Blueprint Sections 20–21. [Bracketed] items are team decisions/accounts.)*

## Store listing (draft)
- **App name:** Terrastep — Walk & Claim
- **Short description:** Walk your neighborhood, build your kingdom. A
  privacy-first walking game where verified steps claim real local territory.
- **Full description (draft):**
  Terrastep turns an ordinary walk into a friendly local game. Start a walk,
  move through your neighborhood, and earn territory hexagons from your
  *verified* moving minutes. Hold your ground against nearby players across
  28-day seasons — or skip competition entirely and just enjoy private
  goals, history and personal bests.
  • Fair by design: speed never multiplies score, daily caps keep beginners
    competitive, and points gently decay so rest days are fine.
  • Private by default: routes, times, weight and calories are never
    public. Public play shows only a nickname and held areas, delayed.
  • Protected places: mark home or any sensitive area and it leaves your
    ranked map completely.
  • Built for ordinary phones and patchy connections: walks record offline
    and sync when you are back.
- **Category:** Health & Fitness. **Content rating:** Everyone (complete the
  IARC questionnaire honestly; UGC = nicknames/kingdom names with reporting
  and blocking, per Plan Section 20).
- **Health apps declaration:** fitness tracking features; no medical claims,
  diagnoses or treatment. Data safety answers below must match reality.

## Play Data safety (truthful mapping to the build)
| Data | Collected | Shared | Why | Optional |
|---|---|---|---|---|
| Email address | Yes | No | Account | No (account) |
| Name (nickname) | Yes | Shown in-app to players if opted in | Game identity | Nickname required, real name never |
| Precise location | Yes, only during user-started sessions | No (derived public cells are delayed + sanitized) | Walk verification, territory | Ranked play only |
| Fitness/activity | Yes (steps during sessions) | No | Verification cross-check | During sessions |
| Weight | Yes | No | Calorie estimates | Yes |
| App activity | Yes (sessions, contributions) | No | Game + private history | — |
Security practices: encrypted in transit; account deletion in-app and via
[web deletion URL]; data deletion on request supported.

## Release runbook
1. **Code freeze** on a release branch; CI must be green (server tests,
   flutter analyze, debug APK).
2. **Bump version** in `app/pubspec.yaml`; update RELEASE notes.
3. **Signing:** release key lives only in CI secrets / the team's vault —
   never in the repo (Plan Section 20). Configure `key.properties` from
   secrets in the release workflow before enabling store builds.
4. **Build** release AAB via workflow_dispatch with `release: true`
   (switch the step to `flutter build appbundle` for Play upload).
5. **Closed test:** internal → closed track. New personal developer
   accounts need 12 opted-in testers for 14 continuous days before
   production access (Plan Section 20 — verify current rule at submission).
6. **Declarations:** health, Data safety, foreground-service declaration
   with a demo video of the user-started workout flow, account deletion URL.
7. **Staged rollout:** 10% → 50% → 100%, watching crash-free rate
   (gate ≥ 99.5%), verification latency, and dispute reports.
8. **Incident levers:** pause new ranked awards via server flag without
   disabling personal recording (Plan Section 17); roll back by promoting
   the previous AAB.
9. **Post-release drill (once per pilot):** restore a backup, rebuild
   ownership from the ledger, complete a deletion request end-to-end,
   revoke a compromised credential (Plan Section 21).

## Hardening checklist (pre-pilot)
- [ ] Supabase project separated dev/prod; RLS verified by adversarial tests
      (Stage 2 suite runs against Postgres, not only SQLite).
- [ ] Service-role key exists only on the server; no secrets in the repo
      (CI secret scan enabled).
- [ ] Custom SMTP configured; email deep links + recovery tested (Plan S24).
- [ ] Evidence purge job proven: batches older than 72 h actually deleted,
      including from backups per retention note (Plan Section 19).
- [ ] Public projection audit: no routes/times/live positions in any
      response; 30-minute delay enforced (Stage 2 tests cover this).
- [ ] Map provider contracted for production traffic + offline terms;
      dev OSM tiles removed from the release build (Plan Section 11).
- [ ] Play Integrity wired as *one* signal; appeal path documented
      (Plan Section 18). No auto-bans from a single signal.
- [ ] Team accounts (Play, Supabase, domain, repo) owned by the team with
      MFA and named recovery owners (Plan Section 20).
