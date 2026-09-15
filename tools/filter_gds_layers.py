#!/usr/bin/env python3
"""Remove non-mask marker layers from a GDSII library without re-encoding it."""

import argparse
import struct
from pathlib import Path


ELEMENT_STARTS = {0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x15, 0x2D}
ENDEL = 0x11
LAYER = 0x0D
PURPOSE_RECORDS = {0x0E, 0x16, 0x2A, 0x2E}


def records(data: bytes) -> list[bytes]:
    result = []
    offset = 0
    while offset < len(data):
        if offset + 4 > len(data):
            raise ValueError(f"truncated GDS record header at byte {offset}")
        length = struct.unpack(">H", data[offset : offset + 2])[0]
        if length < 4 or offset + length > len(data):
            raise ValueError(f"invalid GDS record length {length} at byte {offset}")
        result.append(data[offset : offset + length])
        offset += length
    return result


def record_value(record: bytes) -> int:
    if len(record) < 6:
        raise ValueError("layer/purpose record has no 16-bit value")
    return struct.unpack(">h", record[4:6])[0]


def filter_layers(data: bytes, removed: set[tuple[int, int]]) -> tuple[bytes, int]:
    output: list[bytes] = []
    element: list[bytes] | None = None
    dropped = 0

    for record in records(data):
        record_type = record[2]
        if record_type in ELEMENT_STARTS:
            if element is not None:
                raise ValueError("nested GDS elements")
            element = [record]
        elif element is not None:
            element.append(record)
            if record_type == ENDEL:
                layer = next(
                    (record_value(item) for item in element if item[2] == LAYER), None
                )
                purpose = next(
                    (
                        record_value(item)
                        for item in element
                        if item[2] in PURPOSE_RECORDS
                    ),
                    None,
                )
                if (layer, purpose) in removed:
                    dropped += 1
                else:
                    output.extend(element)
                element = None
        else:
            output.append(record)

    if element is not None:
        raise ValueError("unterminated GDS element")
    return b"".join(output), dropped


def layer_pair(value: str) -> tuple[int, int]:
    try:
        layer, purpose = value.split("/", 1)
        return int(layer), int(purpose)
    except ValueError as error:
        raise argparse.ArgumentTypeError("layer must have LAYER/PURPOSE form") from error


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--remove", action="append", type=layer_pair, required=True)
    args = parser.parse_args()

    filtered, dropped = filter_layers(args.input.read_bytes(), set(args.remove))
    args.output.write_bytes(filtered)
    print(f"removed {dropped} elements from {args.input}")


if __name__ == "__main__":
    main()
