"""Offline acceptance workload: must run in native CPython, not Pyodide."""
import io
import json
import sys
import pandas as pd

assert sys.platform == "ios", "Acceptance must execute inside native iOS CPython"
frame = pd.read_csv(io.StringIO("team,value\na,1\na,2\nb,4\n"))
assert frame.groupby("team")["value"].sum().to_dict() == {"a": 3, "b": 4}
assert frame.loc[frame["value"] > 1, "value"].tolist() == [2, 4]
merged = frame.merge(pd.DataFrame({"team": ["a", "b"], "label": ["A", "B"]}), on="team")
assert merged["label"].tolist() == ["A", "A", "B"]
assert pd.Series([1, None, 3]).fillna(0).tolist() == [1, 0, 3]
assert pd.to_datetime(["2026-09-07T00:00:00Z"], utc=True).tz_convert("Australia/Sydney")[0].hour == 10
assert pd.read_json(io.StringIO(frame.to_json())).equals(frame)
print(json.dumps({"runtime": sys.platform, "pandas": pd.__version__, "nativeSmoke": "passed"}))
