"""
Terrastep fitness calculations — Section 12 of the Product & Technical Plan.

- Distance from filtered valid positions only: implausible jumps and
  stationary GPS jitter are excluded; long gaps become unknown segments
  (never straight-line evidence across unvisited cells).
- Calories are a documented MET-based estimate, never a measurement:
    gross kcal  = MET * 3.5 * weight_kg / 200 * minutes
    active kcal = gross - resting (1 MET) over the same period
  Worked check from the plan: 70 kg, 30 min, 3.8 MET -> ~140 gross, ~103 active.
- Base units are meters, milliseconds, kilograms (Section 12).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

EARTH_R_M = 6_371_000.0
MAX_PLAUSIBLE_SPEED_MPS = 3.5  # generous ceiling for walking; spikes above are jumps
MIN_SEGMENT_M = 3.0  # sub-3m segments are treated as stationary jitter
MAX_GAP_MS = 60_000  # longer gaps are unknown segments, not distance


@dataclass(frozen=True)
class Fix:
    t_ms: int
    lat: float
    lng: float
    accuracy_m: float


def haversine_m(a: Fix, b: Fix) -> float:
    p1, p2 = math.radians(a.lat), math.radians(b.lat)
    dp = math.radians(b.lat - a.lat)
    dl = math.radians(b.lng - a.lng)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R_M * math.asin(math.sqrt(h))


def filtered_distance_m(fixes: list[Fix]) -> tuple[float, dict]:
    """Return (distance_m, stats). Conservative by design (Section 12)."""
    distance = 0.0
    stats = {"accepted_segments": 0, "jitter_segments": 0, "jump_segments": 0, "gap_segments": 0}
    ordered = sorted(fixes, key=lambda f: f.t_ms)
    for prev, cur in zip(ordered, ordered[1:]):
        dt_ms = cur.t_ms - prev.t_ms
        if dt_ms <= 0:
            continue
        if dt_ms > MAX_GAP_MS:
            stats["gap_segments"] += 1
            continue
        d = haversine_m(prev, cur)
        if d < MIN_SEGMENT_M:
            stats["jitter_segments"] += 1
            continue
        speed = d / (dt_ms / 1000)
        if speed > MAX_PLAUSIBLE_SPEED_MPS:
            stats["jump_segments"] += 1
            continue
        distance += d
        stats["accepted_segments"] += 1
    return distance, stats


# Versioned pace -> MET model (illustrative conservative mapping, Section 12).
# The Stage 2 activity model must be validated against the 2024 Adult
# Compendium walking table for ages 19-59 before pilot use.
PACE_MET_MODEL_VERSION = "walk-met-prototype-1"
_PACE_BANDS = [  # (max pace m/s, MET)
    (0.9, 2.0),  # strolling
    (1.25, 3.0),  # ~4.5 km/h
    (1.55, 3.8),  # ~5.6 km/h, the plan's worked example band
    (1.85, 4.3),  # brisk
    (float("inf"), 5.0),  # very brisk uphill-equivalent ceiling for walking mode
]


def met_for_pace(pace_mps: float) -> float:
    for ceiling, met in _PACE_BANDS:
        if pace_mps <= ceiling:
            return met
    return _PACE_BANDS[-1][1]


def calories(*, weight_kg: float | None, moving_minutes: float, met: float) -> dict | None:
    """Estimated kcal, or None when inputs are absent (Section 12: hide, don't invent)."""
    if weight_kg is None or moving_minutes <= 0:
        return None
    gross = met * 3.5 * weight_kg / 200 * moving_minutes
    active = (met - 1.0) * 3.5 * weight_kg / 200 * moving_minutes
    return {
        "gross_kcal": gross,
        "active_kcal": active,
        "met": met,
        "model_version": PACE_MET_MODEL_VERSION,
        "label": "estimated active kcal",
    }
