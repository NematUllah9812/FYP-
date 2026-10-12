# Terrastep app (Flutter + native Kotlin tracker)

Implements Blueprint Sections 5–7 (onboarding, screens, design) and 13
(tracking) against the Stage 2 server contracts.

## What's inside
- `lib/` — app entry, design tokens (Section 7), API client (Section 16),
  sync/outbox engine (idempotent uploads, Section 17), session state, and
  the Start / League / Me screens plus Settings and onboarding (Sections 5–6).
- `android/.../TrackerService.kt` — user-started foreground service using
  Fused Location, adaptive sampling (5 s moving / 30 s stationary), step
  counter with reboot re-baselining, ongoing notification with Stop.
- `android/.../TrackerDb.kt` — durable on-device sample store. Samples are
  only marked uploaded after server acknowledgement; nothing is deleted on
  failure (Sections 13–14).
- `android/.../MainActivity.kt` — Method/Event channel bridge + GPS status.

## First build
1. Install Flutter (stable) and the Android SDK (API 36) — or skip local
   setup and use the Stage 4 GitHub Actions workflow, which builds the APK
   in the cloud.
2. From this folder: `flutter create --platforms=android .` once, to let the
   Flutter tool generate the Gradle wrapper files for your SDK version
   (it does not replace the custom `lib/` or Kotlin sources), then
   `flutter pub get`.
3. Start the Stage 2 server (`../server/app.py`) and, on a device/emulator,
   `adb reverse tcp:8791 tcp:8791` so the app can reach it.
4. `flutter run` (debug) or `flutter build apk --release` (Stage 4 signing).

## Notes / honest gaps
- Map tiles in `start_screen.dart` are OSM dev tiles for local testing;
  production needs the licensed provider chosen by the Section 11 trial.
- Kingdom color selection, avatar upload, blocked-users management and the
  Market demo flag are Stage 4 polish items; the server endpoints and
  profile fields they need already exist.
