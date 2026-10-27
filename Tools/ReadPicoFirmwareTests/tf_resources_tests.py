#!/usr/bin/env python3
"""中文：离线验证 TF 资源守卫及真实打包片段，不编译、启动应用或访问设备。
English: Offline TF resource and packaging guard checks; no build, app, or device access.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib


REPO = Path(__file__).resolve().parents[2]
VALIDATOR = REPO / "scripts/validate-readpico-tf-resources.py"
SOURCE = REPO / "Resources/Firmware/ReadPico"
PACKAGE_BLOCK = (REPO / "scripts/make-app.sh").read_text().split(
    "# BEGIN READ_PICO_PACKAGE\n", 1)[1].split("# END READ_PICO_PACKAGE", 1)[0]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def fixture(directory, app_manifest=None, app_bytes=None):
    directory.mkdir(parents=True)
    version = app_manifest["version"] if app_manifest else "0.27.1-dev41"
    original = json.loads((SOURCE / "tf-manifest.json").read_text())
    packages = [copy.deepcopy(p) for p in original["packages"] if p["id"] in {"gomoku", "drawing-notes"}]
    for entry in packages:
        relative = entry["path"]
        payload = (SOURCE / "tf-card" / relative).read_bytes()
        path = directory / "tf-card" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
    for folder, key in [("games", "games"), ("tools", "apps")]:
        catalog_path = Path("tf-card/apps") / folder / "catalog.json"
        value = json.loads((SOURCE / catalog_path).read_text())
        value[key] = [p for p in value[key] if p["id"] in {"gomoku", "drawing-notes"}]
        write_json(directory / catalog_path, value)
    firmware = copy.deepcopy(app_manifest) if app_manifest else {"version": version}
    firmware["tf_apps"] = {"count": len(packages), "directory": "tf-card",
                           "manifest": "tf-manifest.json", "automatic_install": False}
    catalog = {"version": version, "automatic_install": False, "packages": packages}
    write_json(directory / "manifest.json", firmware)
    write_json(directory / "tf-manifest.json", catalog)
    if app_bytes is not None:
        (directory / "read-pico-app.bin").write_bytes(app_bytes)
    return firmware, catalog


def edit_json(directory, name, action):
    path = directory / name
    value = json.loads(path.read_text())
    action(value)
    write_json(path, value)


def header_crc(data):
    struct.pack_into("<I", data, 232, 0)
    struct.pack_into("<I", data, 232, zlib.crc32(data[:512]))


def native_only_package():
    data = bytearray(516)
    data[:8] = b"PICOAPP1"
    for offset, value in [(8, 1), (12, 512), (16, 516), (20, 1), (24, 10001), (28, 0),
                          (228, 1), (272, 512), (276, 4)]:
        struct.pack_into("<I", data, offset, value)
    for offset, text in [(32, b"gomoku"), (64, "五子棋".encode()), (128, b"native-only fixture"),
                         (256, b"macos-arm64")]:
        data[offset:offset + len(text)] = text
    data[512:] = b"\x01\x02\x03\x04"
    struct.pack_into("<I", data, 280, zlib.crc32(data[512:]))
    header_crc(data)
    return data


def replace_gomoku(directory, mutate):
    """Keep outer hashes consistent so rejection must inspect the actual package."""
    path = directory / "tf-card/apps/games/gomoku.pga"
    data = bytearray(path.read_bytes())
    replacement = mutate(data)
    if replacement is not None:
        data = replacement
    path.write_bytes(data)
    for name, key in [("tf-manifest.json", "packages"), ("tf-card/apps/games/catalog.json", "games")]:
        def update(value):
            for entry in value[key]:
                if entry["id"] == "gomoku":
                    entry.update(bytes=len(data), sha256=sha(data))
        edit_json(directory, name, update)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPO / ".build/readpico-full-build39-review")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix="readpico-tf-guards-") as temporary:
        temporary = Path(temporary)

        def run(name, mutate=None, *, success=False, optimized=False, real=False):
            directory = temporary / name
            if real:
                shutil.copytree(SOURCE, directory)
            else:
                fixture(directory)
            if mutate:
                mutate(directory)
            env = dict(os.environ)
            env.pop("PYTHONOPTIMIZE", None)
            if optimized:
                env["PYTHONOPTIMIZE"] = "1"
            command = [sys.executable, str(VALIDATOR), str(directory)]
            process = subprocess.run(command, env=env, capture_output=True, text=True)
            passed = (process.returncode == 0) == success
            results.append({"name": name, "passed": passed, "expected_success": success,
                            "returncode": process.returncode, "optimized": optimized,
                            "stdout": process.stdout, "stderr": process.stderr})
            print(("PASS" if passed else "FAIL") + " " + name)

        def catalog_change(action):
            return lambda directory: edit_json(directory, "tf-manifest.json", action)

        def firmware_change(action):
            return lambda directory: edit_json(directory, "manifest.json", action)

        run("valid-minimal-set", success=True)
        run("valid-real-bundled-set", success=True, real=True)
        run("wrong-hash", catalog_change(lambda v: v["packages"][0].update(sha256="0" * 64)))
        run("wrong-bytes", catalog_change(lambda v: v["packages"][0].update(bytes=1)))
        run("wrong-version", catalog_change(lambda v: v.update(version="other")))
        run("wrong-count", firmware_change(lambda v: v["tf_apps"].update(count=3)))
        run("wrong-declared-directory", firmware_change(lambda v: v["tf_apps"].update(directory="../tf-card")))
        run("wrong-declared-manifest", firmware_change(lambda v: v["tf_apps"].update(manifest="../tf-manifest.json")))
        run("automatic-catalog-install", catalog_change(lambda v: v.update(automatic_install=True)))
        run("automatic-firmware-install", firmware_change(lambda v: v["tf_apps"].update(automatic_install=True)))
        run("path-parent-traversal", catalog_change(lambda v: v["packages"][0].update(path="../gomoku.pga")))
        run("path-absolute", catalog_change(lambda v: v["packages"][0].update(path="/tmp/gomoku.pga")))
        run("path-wrong-folder", catalog_change(lambda v: v["packages"][0].update(path="apps/tools/gomoku.pga")))
        run("identifier-traversal", catalog_change(lambda v: v["packages"][0].update(id="../gomoku")))
        run("wrong-target", catalog_change(lambda v: v["packages"][0].update(targets=["native-preview"])))

        def duplicate(directory):
            edit_json(directory, "tf-manifest.json", lambda v: v["packages"].append(copy.deepcopy(v["packages"][0])))
            edit_json(directory, "manifest.json", lambda v: v["tf_apps"].update(count=3))
        run("duplicate-identifier", duplicate)
        run("missing-package", lambda d: (d / "tf-card/apps/games/gomoku.pga").unlink())
        run("missing-tf-tree", lambda d: shutil.rmtree(d / "tf-card"))
        run("missing-catalog", lambda d: (d / "tf-manifest.json").unlink())
        run("missing-firmware-manifest", lambda d: (d / "manifest.json").unlink())
        run("unlisted-package", lambda d: (d / "tf-card/apps/games/extra.pga").write_bytes(b"unlisted"))
        run("undeclared-tf-resources", firmware_change(lambda v: v.pop("tf_apps")))

        def legacy(directory):
            shutil.rmtree(directory / "tf-card")
            (directory / "tf-manifest.json").unlink()
            edit_json(directory, "manifest.json", lambda v: v.pop("tf_apps"))
        run("valid-legacy-app-only", legacy, success=True)

        run("pga-bad-magic-outer-hashes-synced", lambda d: replace_gomoku(d, lambda p: p.__setitem__(slice(0, 8), b"NOTPGA!!")))
        run("pga-bad-header-crc-outer-hashes-synced", lambda d: replace_gomoku(d, lambda p: p.__setitem__(232, p[232] ^ 128)))
        run("pga-bad-payload-crc-outer-hashes-synced", lambda d: replace_gomoku(d, lambda p: p.__setitem__(-1, p[-1] ^ 128)))

        def different_id(payload):
            payload[32:64] = b"different" + bytes(23)
            header_crc(payload)
        def different_kind(payload):
            struct.pack_into("<I", payload, 28, 1)
            header_crc(payload)
        run("pga-id-mismatch-outer-hashes-synced", lambda d: replace_gomoku(d, different_id))
        run("pga-kind-mismatch-outer-hashes-synced", lambda d: replace_gomoku(d, different_kind))
        run("pga-native-only-outer-hashes-synced", lambda d: replace_gomoku(d, lambda _: native_only_package()))
        run("catalog-wrong-hash", lambda d: edit_json(d, "tf-card/apps/games/catalog.json", lambda v: v["games"][0].update(sha256="0" * 64)))
        run("catalog-missing-entry", lambda d: edit_json(d, "tf-card/apps/games/catalog.json", lambda v: v.update(games=[])))
        run("catalog-wrong-target", lambda d: edit_json(d, "tf-card/apps/tools/catalog.json", lambda v: v["apps"][0].update(targets=["macos-arm64"])))

        def link(directory, relative, *, dangling=False):
            path = directory / relative
            target = directory / ("outside-" + path.name)
            if path.is_dir():
                path.rename(target)
                path.symlink_to(target, target_is_directory=True)
            else:
                if path.exists():
                    path.rename(target)
                path.symlink_to(directory / "absent-target" if dangling else target)
        run("symlink-tf-root", lambda d: link(d, "tf-card"))
        run("symlink-nested-directory", lambda d: link(d, "tf-card/apps/games"))
        run("symlink-package", lambda d: link(d, "tf-card/apps/games/gomoku.pga"))
        run("symlink-dangling-extra", lambda d: link(d, "tf-card/extra", dangling=True))
        run("symlink-firmware-manifest", lambda d: link(d, "manifest.json"))
        run("symlink-tf-manifest", lambda d: link(d, "tf-manifest.json"))
        run("symlink-validation-directory", lambda d: link(d, "validation"), real=True)
        run("symlink-validation-file", lambda d: link(d, "validation/firmware-validation.json"), real=True)
        run("validation-wrong-version", lambda d: edit_json(d, "validation/firmware-validation.json", lambda v: v.update(version="other")), real=True)
        run("validation-wrong-app-binding", lambda d: edit_json(d, "validation/firmware-validation.json", lambda v: v.update(app_sha256="0" * 64)), real=True)
        run("validation-wrong-source-binding", lambda d: edit_json(d, "validation/source-binding.json", lambda v: v.update(manifest_sha256="0" * 64)), real=True)
        run("optimized-wrong-hash", catalog_change(lambda v: v["packages"][0].update(sha256="0" * 64)), optimized=True)
        run("optimized-path-traversal", catalog_change(lambda v: v["packages"][0].update(path="../gomoku.pga")), optimized=True)

        # Test the production packaging block without compiling/signing or touching a device.
        generated = temporary / "esp-fixture"
        generated.mkdir()
        subprocess.run([sys.executable, str(Path(__file__).with_name("fixtures.py")), str(generated)],
                       check=True, capture_output=True, text=True)
        app_manifest = json.loads((generated / "manifest.json").read_text())
        app_bytes = (generated / "app.bin").read_bytes()

        def package(name, mutate=None, *, success=False):
            root = temporary / name / "source"
            directory = root / "Resources/Firmware/ReadPico"
            fixture(directory, app_manifest, app_bytes)
            scripts = root / "scripts"
            scripts.mkdir(parents=True)
            shutil.copyfile(VALIDATOR, scripts / VALIDATOR.name)
            if mutate:
                mutate(directory)
            app = temporary / name / "staged.app"
            env = dict(os.environ, ROOT=str(root), APP=str(app))
            env.pop("PYTHONOPTIMIZE", None)
            process = subprocess.run(["bash", "-euo", "pipefail", "-c", PACKAGE_BLOCK],
                                     env=env, capture_output=True, text=True)
            passed = (process.returncode == 0) == success
            destination = app / "Contents/Resources/Firmware/ReadPico"
            if not success:
                passed = passed and not destination.exists()
            if passed and success:
                passed = (destination / "tf-manifest.json").read_bytes() == (directory / "tf-manifest.json").read_bytes()
                passed = passed and all((destination / "tf-card" / entry["path"]).read_bytes() ==
                                        (directory / "tf-card" / entry["path"]).read_bytes()
                                        for entry in json.loads((directory / "tf-manifest.json").read_text())["packages"])
            results.append({"name": name, "passed": passed, "expected_success": success,
                            "returncode": process.returncode, "stdout": process.stdout, "stderr": process.stderr})
            print(("PASS" if passed else "FAIL") + " " + name)

        package("package-valid-set", success=True)
        package("package-declared-tree-missing", lambda d: shutil.rmtree(d / "tf-card"))
        package("package-undeclared-tf-resources", firmware_change(lambda v: v.pop("tf_apps")))
        package("package-missing-payload", lambda d: (d / "tf-card/apps/games/gomoku.pga").unlink())
        package("package-wrong-hash", catalog_change(lambda v: v["packages"][0].update(sha256="0" * 64)))
        package("package-symlink-root", lambda d: link(d, "tf-card"))
        package("package-symlink-app", lambda d: link(d, "read-pico-app.bin"))
        package("package-symlink-firmware-manifest", lambda d: link(d, "manifest.json"))
        package("package-symlink-tf-manifest", lambda d: link(d, "tf-manifest.json"))

    report = {"tests": len(results), "passed": sum(r["passed"] for r in results),
              "source_sha256": {str(p.relative_to(REPO)): sha(p.read_bytes()) for p in
                                [VALIDATOR, REPO / "scripts/make-app.sh", Path(__file__)]},
              "results": results}
    report["ok"] = report["passed"] == report["tests"]
    path = args.output / "tf-resources-tests.json"
    write_json(path, report)
    print(f'{"PASS" if report["ok"] else "FAIL"}: {report["passed"]}/{report["tests"]} TF resource guards; report {path}')
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
