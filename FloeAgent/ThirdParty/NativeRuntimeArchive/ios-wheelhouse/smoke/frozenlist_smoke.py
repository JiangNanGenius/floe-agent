import os
import sys

import frozenlist
from frozenlist import FrozenList, _frozenlist


def main():
    if os.environ.get("FLOE_SMOKE_HOST") != "1":
        assert sys.platform == "ios", sys.platform
    assert FrozenList is _frozenlist.FrozenList
    items = FrozenList(["数据", 1])
    items.append(42)
    assert list(items) == ["数据", 1, 42]
    items.freeze()
    assert items.frozen
    try:
        items.append(0)
    except RuntimeError:
        pass
    else:
        raise AssertionError("frozen list accepted append")
    assert items.index(42) == 2
    print("frozenlist smoke OK", frozenlist.__version__)


main()
