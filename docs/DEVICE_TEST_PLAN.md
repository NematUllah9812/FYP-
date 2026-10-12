# Terrastep device test plan — Blueprint Section 21 quality gates

The pilot may start only when these gates pass on the defined cohort.
"Passed" means measured as described, not "seemed fine once."

## Cohort
At least 6 phones: 2 budget, 2 mid-range, 2 flagship, covering the OEMs
pilot participants actually use (e.g. Samsung, Xiaomi/Redmi, Infinix/Tecno,
Pixel). Record model, Android version, battery health for every run.

## Route kit
- One surveyed/open-sky reference route (known distance, e.g. a measured
  track loop) for distance accuracy.
- One urban route with buildings and tree cover (hard GPS).
- One route that runs along H3 cell boundaries (boundary attribution).
- One route passing a protected/excluded area.

## Tracking matrix (every row on at least 2 devices)
Screen off entire walk · app backgrounded · app process killed mid-walk ·
OS force-stop · phone reboot mid-walk · incoming call · battery saver on ·
no step sensor (or sensor disabled) · approximate-only location ·
GPS disabled mid-walk · permission revoked mid-walk · offline start ·
intermittent data (airplane toggles) · device clock changed · session
crossing midnight (Asia/Karachi league day).

Expected behavior: Start/Pause/Resume/Finish agree between UI and the
durable local store; interrupted sessions surface an honest interruption
notice; no fabricated continuity (Plan Section 13).

## Gates and measurement
| Gate | Target | Method |
|---|---|---|
| Session reliability | ≥ 99% of started sessions yield recoverable records | 200+ varied field sessions from the matrix |
| Distance accuracy | Median error ≤ 5% | Reference route, repeated walks, per device |
| Battery | Median incremental screen-off drain ≤ 3 pts/hour; report p90 (≤ 5) and total | Matched idle baseline, 60-min walks, controlled brightness/network |
| Cold start | < 3 s p95 on the budget phone | Release build, recorded traces |
| Stability | ≥ 99.5% crash-free sessions in beta | Privacy-filtered telemetry |
| Server API | Map reads < 500 ms p95 server-side; online verification < 10 s p95 | Load test at Section 22 traffic for 1,000 MAU |
| Consistency | Zero duplicate awards / double owners | Concurrency + retry-storm tests (Stage 1/2 suites extended) |
| Privacy | Zero cross-user private-data access | Authorization test suite; export & deletion spot checks |
| Accessibility | Core walk + history usable with TalkBack at 200% text | Manual task tests |

## Game-rule verification
Replay the Stage 1 test suite plus: two players contesting one cell on
real devices; a newcomer joining mid-season; offline walk uploaded 12 h
later; contribution uploaded after 24 h grace (must become fitness-only).

## Sign-off
Each gate gets: device(s), date, build hash, raw result, pass/fail, tester.
Failed gates block the pilot; they are fixed, not waived (Plan Section 26).
