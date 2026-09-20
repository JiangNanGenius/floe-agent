#!/usr/bin/env python3
"""xml2/xslt-config facade evaluated inside cibuildwheel's target environment."""
import os
from pathlib import Path
import sys
import sysconfig


def settings(platform, root, xslt):
    if platform.startswith("ios-") and platform.endswith("-arm64-iphonesimulator"):
        sdk = "iphonesimulator"
    elif platform.startswith("ios-") and platform.endswith("-arm64-iphoneos"):
        sdk = "iphoneos"
    else:
        raise ValueError(f"Refusing non-iOS or unknown lxml target: {platform}")
    prefix = root / "floe-native" / sdk
    return {"--version": "1.1.45" if xslt else "2.14.6",
            "--cflags": f"-I{prefix}/include -I{prefix}/include/libxml2",
            "--libs": f"-L{prefix}/lib -lxslt -lexslt -lxml2 -liconv -lz -lm"}


if __name__ == "__main__":
    values = settings(os.environ.get("_PYTHON_HOST_PLATFORM") or sysconfig.get_platform(),
                      Path(__file__).resolve().parent, "xslt" in Path(sys.argv[0]).name)
    if len(sys.argv) != 2 or sys.argv[1] not in values:
        raise SystemExit("Unsupported XML build configuration request")
    print(values[sys.argv[1]])
