# SPDX-License-Identifier: MPL-2.0
# Optional Ren'Py project-side registration API. The reviewed official Web
# runtime exposes restart and a real IDBFS flush, but this package has no
# verified general Python-store-to-JS command transport. This file therefore
# does NOT publish a fake descriptor or consume phantom commands. A project
# that adds an explicit transport can register bounded fields/actions here.

init python:
    class FloeDeveloperStore(object):
        version = "1.0.0"
        fields = {}
        actions = {}

        @classmethod
        def register(cls, descriptor):
            for field in descriptor.get("fields", []):
                if field.get("id") and callable(field.get("get")):
                    cls.fields[field["id"]] = field
            for action in descriptor.get("actions", []):
                if action.get("id") and callable(action.get("invoke")):
                    cls.actions[action["id"]] = action
            return True

        @classmethod
        def snapshot(cls):
            values = {}
            for key, field in cls.fields.items():
                try:
                    value = field["get"]()
                    if isinstance(value, (bool, int, float, str)):
                        values[key] = value
                except Exception:
                    pass
            return values

        @classmethod
        def restore(cls, values):
            for key, value in (values or {}).items():
                field = cls.fields.get(key)
                setter = field.get("set") if field else None
                if callable(setter):
                    try:
                        setter(value)
                    except Exception:
                        return False
            return True

        @classmethod
        def invoke(cls, action_id, arguments=None):
            action = cls.actions.get(action_id)
            if not action:
                return False
            try:
                return action["invoke"](arguments or {}) is not False
            except Exception:
                return False
