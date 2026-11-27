# Put the FP_OBSTRUCTIONS placement blockages back after global placement
# (odb_mesh_regions.py removes them so the placer does not charge their
# area to every region); detailed placement then keeps cells out of them.
import json

import click
import odb
from reader import click_odb


@click.command()
@click.option("--obstructions", required=True, help="FP_OBSTRUCTIONS as JSON: [[x0, y0, x1, y1], ...] um")
@click.option("--enabled", default=1, type=int)
@click_odb
def restore(reader, obstructions, enabled):
    if not enabled:
        print("[INFO] restore obstructions: mesh regions disabled; nothing to do")
        return
    block = reader.block
    dbu = block.getDefUnits()
    if list(block.getBlockages()):
        print(f"[INFO] restore obstructions: {len(list(block.getBlockages()))} blockages present; nothing to do")
        return
    boxes = json.loads(obstructions)
    for x0, y0, x1, y1 in boxes:
        odb.dbBlockage_create(block, *(int(round(v * dbu)) for v in (x0, y0, x1, y1)))
    print(f"[INFO] restore obstructions: {len(boxes)} placement blockages restored")


if __name__ == "__main__":
    restore()
