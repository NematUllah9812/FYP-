"""Fitness-math tests from Section 12, including the plan's worked example."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from referee.fitness import Fix, calories, filtered_distance_m, met_for_pace


def test_calorie_worked_example():
    """70 kg, 30 min, 3.8 MET -> about 140 gross kcal, about 103 active kcal."""
    out = calories(weight_kg=70, moving_minutes=30, met=3.8)
    assert out is not None
    assert abs(out["gross_kcal"] - 139.65) < 0.5
    assert abs(out["active_kcal"] - 103.0) < 1.5


def test_calories_hidden_without_weight():
    assert calories(weight_kg=None, moving_minutes=30, met=3.8) is None


def test_distance_straight_walk_and_jitter():
    # A straight 0.001-degree latitude walk north in 10 s steps (~111 m total).
    fixes = [Fix(t_ms=i * 10_000, lat=34.1688 + i * 0.00025, lng=73.2215, accuracy_m=5) for i in range(5)]
    distance, stats = filtered_distance_m(fixes)
    assert 100 < distance < 125
    assert stats["accepted_segments"] == 4
    # Add stationary jitter around the last point: must not inflate distance.
    jitter = fixes + [
        Fix(t_ms=50_000 + i * 5_000, lat=34.1698, lng=73.2215 + (0.000005 if i % 2 else -0.000005), accuracy_m=8)
        for i in range(4)
    ]
    distance2, stats2 = filtered_distance_m(jitter)
    assert abs(distance2 - distance) < 3.0
    assert stats2["jitter_segments"] >= 1


def test_distance_rejects_teleport_jump_and_gap():
    fixes = [
        Fix(t_ms=0, lat=34.1688, lng=73.2215, accuracy_m=5),
        Fix(t_ms=10_000, lat=34.2688, lng=73.2215, accuracy_m=5),  # ~11 km in 10 s: jump
        Fix(t_ms=200_000, lat=34.2689, lng=73.2215, accuracy_m=5),  # after long gap
    ]
    distance, stats = filtered_distance_m(fixes)
    assert distance == 0.0
    assert stats["jump_segments"] == 1
    assert stats["gap_segments"] == 1


def test_met_bands():
    assert met_for_pace(0.5) == 2.0
    assert met_for_pace(1.4) == 3.8
    assert met_for_pace(2.0) == 5.0
