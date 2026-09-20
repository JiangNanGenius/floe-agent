import os
import sys

import _brotli
import brotli


def main():
    if os.environ.get("FLOE_SMOKE_HOST") != "1":
        assert sys.platform == "ios", sys.platform
    assert brotli.__version__ == _brotli.__version__
    payload = "数据-42".encode() * 64
    assert brotli.decompress(brotli.compress(payload, quality=5)) == payload
    compressor = brotli.Compressor(quality=5)
    blob = compressor.process(payload[:100]) + compressor.process(payload[100:]) + compressor.finish()
    assert brotli.decompress(blob) == payload
    print("brotli smoke OK", brotli.__version__)


main()
