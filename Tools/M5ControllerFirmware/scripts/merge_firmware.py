Import("env")

import os
import subprocess


def merge_full_firmware(source, target, env):
    """Create the complete image consumed by the macOS one-click flasher.

    PlatformIO's firmware.bin is only the application partition and normally
    belongs at 0x10000.  The app flasher writes one file at 0x0, so it must
    receive a merged image containing the bootloader and partition metadata.
    """
    build_dir = env.subst("$BUILD_DIR")
    program_name = env.subst("$PROGNAME")
    platform = env.PioPlatform()
    esptool = os.path.join(platform.get_package_dir("tool-esptoolpy"), "esptool.py")
    framework = platform.get_package_dir("framework-arduinoespressif32")
    output = os.path.join(build_dir, f"{program_name}-full.bin")
    command = [
        env.subst("$PYTHONEXE"), esptool,
        "--chip", "esp32s3", "merge_bin",
        "-o", output,
        "--flash_mode", "dio",
        "--flash_freq", "80m",
        "--flash_size", "8MB",
        "0x0000", os.path.join(build_dir, "bootloader.bin"),
        "0x8000", os.path.join(build_dir, "partitions.bin"),
        "0xe000", os.path.join(framework, "tools", "partitions", "boot_app0.bin"),
        "0x10000", os.path.join(build_dir, f"{program_name}.bin"),
    ]
    subprocess.run(command, check=True)
    print(f"Complete one-click image: {output}")


env.AddPostAction("$BUILD_DIR/${PROGNAME}.bin", merge_full_firmware)
