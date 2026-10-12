"""
Terrastep rules simulation — Section 10 scenarios, Stage 1 harness.

Runs synthetic walkers over a small Abbottabad-like cell grid for one
28-day season and reports: time to first claim, ownership concentration
(top-player share), turnover, and whether a mid-season newcomer can win
anything. Parameters come straight from referee/rules_v1.json.

Usage:  .venv/bin/python sim/simulate.py [num_players]
"""

import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from referee.engine import MICRO, Referee, Rules, ms, utc

try:
    from referee import h3_adapter

    if h3_adapter.AVAILABLE:
        CENTER = h3_adapter.cell_for(34.1688, 73.2215, 9)  # Abbottabad
        CELLS = [CENTER] + h3_adapter.neighbors(CENTER)
        AREA = {c: h3_adapter.cell_area_km2(c) for c in CELLS}
    else:
        raise ImportError
except Exception:
    CELLS = [f"cell{i}" for i in range(7)]
    AREA = {c: 0.1053 for c in CELLS}


def run(num_players: int = 20, seed: int = 7) -> dict:
    rng = random.Random(seed)
    rules = Rules.from_json(Path(__file__).resolve().parents[1] / "referee" / "rules_v1.json")
    ref = Referee(rules)
    start = ms(utc(2026, 10, 5, 2))  # 07:00 Asia/Karachi
    day_ms = 24 * 3600 * 1000

    players = [f"player{i:03d}" for i in range(num_players)]
    newcomer = "newcomer"
    first_claim_day: dict[str, int] = {}

    for day in range(rules.season_days):
        todays = players + ([newcomer] if day >= 14 else [])
        for user in todays:
            if rng.random() < 0.25:  # rest day
                continue
            minutes = rng.choice([15, 20, 30, 30, 45, 60, 120])  # incl. one volume profile
            if user == "player000":
                minutes = 120
            at = start + day * day_ms + rng.randrange(0, 3600_000)
            remaining = minutes
            while remaining > 0:
                chunk = min(remaining, rng.choice([5, 6, 10]))
                cell = rng.choice(CELLS)
                ref.accept(
                    user_id=user,
                    cell_id=cell,
                    session_id=f"{user}-d{day}",
                    activity_start_ms=at,
                    moving_duration_ms=chunk * 60_000,
                )
                remaining -= chunk
                at += chunk * 60_000
        owners = ref.evaluate_all(start + day * day_ms + 12 * 3600 * 1000)
        for user in owners.values():
            first_claim_day.setdefault(user, day + 1)

    end = start + rules.season_days * day_ms
    board = ref.territory_board(end, AREA)
    total_area = sum(r["area_km2"] for r in board)
    top_share = (board[0]["area_km2"] / total_area) if total_area else 0.0
    return {
        "players": num_players + 1,
        "owners_at_season_end": len(board),
        "total_owned_area_km2": round(total_area, 3),
        "top_player_area_share": round(top_share, 3),
        "newcomer_first_claim_day": first_claim_day.get(newcomer),
        "newcomer_on_final_board": any(r["user_id"] == newcomer for r in board),
        "median_first_claim_day": sorted(first_claim_day.values())[len(first_claim_day) // 2]
        if first_claim_day
        else None,
        "final_board_top5": [
            (r["user_id"], r["cells"], round(r["area_km2"], 3)) for r in board[:5]
        ],
    }


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    for k, v in run(n).items():
        print(f"{k}: {v}")
