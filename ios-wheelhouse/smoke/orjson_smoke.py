import sys

import orjson


def main():
    assert sys.platform == "ios", sys.platform
    payload = {"name": "数据", "values": [1, 2, 3], "π": 3.14}
    assert orjson.loads(orjson.dumps(payload)) == payload
    assert orjson.dumps({"k": "v"}, option=orjson.OPT_SORT_KEYS) == b'{"k":"v"}'
    print("orjson smoke OK")


main()
