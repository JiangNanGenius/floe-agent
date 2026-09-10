import os
import sys

import zstandard
from zstandard import backend_c


def main():
    if os.environ.get("FLOE_SMOKE_HOST") != "1":
        assert sys.platform == "ios", sys.platform
    assert backend_c.__name__ == "zstandard.backend_c"
    payload = "数据-42".encode() * 64
    blob = zstandard.ZstdCompressor(level=3).compress(payload)
    assert zstandard.get_frame_parameters(blob).content_size == len(payload)
    assert zstandard.ZstdDecompressor().decompress(blob) == payload
    assert zstandard.decompress(zstandard.compress(payload, level=1)) == payload
    print("zstandard smoke OK", zstandard.__version__)


main()
