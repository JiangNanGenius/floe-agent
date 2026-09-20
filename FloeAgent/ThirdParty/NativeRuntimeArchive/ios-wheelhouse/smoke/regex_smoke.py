import sys

import regex


def main():
    assert sys.platform == "ios", sys.platform
    match = regex.fullmatch(r"(\p{L}+)-(\d+)", "数据-42")
    assert match and match.groups() == ("数据", "42")
    assert regex.sub(r"\s+", " ", "a  b\tc") == "a b c"
    print("regex smoke OK", regex.__version__ if hasattr(regex, "__version__") else "")


main()
