import sys

from pydantic_core import SchemaValidator


def main():
    assert sys.platform == "ios", sys.platform
    validator = SchemaValidator({"type": "dict", "keys_schema": {"type": "str"}, "values_schema": {"type": "int"}})
    assert validator.validate_python({"a": 1}) == {"a": 1}
    print("pydantic-core smoke OK")


main()
