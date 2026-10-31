#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Focused offline tests for the Full protected-component manifest contract.

Synthetic facts only: no APK is built, signed, installed or read, and no SDK
tool is invoked. The tests pin the boundary added for G08:

* Full admits only the exact reviewed PhoneControl AccessibilityService and
  Floe system provider, under the exact full application ID and the explicit
  ``g08`` profile;
* every shape deviation still fails: class, permission, export, authority,
  accessibility action/meta-data binding, multiprocess, URI grants and extra
  accessibility declarations;
* the ``legacy`` Full profile keeps the pre-G08 strict boundary and never
  admits the protected components;
* Play has no exception at all, even for byte-identical reviewed components.

Run directly::

    PYTHONDONTWRITEBYTECODE=1 python3 \
        FloeAndroid/scripts/tests/test_check_apk_manifest_contract.py -v
"""

import importlib.util
import sys
import unittest
from pathlib import Path

CHECKER = Path(__file__).resolve().parents[1] / "check-apk.py"


def _load_checker():
    spec = importlib.util.spec_from_file_location(
        "floe_check_apk_manifest_under_test", CHECKER
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load check-apk.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


checker = _load_checker()

FULL_PACKAGE = "com.floe.agent.full"
FULL_DEBUG_PACKAGE = "com.floe.agent.full.dev"
PLAY_PACKAGE = "com.floe.agent"
PLAY_DEBUG_PACKAGE = "com.floe.agent.dev"


def meta(name=checker.ACCESSIBILITY_META, resource="@0x7f100000", value=None):
    return {"name": name, "resource": resource, "value": value}


def intent_filter(
    actions=(checker.ACCESSIBILITY_ACTION,),
    categories=(),
    data_count=0,
    other_children=(),
):
    return {
        "actions": list(actions),
        "categories": list(categories),
        "dataCount": data_count,
        "otherChildren": list(other_children),
    }


def service(
    name=checker.G08_FULL_ACCESSIBILITY_SERVICE,
    permission=checker.G08_FULL_ACCESSIBILITY_PERMISSION,
    exported="true",
    enabled=None,
    intent_filters=None,
    meta_data=None,
    child_tags=None,
):
    filters = [intent_filter()] if intent_filters is None else list(intent_filters)
    metas = [meta()] if meta_data is None else list(meta_data)
    if child_tags is None:
        child_tags = ["intent-filter"] * len(filters) + ["meta-data"] * len(metas)
    return {
        "tag": "service",
        "name": name,
        "permission": permission,
        "exported": exported,
        "enabled": enabled,
        "childTags": list(child_tags),
        "intentFilters": filters,
        "metaData": metas,
    }


def provider(
    package=FULL_PACKAGE,
    name=checker.G08_FULL_PROVIDER,
    permission=checker.G08_FULL_PROVIDER_PERMISSION,
    exported="true",
    multiprocess="false",
    authorities=None,
    grant_uri_permissions=None,
    child_tags=None,
):
    if authorities is None:
        authorities = [package + checker.G08_FULL_PROVIDER_AUTHORITY_SUFFIX]
    return {
        "tag": "provider",
        "name": name,
        "permission": permission,
        "exported": exported,
        "enabled": None,
        "childTags": list(child_tags or []),
        "intentFilters": [],
        "metaData": [],
        "authorities": list(authorities),
        "multiprocess": multiprocess,
        "grantUriPermissions": grant_uri_permissions,
    }


def activity(name="com.example.PlainActivity", permission=None, intent_filters=()):
    filters = list(intent_filters)
    return {
        "tag": "activity",
        "name": name,
        "permission": permission,
        "exported": "false",
        "enabled": None,
        "childTags": ["intent-filter"] * len(filters),
        "intentFilters": filters,
        "metaData": [],
    }


def receiver(name="com.example.PlainReceiver", permission=None, intent_filters=()):
    filters = list(intent_filters)
    return {
        "tag": "receiver",
        "name": name,
        "permission": permission,
        "exported": "false",
        "enabled": None,
        "childTags": ["intent-filter"] * len(filters),
        "intentFilters": filters,
        "metaData": [],
    }


def facts(
    package=FULL_PACKAGE,
    services=None,
    providers=None,
    activities=None,
    receivers=None,
    action_count=None,
    meta_count=None,
    extra_actions=(),
    extra_meta=(),
):
    if services is None:
        services = [service()]
    if providers is None:
        providers = [provider(package=package)]
    activities = list(activities or [])
    receivers = list(receivers or [])
    action_names = list(extra_actions)
    meta_names = list(extra_meta)
    for component in list(services) + activities + receivers:
        for intent in component.get("intentFilters") or []:
            action_names.extend(intent.get("actions") or [])
        for entry in component.get("metaData") or []:
            if entry.get("name"):
                meta_names.append(entry["name"])
    if action_count is None:
        action_count = sum(
            1 for name in action_names if name == checker.ACCESSIBILITY_ACTION
        )
    if meta_count is None:
        meta_count = sum(
            1 for name in meta_names if name == checker.ACCESSIBILITY_META
        )
    return {
        "package": package,
        "versionCode": "24",
        "versionName": "0.1.0-alpha.22",
        "minSdk": "28",
        "targetSdk": "37",
        "extractNativeLibs": "true" if checker.package_channel(package) == "full" else "false",
        "permissions": [],
        "declaredPermissions": [],
        "services": list(services),
        "activities": activities,
        "providers": list(providers),
        "receivers": receivers,
        "components": list(services) + activities + list(providers) + receivers,
        "actions": sorted(set(action_names)),
        "metaData": sorted(set(meta_names)),
        "accessibilityActionCount": action_count,
        "accessibilityMetaCount": meta_count,
    }


class BooleanTypingTests(unittest.TestCase):
    def test_literal_booleans_are_normalized_explicitly(self):
        self.assertIs(checker.typed_boolean("false"), False)
        self.assertIs(checker.typed_boolean("False"), False)
        self.assertIs(checker.typed_boolean("true"), True)
        self.assertIs(checker.typed_boolean(False), False)
        self.assertIs(checker.typed_boolean(True), True)
        self.assertIs(checker.typed_boolean("0"), False)
        self.assertIs(checker.typed_boolean("1"), True)
        self.assertIs(checker.typed_boolean("0x0"), False)
        self.assertIs(checker.typed_boolean("0x1"), True)

    def test_absent_or_referenced_booleans_are_not_coerced(self):
        self.assertIsNone(checker.typed_boolean(None))
        self.assertIsNone(checker.typed_boolean("@bool/exported"))
        self.assertIsNone(checker.typed_boolean("yes"))


class FullProtectedContractTests(unittest.TestCase):
    def assert_problem(self, problems, fragment):
        self.assertTrue(
            any(fragment in problem for problem in problems),
            "expected {!r} in {}".format(fragment, problems),
        )

    def test_exact_full_components_pass_both_full_checks(self):
        data = facts()
        self.assertEqual([], checker.forbidden_components(data, "full"))
        self.assertEqual([], checker.protected_components_problems(data))

    def test_protected_components_do_not_waive_forbidden_uses_permissions(self):
        data = facts()
        data["permissions"] = [
            checker.G08_FULL_ACCESSIBILITY_PERMISSION,
            "android.permission.WRITE_SECURE_SETTINGS",
        ]
        self.assertEqual(
            sorted(data["permissions"]), checker.forbidden_permissions(data)
        )

    def test_full_debug_package_identity_is_exact(self):
        data = facts(package=FULL_DEBUG_PACKAGE)
        self.assertEqual([], checker.channel_identity_problems("full", data))
        self.assertEqual([], checker.forbidden_components(data, "full"))
        self.assertEqual([], checker.protected_components_problems(data))

    def test_play_package_cannot_borrow_the_full_exception(self):
        data = facts(package=PLAY_PACKAGE)
        self.assertTrue(checker.channel_identity_problems("full", data))
        problems = checker.forbidden_components(data, "full")
        self.assert_problem(problems, "forbidden service name")
        self.assert_problem(problems, "forbidden platform component")
        self.assert_problem(problems, "occurrence(s)")

    def test_play_rejects_byte_identical_protected_components(self):
        problems = checker.forbidden_components(facts(), "play")
        self.assert_problem(problems, "forbidden service name")
        self.assert_problem(problems, "forbidden platform component")
        self.assert_problem(problems, "AccessibilityService occurrence(s)")
        self.assert_problem(problems, "accessibilityservice meta-data")

    def test_play_without_protected_components_remains_clean(self):
        data = facts(package=PLAY_PACKAGE, services=[], providers=[])
        self.assertEqual([], checker.channel_identity_problems("play", data))
        self.assertEqual([], checker.forbidden_components(data, "play"))

    def test_missing_protected_service_fails_presence_only(self):
        data = facts(services=[])
        self.assertEqual([], checker.forbidden_components(data, "full"))
        self.assert_problem(
            checker.protected_components_problems(data),
            "requires exactly one protected AccessibilityService",
        )

    def test_missing_protected_provider_fails_presence_only(self):
        data = facts(providers=[])
        self.assertEqual([], checker.forbidden_components(data, "full"))
        self.assert_problem(
            checker.protected_components_problems(data),
            "requires exactly one protected provider",
        )

    def test_wrong_service_class_fails(self):
        data = facts(
            services=[
                service(
                    name="com.floe.android.phonecontrol.OtherAccessibilityService"
                )
            ]
        )
        problems = checker.forbidden_components(data, "full")
        self.assert_problem(problems, "forbidden service name")
        self.assert_problem(
            checker.protected_components_problems(data),
            "requires exactly one protected AccessibilityService",
        )

    def test_service_missing_permission_fails(self):
        data = facts(services=[service(permission=None)])
        self.assert_problem(
            checker.protected_components_problems(data),
            "must declare android:permission="
            + checker.G08_FULL_ACCESSIBILITY_PERMISSION,
        )
        self.assert_problem(
            checker.forbidden_components(data, "full"), "forbidden service name"
        )

    def test_service_loosened_permission_fails(self):
        data = facts(
            services=[service(permission="android.permission.BIND_JOB_SERVICE")]
        )
        self.assert_problem(
            checker.protected_components_problems(data),
            "must declare android:permission="
            + checker.G08_FULL_ACCESSIBILITY_PERMISSION,
        )

    def test_service_exported_false_fails(self):
        data = facts(services=[service(exported="false")])
        self.assert_problem(
            checker.protected_components_problems(data),
            "must declare android:exported=true",
        )

    def test_service_exported_missing_fails(self):
        data = facts(services=[service(exported=None)])
        self.assert_problem(
            checker.protected_components_problems(data),
            "must declare android:exported=true",
        )

    def test_service_exported_reference_fails(self):
        data = facts(services=[service(exported="@bool/exported")])
        self.assert_problem(
            checker.protected_components_problems(data),
            "must declare android:exported=true",
        )

    def test_service_exported_typed_false_fails(self):
        data = facts(services=[service(exported=False)])
        self.assert_problem(
            checker.protected_components_problems(data),
            "must declare android:exported=true",
        )

    def test_extra_accessibility_action_fails(self):
        data = facts(
            services=[
                service(
                    intent_filters=[
                        intent_filter(
                            actions=(
                                checker.ACCESSIBILITY_ACTION,
                                "android.intent.action.VIEW",
                            )
                        )
                    ]
                )
            ]
        )
        self.assert_problem(
            checker.protected_components_problems(data),
            "intent-filter actions must be exactly",
        )
        self.assert_problem(
            checker.forbidden_components(data, "full"), "occurrence(s)"
        )

    def test_extra_intent_filter_fails(self):
        data = facts(
            services=[
                service(
                    intent_filters=[
                        intent_filter(),
                        intent_filter(actions=("android.intent.action.VIEW",)),
                    ]
                )
            ]
        )
        self.assert_problem(
            checker.protected_components_problems(data),
            "must declare exactly one intent-filter",
        )

    def test_intent_filter_categories_data_or_children_fail(self):
        for intent in (
            intent_filter(categories=("android.intent.category.DEFAULT",)),
            intent_filter(data_count=1),
            intent_filter(other_children=("property",)),
        ):
            with self.subTest(intent=intent):
                data = facts(services=[service(intent_filters=[intent])])
                self.assertTrue(checker.protected_components_problems(data))

    def test_extra_meta_data_or_wrong_name_or_resource_fails(self):
        cases = (
            (service(meta_data=[meta(), meta(name="com.example.other")]),
             "must declare exactly one meta-data"),
            (service(meta_data=[meta(name="com.example.other")]),
             "meta-data name must be exactly"),
            (service(meta_data=[meta(resource=None)]),
             "must declare a non-null android:resource reference"),
            (service(meta_data=[meta(resource="xml/floe")]),
             "must declare a non-null android:resource reference"),
            (service(meta_data=[meta(resource="@null")]),
             "must declare a non-null android:resource reference"),
            (service(meta_data=[meta(resource="@empty")]),
             "must declare a non-null android:resource reference"),
        )
        for candidate, fragment in cases:
            with self.subTest(fragment=fragment):
                data = facts(services=[candidate])
                self.assert_problem(
                    checker.protected_components_problems(data), fragment
                )

    def test_unexpected_service_child_element_fails(self):
        data = facts(
            services=[
                service(
                    child_tags=["intent-filter", "meta-data", "property"]
                )
            ]
        )
        self.assert_problem(
            checker.protected_components_problems(data),
            "must declare exactly one intent-filter and one meta-data",
        )

    def test_unprotected_service_with_same_action_fails(self):
        data = facts(
            services=[
                service(),
                service(
                    name="com.example.ObserverService",
                    permission=None,
                    meta_data=[],
                    intent_filters=[intent_filter()],
                ),
            ]
        )
        problems = checker.forbidden_components(data, "full")
        self.assert_problem(problems, "occurrence(s)")
        self.assertEqual([], checker.protected_components_problems(data))

    def test_accessibility_action_on_activity_fails(self):
        data = facts(
            activities=[
                activity(intent_filters=[intent_filter()])
            ]
        )
        self.assert_problem(
            checker.forbidden_components(data, "full"), "occurrence(s)"
        )

    def test_accessibility_meta_outside_the_service_fails(self):
        data = facts(meta_count=2)
        self.assert_problem(
            checker.forbidden_components(data, "full"),
            "accessibilityservice meta-data occurrence(s)",
        )

    def test_provider_wrong_authority_fails(self):
        data = facts(
            providers=[
                provider(authorities=[FULL_PACKAGE + ".floe.system.other"])
            ]
        )
        self.assert_problem(
            checker.protected_components_problems(data),
            "authorities must be exactly",
        )
        self.assert_problem(
            checker.forbidden_components(data, "full"), "forbidden platform component"
        )

    def test_provider_extra_authority_fails(self):
        data = facts(
            providers=[
                provider(
                    authorities=[
                        FULL_PACKAGE + ".floe.system",
                        FULL_PACKAGE + ".floe.system.extra",
                    ]
                )
            ]
        )
        self.assert_problem(
            checker.protected_components_problems(data),
            "authorities must be exactly",
        )

    def test_provider_missing_or_wrong_permission_fails(self):
        for permission in (None, "android.permission.BIND_JOB_SERVICE"):
            with self.subTest(permission=permission):
                data = facts(providers=[provider(permission=permission)])
                self.assert_problem(
                    checker.protected_components_problems(data),
                    "must declare android:permission="
                    + checker.G08_FULL_PROVIDER_PERMISSION,
                )

    def test_provider_read_write_permission_overrides_fail(self):
        for attribute in ("readPermission", "writePermission"):
            for value in ("", "android.permission.INTERNET",
                          checker.G08_FULL_PROVIDER_PERMISSION):
                with self.subTest(attribute=attribute, value=value):
                    item = provider()
                    item[attribute] = value
                    data = facts(providers=[item])
                    self.assert_problem(
                        checker.protected_components_problems(data),
                        "must not override android:" + attribute,
                    )
                    self.assertTrue(checker.forbidden_components(data, "full"))

    def test_provider_exported_false_or_missing_fails(self):
        for exported in ("false", None, "@bool/exported"):
            with self.subTest(exported=exported):
                data = facts(providers=[provider(exported=exported)])
                self.assert_problem(
                    checker.protected_components_problems(data),
                    "must declare android:exported=true",
                )

    def test_provider_multiprocess_must_be_explicitly_false(self):
        for multiprocess in ("true", None, "@bool/multiprocess"):
            with self.subTest(multiprocess=multiprocess):
                data = facts(providers=[provider(multiprocess=multiprocess)])
                self.assert_problem(
                    checker.protected_components_problems(data),
                    "must explicitly declare android:multiprocess=false",
                )

    def test_provider_typed_booleans_are_accepted(self):
        data = facts(
            providers=[
                provider(
                    exported=True,
                    multiprocess=False,
                    grant_uri_permissions=False,
                )
            ]
        )
        self.assertEqual([], checker.protected_components_problems(data))
        self.assertEqual([], checker.forbidden_components(data, "full"))

    def test_provider_uri_grant_or_child_fails(self):
        cases = (
            (provider(grant_uri_permissions="true"), "must not grant URI permissions"),
            (provider(grant_uri_permissions="@bool/grant"),
             "grantUriPermissions must be a literal boolean"),
            (provider(child_tags=["grant-uri-permission"]),
             "must not declare child elements"),
            (provider(child_tags=["path-permission"]),
             "must not declare child elements"),
        )
        for candidate, fragment in cases:
            with self.subTest(fragment=fragment):
                data = facts(providers=[candidate])
                self.assert_problem(
                    checker.protected_components_problems(data), fragment
                )

    def test_reserved_authority_on_another_provider_fails(self):
        data = facts(
            providers=[
                provider(),
                provider(
                    name="com.example.OtherProvider",
                    permission=None,
                    authorities=[FULL_PACKAGE + ".floe.system"],
                ),
            ]
        )
        self.assertEqual([], checker.protected_components_problems(data))
        self.assert_problem(
            checker.forbidden_components(data, "full"),
            "is reserved for the exact Full provider",
        )

    def test_unknown_root_and_shizuku_components_fail(self):
        data = facts(
            services=[
                service(),
                service(
                    name="com.example.ShizukuBridgeService",
                    permission=None,
                    intent_filters=[],
                    meta_data=[],
                ),
            ],
            providers=[
                provider(),
                provider(
                    name="com.example.RootSystemProvider",
                    permission=None,
                    authorities=["com.example.rootsystem"],
                ),
            ],
        )
        problems = checker.forbidden_components(data, "full")
        self.assert_problem(problems, "com.example.ShizukuBridgeService")
        self.assert_problem(problems, "com.example.RootSystemProvider")

    def test_protected_only_permission_on_other_component_fails(self):
        data = facts(
            services=[
                service(),
                service(
                    name="com.example.PrivilegedService",
                    permission=checker.G08_FULL_PROVIDER_PERMISSION,
                    intent_filters=[],
                    meta_data=[],
                ),
            ]
        )
        self.assert_problem(
            checker.forbidden_components(data, "full"),
            "protected component permission",
        )


class LegacyFullProfileTests(unittest.TestCase):
    def assert_problem(self, problems, fragment):
        self.assertTrue(
            any(fragment in problem for problem in problems),
            "expected {!r} in {}".format(fragment, problems),
        )

    def test_legacy_does_not_require_or_admit_protected_components(self):
        plain = facts(services=[], providers=[])
        self.assertEqual([], checker.protected_components_problems(plain, "legacy"))
        self.assertEqual(
            [], checker.forbidden_components(plain, "full", "legacy")
        )
        protected = facts()
        self.assertEqual(
            [], checker.protected_components_problems(protected, "legacy")
        )
        self.assert_problem(
            checker.forbidden_components(protected, "full", "legacy"),
            "forbidden service name",
        )

    def test_unknown_profile_is_rejected(self):
        with self.assertRaises(checker.CheckError):
            checker.protected_components_problems(facts(), "unknown")
        with self.assertRaises(checker.CheckError):
            checker.forbidden_components(facts(), "full", "unknown")


class ChannelIdentityTests(unittest.TestCase):
    def test_exact_package_identities(self):
        self.assertEqual("full", checker.package_channel(FULL_PACKAGE))
        self.assertEqual("full", checker.package_channel(FULL_DEBUG_PACKAGE))
        self.assertEqual("play", checker.package_channel(PLAY_PACKAGE))
        self.assertEqual("play", checker.package_channel(PLAY_DEBUG_PACKAGE))
        self.assertIsNone(checker.package_channel("com.floe.agent.full.debug"))
        self.assertIsNone(checker.package_channel("com.example.full"))

    def test_channel_slot_must_match_actual_package(self):
        full = facts()
        self.assertEqual([], checker.channel_identity_problems("full", full))
        self.assert_problem(
            checker.channel_identity_problems("play", full),
            "but the play slot was checked",
        )
        play = facts(package=PLAY_PACKAGE, services=[], providers=[])
        self.assertEqual([], checker.channel_identity_problems("play", play))
        self.assert_problem(
            checker.channel_identity_problems("full", play),
            "but the full slot was checked",
        )

    def assert_problem(self, problems, fragment):
        self.assertTrue(
            any(fragment in problem for problem in problems),
            "expected {!r} in {}".format(fragment, problems),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
