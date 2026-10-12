"""
H3 geographic adapter — Section 11 of the plan.

Resolution 9 is the prototype competition resolution (avg cell ~0.1053 km2,
avg edge ~200.8 m). Resolution is never mixed within one competition.
Cell IDs cross API boundaries as text (Section 15).
"""

from __future__ import annotations

RESOLUTION = 9

try:
    import h3 as _h3

    AVAILABLE = True
except ImportError:  # pragma: no cover - exercised only without the h3 wheel
    _h3 = None
    AVAILABLE = False


def _require() -> None:
    if not AVAILABLE:
        raise RuntimeError("h3 package not installed; run inside the project venv")


def cell_for(lat: float, lng: float, resolution: int = RESOLUTION) -> str:
    _require()
    return _h3.latlng_to_cell(lat, lng, resolution)


def cell_area_km2(cell_id: str) -> float:
    _require()
    return _h3.cell_area(cell_id, unit="km^2")


def boundary_latlng(cell_id: str) -> list[tuple[float, float]]:
    _require()
    return list(_h3.cell_to_boundary(cell_id))


def neighbors(cell_id: str) -> list[str]:
    _require()
    return list(_h3.grid_disk(cell_id, 1))
