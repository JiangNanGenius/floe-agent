import os
import sys

import greenlet
from greenlet import _greenlet


def main():
    if os.environ.get("FLOE_SMOKE_HOST") != "1":
        assert sys.platform == "ios", sys.platform
    assert _greenlet.greenlet is greenlet.greenlet
    log = []

    def worker(value):
        log.append(("worker", value))
        greenlet.getcurrent().parent.switch(value + 1)
        return value * 2

    child = greenlet.greenlet(worker)
    assert child.switch(41) == 42
    assert log == [("worker", 41)]
    assert child.switch() == 82
    print("greenlet smoke OK", greenlet.__version__)


main()
