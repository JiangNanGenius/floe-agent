"""Exercise the actual embedded runner source, without linking iOS CPython."""
import ast
import json
from pathlib import Path
import re
import unittest


class EmbeddedOutputTests(unittest.TestCase):
    def run_script(self, script, cap=16):
        source = (Path(__file__).resolve().parents[2] /
                  "FloeApp/Execution/FloeCPythonBridge.m").read_text()
        fragment = source.split("static const char *runner =", 1)[1].split(
            "PyObject *execution =", 1)[0]
        runner = "".join(ast.literal_eval(literal) for literal in
                         re.findall(r'^\s*("(?:[^"\\]|\\.)*")', fragment, re.MULTILINE))
        state = {
            "_floe_script": script, "_floe_input_json": "null",
            "_floe_context_json": "{}", "_floe_timeout": 5,
            "_floe_cap": cap, "_floe_is_cancelled": lambda: False,
        }
        exec(compile(runner, "embedded-runner", "exec"), state)
        return state, json.loads(state["_floe_result"])

    def test_repeated_output_does_not_retain_empty_chunks_after_limit(self):
        state, result = self.run_script("for _ in range(20000): print('x')")
        self.assertEqual(result["status"], "ok")
        self.assertEqual(len(result["stdout"].encode()), 16)
        self.assertTrue(result["truncated"])
        self.assertLessEqual(len(state["_floe_out"].parts), 16)

    def test_stdout_and_stderr_share_the_byte_limit(self):
        _, result = self.run_script("import sys; print('中文'); print('error' * 10, file=sys.stderr)", cap=10)
        self.assertEqual(result["stdout"], "中文\n")
        self.assertEqual(result["stderr"], "err")
        self.assertTrue(result["stderrTruncated"])


if __name__ == "__main__":
    unittest.main()
