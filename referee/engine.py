"""
Terrastep authoritative referee — Stage 1 reference implementation.

Implements the prototype ruleset in Section 9 of the Terrastep Product and
Technical Plan exactly, in fixed-point micro-points (1 point = 1_000_000
micro-points; 1 point = 1 eligible moving minute after caps).

Design notes (from Sections 9, 10, 17 of the plan):
- Contributions are an immutable accepted ledger; scores are derived.
- Caps are applied at acceptance time, in acceptance order, against the
  activity's league-local day (Asia/Karachi for the pilot).
- Effective score decays linearly to zero over 7 rolling days.
- Ownership is evaluated deterministically: no randomness anywhere.
  Tie-breaks: highest score, then earliest accepted contribution, then
  stable account ID.
- This module is transport-independent (Section 14): the Stage 2 server will
  run the same logic inside a Postgres transaction with row locks.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

MICRO = 1_000_000
MS_PER_MINUTE = 60_000
MS_PER_DAY = 86_400_000


def points_to_micro(points: float) -> int:
    return int(round(points * MICRO))


def duration_ms_to_micro(duration_ms: int) -> int:
    """1 point per eligible moving minute (Section 9 base earning)."""
    return duration_ms * MICRO // MS_PER_MINUTE


@dataclass(frozen=True)
class Rules:
    rules_version: str = "v1"
    points_per_moving_minute: int = 1
    per_cell_daily_cap_points: float = 6
    per_user_daily_cap_points: float = 45
    contribution_lifetime_days: int = 7
    neutral_cell_threshold_points: float = 2
    ownership_release_below_points: float = 1
    takeover_margin_min_points: float = 2
    takeover_margin_fraction_of_owner: float = 0.20
    offline_upload_grace_hours: int = 24
    season_days: int = 28
    league_timezone: str = "Asia/Karachi"
    h3_resolution: int = 9

    @classmethod
    def from_json(cls, path: str | Path) -> "Rules":
        data = json.loads(Path(path).read_text())
        known = {f.name for f in cls.__dataclass_fields__.values()}  # type: ignore[attr-defined]
        return cls(**{k: v for k, v in data.items() if k in known})

    @property
    def tz(self) -> ZoneInfo:
        return ZoneInfo(self.league_timezone)

    @property
    def cell_cap_micro(self) -> int:
        return points_to_micro(self.per_cell_daily_cap_points)

    @property
    def user_cap_micro(self) -> int:
        return points_to_micro(self.per_user_daily_cap_points)

    @property
    def neutral_threshold_micro(self) -> int:
        return points_to_micro(self.neutral_cell_threshold_points)

    @property
    def release_below_micro(self) -> int:
        return points_to_micro(self.ownership_release_below_points)

    @property
    def lifetime_ms(self) -> int:
        return self.contribution_lifetime_days * MS_PER_DAY


@dataclass
class Contribution:
    """One immutable accepted ledger entry (Section 15: contributions)."""

    seq: int  # global acceptance order
    user_id: str
    cell_id: str  # H3 ID as text (Section 15: text at API boundaries)
    session_id: str
    activity_start_ms: int  # UTC epoch ms of the credited interval start
    activity_end_ms: int
    credited_micro: int  # after caps; may be less than requested
    league_day: str  # ISO date in the league time zone


@dataclass
class Acceptance:
    requested_micro: int
    credited_micro: int
    cap_reason: str | None  # None, "cell_daily_cap", "user_daily_cap", "both_caps"
    contribution: Contribution | None  # None when nothing was credited


@dataclass
class Referee:
    rules: Rules = field(default_factory=Rules)
    _ledger: list[Contribution] = field(default_factory=list)
    _owners: dict[str, str] = field(default_factory=dict)  # cell_id -> user_id
    _seq: int = 0

    # ---------- helpers ----------

    def league_day_of(self, epoch_ms: int) -> str:
        dt = datetime.fromtimestamp(epoch_ms / 1000, tz=timezone.utc)
        return dt.astimezone(self.rules.tz).date().isoformat()

    # ---------- acceptance (Section 17 atomic procedure, steps 3-5) ----------

    def _used_on_day(self, user_id: str, league_day: str, cell_id: str | None) -> int:
        return sum(
            c.credited_micro
            for c in self._ledger
            if c.user_id == user_id
            and c.league_day == league_day
            and (cell_id is None or c.cell_id == cell_id)
        )

    def accept(
        self,
        *,
        user_id: str,
        cell_id: str,
        session_id: str,
        activity_start_ms: int,
        moving_duration_ms: int,
    ) -> Acceptance:
        """Credit verified moving time to a cell, applying Section 9 caps.

        Callers (Stage 2 ingest) must pass only verified eligible intervals;
        verification of evidence itself lives in the ingest layer (Sections
        17-18). Splitting an interval that crosses a league-day boundary is
        the caller's job, so no second is ever counted twice.
        """
        if moving_duration_ms < 0:
            raise ValueError("duration must be non-negative")
        requested = duration_ms_to_micro(moving_duration_ms)
        league_day = self.league_day_of(activity_start_ms)

        cell_room = self.rules.cell_cap_micro - self._used_on_day(user_id, league_day, cell_id)
        user_room = self.rules.user_cap_micro - self._used_on_day(user_id, league_day, None)
        credited = max(0, min(requested, cell_room, user_room))

        reasons = []
        if credited < requested:
            if cell_room <= user_room and cell_room < requested:
                reasons.append("cell_daily_cap")
            if user_room <= cell_room and user_room < requested:
                reasons.append("user_daily_cap")
        cap_reason = None
        if reasons:
            cap_reason = "both_caps" if len(reasons) == 2 else reasons[0]
            if reasons == ["cell_daily_cap", "user_daily_cap"]:
                cap_reason = "both_caps"

        contribution = None
        if credited > 0:
            self._seq += 1
            contribution = Contribution(
                seq=self._seq,
                user_id=user_id,
                cell_id=cell_id,
                session_id=session_id,
                activity_start_ms=activity_start_ms,
                activity_end_ms=activity_start_ms + moving_duration_ms,
                credited_micro=credited,
                league_day=league_day,
            )
            self._ledger.append(contribution)
        return Acceptance(requested, credited, cap_reason, contribution)

    # ---------- scoring (Section 9 formula) ----------

    def effective_score_micro(self, user_id: str, cell_id: str, at_ms: int) -> int:
        """S(user, cell, t) = SUM p(j) * MAX(0, 1 - age_days / 7)."""
        total = 0
        for c in self._ledger:
            if c.user_id != user_id or c.cell_id != cell_id:
                continue
            age_ms = at_ms - c.activity_start_ms
            if age_ms < 0:
                continue  # future-dated evidence never scores early
            remaining = self.rules.lifetime_ms - age_ms
            if remaining <= 0:
                continue
            total += c.credited_micro * remaining // self.rules.lifetime_ms
        return total

    def _first_contribution_key(self, user_id: str, cell_id: str) -> tuple[int, int]:
        """(activity time, acceptance sequence) of the user's earliest credit."""
        entries = [
            c
            for c in self._ledger
            if c.user_id == user_id and c.cell_id == cell_id and c.credited_micro > 0
        ]
        if not entries:
            return (0, 0)
        first = min(entries, key=lambda c: (c.activity_start_ms, c.seq))
        return (first.activity_start_ms, first.seq)

    def scores_for_cell(self, cell_id: str, at_ms: int) -> dict[str, int]:
        users = {c.user_id for c in self._ledger if c.cell_id == cell_id}
        return {
            u: s
            for u in users
            if (s := self.effective_score_micro(u, cell_id, at_ms)) > 0
        }

    # ---------- ownership (Section 9 owner-selection rule) ----------

    def evaluate_ownership(self, cell_id: str, at_ms: int) -> str | None:
        """Recompute and store the owner of one cell at time `at_ms`.

        Deterministic: highest score wins; ties broken by earliest accepted
        contribution, then stable account ID. Incumbent hysteresis: a
        challenger must exceed the owner by MAX(2 pts, 20% of owner score).
        An incumbent below the release floor (1 pt) loses the cell, which is
        then awarded by the neutral rule (highest score >= 2 pts).
        """
        scores = self.scores_for_cell(cell_id, at_ms)
        incumbent = self._owners.get(cell_id)
        incumbent_score = scores.get(incumbent, 0) if incumbent else 0

        def rank_key(user_id: str) -> tuple[int, int, int, str]:
            # Sort ascending: highest score, earliest contribution time,
            # earliest acceptance, then stable account ID (Section 9).
            first_ms, first_seq = self._first_contribution_key(user_id, cell_id)
            return (-scores[user_id], first_ms, first_seq, user_id)

        if incumbent and incumbent_score >= self.rules.release_below_micro:
            challengers = [u for u in scores if u != incumbent]
            if challengers:
                best = min(challengers, key=rank_key)
                margin = max(
                    points_to_micro(self.rules.takeover_margin_min_points),
                    int(incumbent_score * self.rules.takeover_margin_fraction_of_owner),
                )
                if scores[best] >= incumbent_score + margin:
                    self._owners[cell_id] = best
                    return best
            return incumbent

        # Neutral / released cell.
        if scores:
            best = min(scores, key=rank_key)
            if scores[best] >= self.rules.neutral_threshold_micro:
                self._owners[cell_id] = best
                return best
        self._owners.pop(cell_id, None)
        return None

    def owner_of(self, cell_id: str) -> str | None:
        return self._owners.get(cell_id)

    def evaluate_all(self, at_ms: int) -> dict[str, str]:
        cells = {c.cell_id for c in self._ledger} | set(self._owners)
        for cell in cells:
            self.evaluate_ownership(cell, at_ms)
        return dict(self._owners)

    # ---------- boards (Section 10) ----------

    def territory_board(self, at_ms: int, cell_area_km2: dict[str, float]) -> list[dict]:
        """Rank by owned area, then cell count, then stable account ID."""
        owners = self.evaluate_all(at_ms)
        per_user: dict[str, list[str]] = {}
        for cell, user in owners.items():
            per_user.setdefault(user, []).append(cell)
        rows = [
            {
                "user_id": u,
                "cells": len(cells),
                "area_km2": sum(cell_area_km2.get(c, 0.0) for c in cells),
            }
            for u, cells in per_user.items()
        ]
        rows.sort(key=lambda r: (-r["area_km2"], -r["cells"], r["user_id"]))
        return rows

    @property
    def ledger(self) -> list[Contribution]:
        return list(self._ledger)

    @property
    def owners(self) -> dict[str, str]:
        return dict(self._owners)

    def restore(self, contributions: list[Contribution], owners: dict[str, str]) -> None:
        """Load a persisted ledger (Stage 2 server boot / replay)."""
        self._ledger = sorted(contributions, key=lambda c: c.seq)
        self._owners = dict(owners)
        self._seq = self._ledger[-1].seq if self._ledger else 0


def ms(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)


def utc(year: int, month: int, day: int, hour: int = 12, minute: int = 0) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=timezone.utc)
