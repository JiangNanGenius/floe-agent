import os
import sys

import multidict
from multidict import CIMultiDict, MultiDict, MultiDictProxy, _multidict, istr


def main():
    if os.environ.get("FLOE_SMOKE_HOST") != "1":
        assert sys.platform == "ios", sys.platform
    assert MultiDict is _multidict.MultiDict
    headers = CIMultiDict({"Content-Type": "text/plain"})
    headers.add("content-type", "charset=utf-8")
    assert headers.getall("CONTENT-TYPE") == ["text/plain", "charset=utf-8"]
    pairs = MultiDict([("k", 1), ("k", 2)])
    assert pairs.getone("k") == 1
    typed_key = istr("Content-Type")
    assert str(typed_key) == "Content-Type"
    assert CIMultiDict({typed_key: "text/plain"})["content-type"] == "text/plain"
    proxy = MultiDictProxy(pairs)
    assert proxy.getall("k") == [1, 2]
    print("multidict smoke OK", multidict.__version__)


main()
