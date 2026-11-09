#!/usr/bin/env python3
"""Verify the unsigned native-source IPA without Xcode; never extract or execute it.

The expected commit is used to verify bundled SourceRuntime bytes. The workflow's
checkout log is still needed to establish which Swift source produced the binary.
"""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import struct
import subprocess
import sys
import zipfile


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], stderr=subprocess.PIPE)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(ipa, revision, root):
    commit = git(root, "rev-parse", "--verify", "--end-of-options", revision + "^{commit}").decode().strip()
    with zipfile.ZipFile(ipa) as archive:
        require(archive.testzip() is None, "ZIP CRC validation failed")
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate ZIP member names are not allowed")
        info_paths = [name for name in names if name.startswith("Payload/")
                      and name.count("/") == 2 and name.endswith(".app/Info.plist")]
        require(len(info_paths) == 1, "Expected one Payload/*.app/Info.plist")
        prefix = info_paths[0][:-len("Info.plist")]
        info = plistlib.loads(archive.read(info_paths[0]))
        require(info["MinimumOSVersion"] == "26.0", "Unexpected minimum iOS version")
        require(info["CFBundleIdentifier"] == "com.epiboly.legado", "Unexpected app bundle identifier")
        require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Expected an iPhoneOS device build")
        executable_name = info["CFBundleExecutable"]
        require(isinstance(executable_name, str) and "/" not in executable_name and "\\" not in executable_name,
                "Invalid main executable name")
        executable = archive.read(prefix + executable_name)
        require(len(executable) >= 32, "Truncated Mach-O header")
        magic, cpu, _ = struct.unpack_from("<III", executable)
        require(magic == 0xFEEDFACF and cpu == 0x0100000C, "Expected a thin arm64 Mach-O executable")
        ncmds, sizeofcmds = struct.unpack_from("<II", executable, 16)
        require(ncmds <= sizeofcmds // 8 and 32 + sizeofcmds <= len(executable), "Invalid load-command region")
        offset = 32
        for _ in range(ncmds):
            require(offset + 8 <= 32 + sizeofcmds, "Truncated load-command header")
            command, size = struct.unpack_from("<II", executable, offset)
            require(size >= 8 and offset + size <= 32 + sizeofcmds, "Invalid Mach-O load command")
            if command == 0x1D:  # LC_CODE_SIGNATURE
                require(size >= 16, "Truncated code-signature command")
                _, data_size = struct.unpack_from("<II", executable, offset + 8)
                require(data_size == 0, "Main executable contains a code signature")
            offset += size
        require(offset == 32 + sizeofcmds, "Load-command size mismatch")
        require(not any(name.startswith(prefix + "_CodeSignature/")
                        or name == prefix + "embedded.mobileprovision" for name in names),
                "App contains signing metadata or a provisioning profile")
        tracked = git(root, "ls-tree", "-r", "--name-only", commit, "App/Resources/SourceRuntime").decode("utf-8").splitlines()
        require(bool(tracked), "Expected commit has no SourceRuntime resources")
        expected_names = {prefix + "SourceRuntime/" + Path(relative).name for relative in tracked}
        actual_names = {name for name in names if name.startswith(prefix + "SourceRuntime/") and not name.endswith("/")}
        require(actual_names == expected_names, "Embedded SourceRuntime file set differs from the expected commit")
        resources = []
        for relative in tracked:
            expected = git(root, "show", f"{commit}:{relative}")
            actual = archive.read(prefix + "SourceRuntime/" + Path(relative).name)
            require(actual == expected, f"Embedded resource differs from the expected commit: {relative}")
            resources.append({"name": Path(relative).name, "bytes": len(actual),
                              "sha256": hashlib.sha256(actual).hexdigest()})
    return {"ipa": str(ipa), "expectedCommit": commit,
            "bytes": ipa.stat().st_size, "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
            "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "bundleId": info["CFBundleIdentifier"], "minimumOS": info["MinimumOSVersion"],
            "architecture": "arm64", "unsigned": True, "mainExecutableCodeSignature": False,
            "resources": resources,
            "provenance": "Resource bytes verified; confirm Swift checkout in the build workflow log."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("revision", help="Expected local Git commit or ref")
    parser.add_argument("--output", type=Path, help="Write the JSON report here as well as stdout")
    args = parser.parse_args()
    try:
        ipa = args.ipa.resolve(strict=True)
        if args.output:
            require(args.output.resolve() != ipa, "The JSON report cannot overwrite the IPA")
        report = verify(ipa, args.revision, Path(__file__).resolve().parents[1])
        text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            args.output.write_text(text, encoding="utf-8", newline="\n")
        print(text, end="")
    except (OSError, ValueError, KeyError, TypeError, struct.error, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print("IPA verification failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
