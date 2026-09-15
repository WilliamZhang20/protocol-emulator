"""Stable event vocabulary shared by future models and scoreboards."""

from dataclasses import dataclass
from enum import Enum, auto


class EventKind(Enum):
    """Externally observable engine actions."""

    INSTRUCTION = auto()
    GPIO_WRITE = auto()
    GPIO_OE_WRITE = auto()
    FIFO_PUSH = auto()
    FIFO_POP = auto()
    STALL = auto()


@dataclass(frozen=True)
class TraceEvent:
    """One timestamped action emitted by a reference model or monitor."""

    cycle: int
    kind: EventKind
    value: int = 0
    mask: int = 0
