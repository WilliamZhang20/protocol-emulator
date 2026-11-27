"""
LibreLane plugin: tile-aware placement regions for the mesh chip
(odb_mesh_regions.py; FABRIC_REORG.md step 7). ``src/config.json`` inserts
the step before global placement when MESH_REGIONS is set:

    "meta": {"substituting_steps": {"+Odb.AddRoutingObstructions": "Project.MeshRegions"}}
"""
import os

from librelane.config import Variable
from librelane.steps import Step
from librelane.steps.odb import OdbpyStep

HERE = os.path.dirname(os.path.abspath(__file__))


@Step.factory.register()
class MeshRegions(OdbpyStep):
    id = "Project.MeshRegions"
    name = "Mesh Cell Placement Regions"

    config_vars = [
        Variable("MESH_REGIONS", bool, "Create the mesh cell regions (else the step changes nothing).", default=True),
        Variable("MESH_REGION_MARGIN", float, "Channel half-width between cell regions (um).", default=4.0),
        Variable("MESH_REGION_MAX_FANOUT", int, "Largest net the cell assignment walks through.", default=24),
    ]

    def get_script_path(self):
        return os.path.join(HERE, "odb_mesh_regions.py")

    def get_command(self):
        return super().get_command() + [
            "--margin", str(self.config["MESH_REGION_MARGIN"]),
            "--max-fanout", str(self.config["MESH_REGION_MAX_FANOUT"]),
            "--enabled", "1" if self.config["MESH_REGIONS"] else "0",
        ]


@Step.factory.register()
class RestoreObstructions(OdbpyStep):
    id = "Project.RestoreObstructions"
    name = "Restore Placement Obstructions"

    config_vars = [
        Variable("MESH_REGIONS", bool, "Create the mesh cell regions (else the step changes nothing).", default=True),
    ]

    def get_script_path(self):
        return os.path.join(HERE, "odb_restore_obstructions.py")

    def get_command(self):
        import json
        obs = self.config.get("FP_OBSTRUCTIONS") or []
        return super().get_command() + [
            "--obstructions", json.dumps([[float(v) for v in o] for o in obs]),
            "--enabled", "1" if self.config["MESH_REGIONS"] else "0",
        ]
