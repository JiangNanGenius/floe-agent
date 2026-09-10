import sys

from markupsafe import Markup, escape


def main():
    assert sys.platform == "ios", sys.platform
    assert str(escape("<b>数据</b>")) == "&lt;b&gt;数据&lt;/b&gt;"
    assert Markup("<em>{}</em>").format("ok") == Markup("<em>ok</em>")
    print("markupsafe smoke OK")


main()
