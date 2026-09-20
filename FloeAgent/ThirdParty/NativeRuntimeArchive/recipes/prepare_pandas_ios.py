"""Mechanical cross-build patch for the SHA-pinned pandas source distribution.

Meson needs target NumPy headers, not execution of iOS NumPy on the macOS host.
No runtime pandas or NumPy behavior is patched.
"""
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
path = root / "pandas/meson.build"
source = path.read_text()
assert source.count("import numpy as np") == 1
assert source.count("np.get_include()") == 2
source = source.replace("import numpy as np", """import importlib.util
from pathlib import Path
spec = importlib.util.find_spec('numpy')
assert spec is not None and spec.origin is not None
numpy_include = str(Path(spec.origin).parent / '_core' / 'include')
assert (Path(numpy_include) / 'numpy' / 'arrayobject.h').is_file()""")
source = source.replace("np.get_include()", "numpy_include")
path.write_text(source)
