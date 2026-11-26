"""Fold plain sequencer row pairs into descriptor rows.

Both folds are exact: the descriptor runs cycle for cycle like the two rows
it replaces (see grid_sequencer.v).

- phases {1,1,01,a0,a1,event,0}: a wait on `event` with action a0 that
  continues into a wait on the same event with action a1.
- entry-wait {1,1,10,pulse,hold,event,0}: an always row with action `pulse`
  that continues into a wait on `event` with action `hold`.

A pair folds only when nothing else enters its second row and that row
continues to the row after it, so the descriptor can fall through.
"""


def _fields(word):
    return word >> 15, (word >> 11) & 15, (word >> 7) & 15, (word >> 4) & 7, word & 15


def fold(rows, entry=0):
    rows = list(rows)
    n = len(rows)
    entered = {}
    for i, word in enumerate(rows):
        halt, no, yes, _, _ = _fields(word)
        if halt:
            continue
        for target in {no, yes} - {i}:
            entered.setdefault(target, set()).add(i)
    folded = {}
    i = 0
    while i < n - 1:
        ha, na, ya, ea, aa = _fields(rows[i])
        hb, nb, yb, eb, ab = _fields(rows[i + 1])
        pair = (not ha and not hb and i + 1 != entry and entered.get(i + 1, set()) <= {i}
                and nb == i + 1 and yb == i + 2)
        if pair and na == i and ya == i + 1 and ea == eb and ea != 0:
            folded[i] = 0xD000 | aa << 8 | ab << 4 | eb << 1
            i += 2
            continue
        if pair and ea == 0 and na == ya == i + 1 and eb != 0:
            folded[i] = 0xE000 | aa << 8 | ab << 4 | eb << 1
            i += 2
            continue
        i += 1
    keep = [k for k in range(n) if k - 1 not in folded]
    index = {old: new for new, old in enumerate(keep)}
    out = []
    for old in keep:
        if old in folded:
            out.append(folded[old])
            continue
        halt, no, yes, event, action = _fields(rows[old])
        out.append(rows[old] if halt else index[no] << 11 | index[yes] << 7 | event << 4 | action)
    return out
