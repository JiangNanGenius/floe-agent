import sys

import yaml


def main():
    assert sys.platform == "ios", sys.platform
    doc = yaml.safe_load("name: 数据\nitems: [1, 2, 3]\n")
    assert doc == {"name": "数据", "items": [1, 2, 3]}
    assert yaml.safe_load(yaml.dump(doc)) == doc
    print("pyyaml smoke OK", yaml.__version__)


main()
