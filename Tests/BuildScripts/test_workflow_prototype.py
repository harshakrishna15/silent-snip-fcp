import copy
import importlib.util
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
import zlib


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/check-workflow-prototype.py"
SPEC = importlib.util.spec_from_file_location("workflow_prototype_package", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def write_macho(path, *, bootstrap=False, wrong_entry=False, library=None,
                debug_bootstrap_record=False, duplicate_definition=False):
    address = 0x100000000
    segment = struct.pack("<II16sQQQQiiII", 0x19, 72, b"__TEXT", address, 1024, 0, 1024, 7, 5, 0, 0)
    symbol_name = b"_ProExtensionMain" if bootstrap else b"_main"
    strings = b"\0" + symbol_name + b"\0"
    symbol_count = 2 if debug_bootstrap_record or duplicate_definition else 1
    string_offset = 512 + symbol_count * 16
    symtab = struct.pack("<6I", 0x2, 24, 512, symbol_count, string_offset, len(strings))
    entry = struct.pack("<IIQQ", 0x80000028, 24, 384 + (8 if wrong_entry else 0), 0)
    name = (library or "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit").encode() + b"\0"
    size = (24 + len(name) + 7) // 8 * 8
    dylib = struct.pack("<6I", 0xC, size, 24, 0, 0, 0) + name
    dylib += b"\0" * (size - len(dylib))
    commands = segment + symtab + entry + dylib
    image = bytearray(1024)
    image[:32] = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 4, len(commands), 0, 0)
    image[32:32+len(commands)] = commands
    if symbol_count == 2:
        image[512:528] = struct.pack("<IBBHQ", 1, 0x24 if debug_bootstrap_record else 0xF,
                                    1, 0, address + 384)
    actual_symbol_offset = 512 + (symbol_count - 1) * 16
    image[actual_symbol_offset:actual_symbol_offset+16] = struct.pack("<IBBHQ", 1, 0xF, 1, 0, address + 384)
    image[string_offset:string_offset+len(strings)] = strings
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(image)
    path.chmod(0o755)


def icon_png(pixels):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    header = struct.pack(">IIBBBBB", pixels, pixels, 8, 6, 0, 0, 0)
    rows = (b"\0" + b"\0\0\0\0" * pixels) * pixels
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def write_icons(bundle, name):
    resources = bundle / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    body = b""
    for kind, pixels in [(b"icp5", 32), (b"ic12", 64)]:
        data = icon_png(pixels)
        body += kind + struct.pack(">I", len(data) + 8) + data
        if name in {"ExtensionIcon", "WorkflowBadge"}:
            (resources / (name + (".png" if pixels == 32 else "@2x.png"))).write_bytes(data)
    (resources / (name + ".icns")).write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


class WorkflowPrototypePackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="WorkflowPackage-")
        # The verifier must use exact identities, not a preferred app filename.
        self.app = Path(self.directory.name) / "Different Name.package"
        self.extension = self.app / "Contents/PlugIns" / MODULE.EXTENSION_NAME
        self.app_info = dict(CFBundleIdentifier=MODULE.APP_ID, CFBundlePackageType="APPL",
                             CFBundleExecutable="SilentSnipWorkflowPrototype", CFBundleVersion="10",
                             CFBundleIconFile="AppIcon")
        self.extension_info = dict(CFBundleIdentifier=MODULE.EXTENSION_ID, CFBundlePackageType="XPC!",
            CFBundleExecutable="SilentSnipWorkflowExtension", CFBundleVersion="10", CFBundleIconFile="ExtensionIcon", NSExtension={
                "NSExtensionPointIdentifier": "com.apple.FinalCut.WorkflowExtension",
                "ProExtensionPrincipalViewControllerClass": "SSWorkflowViewController"})
        self.write_info(self.app, self.app_info)
        self.write_info(self.extension, self.extension_info)
        write_icons(self.app, "AppIcon")
        write_icons(self.extension, "ExtensionIcon")
        write_icons(self.extension, "WorkflowBadge")
        self.app_binary = self.app / "Contents/MacOS/SilentSnipWorkflowPrototype"
        self.extension_binary = self.extension / "Contents/MacOS/SilentSnipWorkflowExtension"
        write_macho(self.app_binary)
        write_macho(self.extension_binary, bootstrap=True)
        self.entitlements = copy.deepcopy(MODULE.EXPECTED_ENTITLEMENTS)
        self.calls = []
        self.signature_fails = False

    def tearDown(self):
        self.directory.cleanup()

    def write_info(self, bundle, value):
        path = bundle / "Contents/Info.plist"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def run_tool(self, arguments, **kwargs):
        self.calls.append(arguments)
        if "--display" in arguments:
            return subprocess.CompletedProcess(arguments, 0, plistlib.dumps(self.entitlements), b"")
        return subprocess.CompletedProcess(arguments, 1 if self.signature_fails else 0, b"", b"")

    def verify(self):
        return MODULE.verify_app(self.app, run=self.run_tool)

    def test_valid_isolated_package_checks_bootstrap_capabilities_and_deep_signature(self):
        report = self.verify()
        self.assertTrue(report["verified"])
        self.assertTrue(report["extensionMachO"]["usesProExtensionMain"])
        self.assertFalse(report["registrationPerformedByChecker"])
        self.assertFalse(report["installationPerformedByChecker"])
        self.assertFalse(report["nativeFinalCutBehaviorEstablished"])
        self.assertIs(report["signedEntitlements"]["com.apple.security.automation.apple-events"], True)
        self.assertIn(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.app.resolve())], self.calls)
        self.assertEqual(report["extensionIcon"]["bundleIconFile"], "ExtensionIcon")
        self.assertEqual([image["pixels"] for image in report["extensionIcon"]["toolbarPNGs"]], [32, 64])
        self.assertFalse(report["extensionIcon"]["nativeToolbarRenderingEstablished"])
        self.assertEqual([image["pixels"] for image in report["headerBadgePNGs"]], [32, 64])

    def test_template_toolbar_icon_cannot_replace_the_required_colored_header_badge(self):
        (self.extension / "Contents/Resources/WorkflowBadge@2x.png").unlink()
        with self.assertRaisesRegex(ValueError, "header badge resource"):
            self.verify()

    def test_current_package_cannot_omit_declared_icon_or_its_resource(self):
        self.extension_info.pop("CFBundleIconFile")
        self.write_info(self.extension, self.extension_info)
        with self.assertRaisesRegex(ValueError, "bundle icon name"):
            self.verify()
        self.extension_info["CFBundleIconFile"] = "ExtensionIcon"
        self.write_info(self.extension, self.extension_info)
        (self.extension / "Contents/Resources/ExtensionIcon.icns").unlink()
        with self.assertRaisesRegex(ValueError, "bundle icon resource"):
            self.verify()

    def test_icon_escape_and_malformed_container_are_rejected(self):
        path = self.extension / "Contents/Resources/ExtensionIcon.icns"
        outside = Path(self.directory.name) / "Other.icns"
        path.rename(outside)
        path.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "escaping Workflow bundle icon"):
            self.verify()
        path.unlink()
        path.write_bytes(b"icns" + struct.pack(">I", 1000) + b"bad-data")
        with self.assertRaisesRegex(ValueError, "icon container"):
            self.verify()

    def test_toolbar_icon_keeps_sdk_small_and_retina_representations(self):
        path = self.extension / "Contents/Resources/ExtensionIcon@2x.png"
        path.write_bytes(icon_png(32))
        with self.assertRaisesRegex(ValueError, "32/64 px RGBA"):
            self.verify()

    def test_production_identity_rejected_before_external_commands(self):
        self.app_info["CFBundleIdentifier"] = "local.silentsnip.app"
        self.write_info(self.app, self.app_info)
        with self.assertRaisesRegex(ValueError, "isolated Workflow Prototype"):
            self.verify()
        self.assertEqual(self.calls, [])

    def test_extra_audio_extension_is_rejected(self):
        (self.extension.parent / "SilentSnipAudio.appex").mkdir()
        with self.assertRaisesRegex(ValueError, "only its one Workflow"):
            self.verify()

    def test_audio_registration_and_production_routes_rejected_even_when_nested(self):
        for key in ["AudioComponents", "AudioComponentBundle", "CFBundleURLTypes", "CFBundleDocumentTypes",
                    "NSServices", "NSAppleScriptEnabled", "OSAScriptingDefinition", "SilentSnipContainingApp"]:
            with self.subTest(key=key):
                value = copy.deepcopy(self.extension_info)
                value["NSExtension"]["Unexpected"] = {key: []}
                self.write_info(self.extension, value)
                with self.assertRaisesRegex(ValueError, "production URL/document/Share route"):
                    self.verify()

    def test_wrong_point_or_controller_cannot_pass_as_workflow_prototype(self):
        for key, value in [("NSExtensionPointIdentifier", "com.apple.AudioUnit-UI"),
                           ("ProExtensionPrincipalViewControllerClass", "OtherController")]:
            info = copy.deepcopy(self.extension_info)
            info["NSExtension"][key] = value
            self.write_info(self.extension, info)
            with self.assertRaisesRegex(ValueError, "point or principal"):
                self.verify()

    def test_signed_entitlements_must_be_exact_inspection_and_automation_consent(self):
        missing_consent = copy.deepcopy(MODULE.EXPECTED_ENTITLEMENTS)
        missing_consent.pop("com.apple.security.automation.apple-events")
        variants = [
            {},
            missing_consent,
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.network.client": True},
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.app-sandbox": 1},
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.automation.apple-events": 1},
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.accessibility": True},
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.files.user-selected.read-only": True},
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.application-groups": ["group.unrelated"]},
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.temporary-exception.apple-events": ["*"]},
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.scripting-targets": {
                "com.apple.FinalCut": ["com.apple.FinalCut.library.inspection", "com.apple.FinalCut.library.modification"]}},
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.scripting-targets": {"com.apple.FinalCut": ["*"]}},
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.scripting-targets": {"*": ["com.apple.FinalCut.library.inspection"]}},
            {**MODULE.EXPECTED_ENTITLEMENTS, "com.apple.security.scripting-targets": {
                "com.apple.FinalCut": ["com.apple.FinalCut.library.inspection"], "com.apple.finder": ["com.apple.finder.read"]}},
        ]
        for value in variants:
            with self.subTest(value=value):
                self.entitlements = value
                with self.assertRaisesRegex(ValueError, "read-only Final Cut"):
                    self.verify()

    def test_entry_must_be_actual_sdk_bootstrap_not_merely_present_symbol(self):
        write_macho(self.extension_binary, bootstrap=True, wrong_entry=True)
        with self.assertRaisesRegex(ValueError, "does not enter"):
            self.verify()

    def test_sdk_debug_stabs_record_is_not_a_duplicate_bootstrap_definition(self):
        write_macho(self.extension_binary, bootstrap=True, debug_bootstrap_record=True)
        self.assertTrue(self.verify()["extensionMachO"]["usesProExtensionMain"])

    def test_two_real_bootstrap_definitions_are_still_rejected(self):
        write_macho(self.extension_binary, bootstrap=True, duplicate_definition=True)
        with self.assertRaisesRegex(ValueError, "Undefined/duplicate"):
            self.verify()

    def test_private_or_sdk_host_dylib_loads_are_rejected(self):
        for value in ["/Applications/Final Cut Pro.app/Contents/Frameworks/Flexo.framework/Flexo",
                      "@rpath/ProExtensionHost.framework/ProExtensionHost",
                      "/Library/Developer/SDKs/WorkflowExtensionSDK.sdk/Library/Frameworks/ProExtensionHost.framework/ProExtensionHost"]:
            with self.subTest(library=value):
                write_macho(self.extension_binary, bootstrap=True, library=value)
                with self.assertRaisesRegex(ValueError, "host framework"):
                    self.verify()

    def test_deep_signature_failure_is_not_packaging_success(self):
        self.signature_fails = True
        with self.assertRaisesRegex(ValueError, "verification command failed"):
            self.verify()

    def test_extension_symlink_cannot_select_a_different_app(self):
        moved = Path(self.directory.name) / "Other.appex"
        self.extension.rename(moved)
        self.extension.symlink_to(moved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.verify()

    def test_existing_audit_is_never_overwritten(self):
        output = Path(self.directory.name) / "Audit.json"
        output.write_text("preserve evidence")
        with self.assertRaises(SystemExit) as result:
            MODULE.main(["--app", str(self.app), "--output", str(output)])
        self.assertEqual(result.exception.code, 2)
        self.assertEqual(output.read_text(), "preserve evidence")

    def make_worker(self):
        app = Path(self.directory.name) / "Worker.app"
        info = dict(CFBundleIdentifier="local.silentsnip.app", CFBundlePackageType="APPL",
                    CFBundleExecutable="SilentSnip", CFBundleVersion="49",
                    SilentSnipWorkflowProtocolVersion=1,
                    CFBundleURLTypes=[{"CFBundleURLSchemes": ["silentsnip"]}],
                    **{"com.apple.proapps.MediaAssetProtocol": {}})
        self.write_info(app, info)
        write_macho(app / "Contents/MacOS/SilentSnip")
        return app, info

    def test_worker_metadata_contract_verified_without_launch_or_registry_claim(self):
        app, _ = self.make_worker()
        report = MODULE.verify_worker(app, run=self.run_tool)
        self.assertEqual(report["workflowProtocolVersion"], 1)
        self.assertTrue(report["activeURLAndShareRoutesVerified"])
        self.assertFalse(report["runtimeLookupUniquenessEstablished"])
        self.assertFalse(report["sandboxClientReadabilityEstablished"])
        self.assertEqual(len(self.calls), 1)
        self.assertIn("--verify", self.calls[0])

    def test_old_boolean_unknown_or_inert_worker_is_rejected_before_external_commands(self):
        app, original = self.make_worker()
        for field, value in [("CFBundleIdentifier", "local.silentsnip.helper.candidate"),
                ("CFBundleExecutable", "OtherWorker"), ("CFBundleVersion", "47"), ("CFBundleVersion", "48"),
                ("SilentSnipWorkflowProtocolVersion", None), ("SilentSnipWorkflowProtocolVersion", True),
                ("SilentSnipWorkflowProtocolVersion", 2), ("CFBundleURLTypes", []),
                ("com.apple.proapps.MediaAssetProtocol", None)]:
            with self.subTest(field=field, value=value):
                info = copy.deepcopy(original)
                if value is None:
                    info.pop(field)
                else:
                    info[field] = value
                self.write_info(app, info)
                self.calls.clear()
                with self.assertRaises(ValueError):
                    MODULE.verify_worker(app, run=self.run_tool)
                self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
