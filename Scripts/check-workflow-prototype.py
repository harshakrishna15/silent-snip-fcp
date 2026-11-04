"""Verify the isolated M1 Workflow Extension package without running it.

This checks identities, routes, capabilities, Mach-O bootstrap/dependencies and
signatures. It does not install/register the app or establish native behavior.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess


APP_ID = "local.silentsnip.workflowprototype"
EXTENSION_ID = APP_ID + ".extension"
EXTENSION_NAME = "SilentSnipWorkflowExtension.appex"
EXPECTED_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.automation.apple-events": True,
    "com.apple.security.scripting-targets": {
        "com.apple.FinalCut": ["com.apple.FinalCut.library.inspection"],
    },
}
FORBIDDEN_ROUTES = {
    "CFBundleURLTypes", "CFBundleDocumentTypes", "NSServices",
    "NSAppleScriptEnabled", "OSAScriptingDefinition", "SilentSnipContainingApp",
    "AudioComponents", "AudioComponentBundle", "CFPlugInFactories", "CFPlugInTypes",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_info(bundle):
    path = bundle / "Contents/Info.plist"
    require(path.is_file() and not path.is_symlink(), "Missing or symlinked bundle metadata")
    value = plistlib.loads(path.read_bytes())
    require(isinstance(value, dict), "Bundle metadata must be a dictionary")
    return value


def check_routes(value):
    if isinstance(value, dict):
        require(not FORBIDDEN_ROUTES.intersection(value), "Prototype declares an Audio Unit or production URL/document/Share route")
        for child in value.values():
            check_routes(child)
    elif isinstance(value, list):
        for child in value:
            check_routes(child)


def executable(bundle, info, expected_name):
    require(info.get("CFBundleExecutable") == expected_name, "Unexpected prototype executable")
    path = bundle / "Contents/MacOS" / expected_name
    require(path.is_file() and not path.is_symlink() and os.access(path, os.X_OK), "Missing, symlinked, or nonexecutable prototype binary")
    require(path.resolve().is_relative_to(bundle.resolve()), "Executable escapes its bundle")
    return path


def macho_details(path):
    data = path.read_bytes()
    require(len(data) >= 32, "Incomplete Mach-O header")
    magic, cpu, _, kind, count, command_bytes, _, _ = struct.unpack("<8I", data[:32])
    require(magic == 0xFEEDFACF and cpu == 0x0100000C and kind == 2,
            "Prototype must contain thin arm64 Mach-O executables")
    require(count <= 65536 and 32 + command_bytes <= len(data), "Invalid Mach-O load-command bounds")
    cursor = 32; libraries = []; text = None; entry = None; symbols = None
    for _ in range(count):
        require(cursor + 8 <= 32 + command_bytes, "Incomplete Mach-O load command")
        command, size = struct.unpack("<II", data[cursor:cursor+8])
        require(size >= 8 and cursor + size <= 32 + command_bytes, "Invalid Mach-O command size")
        payload = data[cursor:cursor+size]
        if command in {0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023}:
            require(size >= 24, "Incomplete dylib command")
            offset = struct.unpack("<I", payload[8:12])[0]
            require(24 <= offset < size and b"\0" in payload[offset:], "Invalid dylib name")
            libraries.append(payload[offset:].split(b"\0", 1)[0].decode("utf-8"))
        elif command == 0x19:
            require(size >= 72, "Incomplete segment command")
            if payload[8:24].split(b"\0", 1)[0] == b"__TEXT":
                require(text is None, "Duplicate executable text segment")
                address, _, offset, length = struct.unpack("<4Q", payload[24:56])
                text = (address, offset, length)
        elif command == 0x80000028:
            require(size >= 24 and entry is None, "Missing/duplicate executable bootstrap command")
            entry = struct.unpack("<Q", payload[8:16])[0]
        elif command == 0x2:
            require(size >= 24 and symbols is None, "Invalid symbol-table command")
            symbols = struct.unpack("<4I", payload[8:24])
        cursor += size
    require(cursor == 32 + command_bytes, "Mach-O load commands do not consume their declared size")
    for library in libraries:
        require(not any(fragment in library for fragment in [
            "ProExtensionHost.framework", "ProExtension.framework", "Final Cut Pro.app/",
            "Flexo.framework", "WorkflowExtensionSDK.sdk/",
        ]), "Prototype dynamically loads an SDK/Final Cut host framework")
    bootstrap = None
    if symbols:
        offset, number, strings, string_bytes = symbols
        require(offset + number * 16 <= len(data) and strings + string_bytes <= len(data), "Invalid Mach-O symbol bounds")
        for index in range(number):
            name, symbol_type, _, _, value = struct.unpack("<IBBHQ", data[offset+index*16:offset+(index+1)*16])
            require(name < string_bytes, "Invalid symbol string offset")
            # SDK static libraries can retain N_FUN/STABS debug entries with
            # the same spelling as a real symbol. They are not definitions.
            if symbol_type & 0xE0:
                continue
            if data[strings+name:strings+string_bytes].split(b"\0", 1)[0] == b"_ProExtensionMain":
                require(symbol_type & 0xE == 0xE and value != 0 and bootstrap is None,
                        "Undefined/duplicate ProExtensionMain")
                bootstrap = value
    entry_address = None
    if entry is not None and text:
        address, offset, length = text
        require(offset <= entry < offset + length, "Executable entry is outside its text segment")
        entry_address = address + entry - offset
    return dict(dylibLoads=libraries, entryFileOffset=entry, entryAddress=entry_address,
                ProExtensionMainAddress=bootstrap,
                usesProExtensionMain=bootstrap is not None and entry_address == bootstrap)


def tool(arguments, run):
    result = run(arguments, capture_output=True)
    require(result.returncode == 0, "Package verification command failed: " + arguments[0])
    return result


def verify_app(app, run=subprocess.run):
    app = app.resolve(strict=True)
    require(app.is_dir(), "The app path must be a bundle directory")
    info = read_info(app)
    require(info.get("CFBundleIdentifier") == APP_ID and info.get("CFBundlePackageType") == "APPL",
            "This checker accepts only the isolated Workflow Prototype app identity")
    check_routes(info)
    require("NSExtension" not in info, "The containing app must not itself declare an extension")
    plugins = app / "Contents/PlugIns"
    require(plugins.is_dir() and not plugins.is_symlink(), "Missing or symlinked extension directory")
    require(sorted(child.name for child in plugins.iterdir()) == [EXTENSION_NAME],
            "The prototype must contain only its one Workflow Extension")
    extension = plugins / EXTENSION_NAME
    require(not extension.is_symlink() and extension.resolve().is_relative_to(app), "Extension escapes its containing app")
    extension_info = read_info(extension)
    require(extension_info.get("CFBundleIdentifier") == EXTENSION_ID and extension_info.get("CFBundlePackageType") == "XPC!",
            "Unexpected Workflow Extension identity")
    check_routes(extension_info)
    registration = extension_info.get("NSExtension")
    require(isinstance(registration, dict) and
            registration.get("NSExtensionPointIdentifier") == "com.apple.FinalCut.WorkflowExtension" and
            registration.get("ProExtensionPrincipalViewControllerClass") == "SSWorkflowViewController",
            "Unexpected Workflow Extension point or principal controller")
    # An unrelated nested service/component would bypass the one-extension check.
    for path in app.rglob("*"):
        require(not path.is_symlink() or path.resolve().is_relative_to(app), "A bundle symlink escapes the app")
        if path.is_dir() and path != extension:
            require(path.suffix.lower() not in {".appex", ".component", ".audiounit", ".xpc"},
                    "Unexpected nested extension, Audio Unit, or service")
        if path.name == "Info.plist":
            value = plistlib.loads(path.read_bytes())
            check_routes(value)
    containing_binary = executable(app, info, "SilentSnipWorkflowPrototype")
    extension_binary = executable(extension, extension_info, "SilentSnipWorkflowExtension")
    containing_macho = macho_details(containing_binary)
    extension_macho = macho_details(extension_binary)
    require(extension_macho["usesProExtensionMain"], "Extension executable does not enter through the SDK ProExtensionMain bootstrap")
    result = tool(["/usr/bin/codesign", "--display", "--entitlements", ":-", str(extension)], run)
    raw = result.stdout if isinstance(result.stdout, bytes) else result.stdout.encode()
    # codesign diagnostics belong on stderr; tolerate an informational prefix only.
    begin = raw.find(b"<?xml")
    if begin < 0:
        begin = raw.find(b"bplist")
    require(begin >= 0, "The signed extension has no readable entitlement plist")
    entitlements = plistlib.loads(raw[begin:])
    require(isinstance(entitlements, dict) and entitlements.get("com.apple.security.app-sandbox") is True and
            entitlements.get("com.apple.security.automation.apple-events") is True and
            entitlements == EXPECTED_ENTITLEMENTS,
            "Signed capabilities differ from sandboxed read-only Final Cut library inspection with Automation consent")
    tool(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], run)
    return dict(verified=True, app=str(app), containingBundleIdentifier=APP_ID,
                extensionBundleIdentifier=EXTENSION_ID, signedEntitlements=entitlements,
                containingExecutableSHA256=sha(containing_binary), extensionExecutableSHA256=sha(extension_binary),
                containingMachO=containing_macho, extensionMachO=extension_macho,
                deepStrictSignatureVerified=True, installationPerformedByChecker=False,
                registrationPerformedByChecker=False,
                nativeFinalCutBehaviorEstablished=False, analysisOrCutsEstablished=False,
                scope="Read-only SDK library inspection with macOS Automation consent; isolated-package verification performs no app execution, registration, installation, host observation, audio analysis or timeline edits")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    if args.output.exists():
        parser.exit(2, "The audit already exists; preserve it and choose a new output path.\n")
    try:
        report = verify_app(args.app)
    except (OSError, ValueError, KeyError, TypeError, struct.error, plistlib.InvalidFileException) as error:
        report = dict(verified=False, app=str(args.app), error=str(error), nativeFinalCutBehaviorEstablished=False)
    report["auditedAtUTC"] = datetime.now(timezone.utc).isoformat()
    try:
        with args.output.open("x") as stream:
            json.dump(report, stream, indent=2); stream.write("\n")
    except OSError as error:
        parser.exit(2, str(error) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["verified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
