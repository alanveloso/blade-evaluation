"""Condition order of the frozen matrices (read-only view of experiment/config/*_matrix.json)."""
import json
from pathlib import Path

_CFG = Path(__file__).resolve().parents[2] / "experiment" / "config"
PRIMARY_IDS = [c["condition_id"] for c in json.loads((_CFG / "primary_matrix.json").read_text())["conditions"]]
SECONDARY_IDS = [c["condition_id"] for c in json.loads((_CFG / "secondary_matrix.json").read_text())["conditions"]]
