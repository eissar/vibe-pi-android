#!/usr/bin/env python3
"""Boot the emulator headless, install the APK, run scripted steps, then shut
everything down again (the emulator never outlives this script).

Usage: tools/emu_test.py steps.json
steps: [["sleep", 2], ["shot", "name"], ["tap", x, y], ["text", "hi"],
        ["key", "KEYCODE_ENTER"], ["swipe", x1, y1, x2, y2, ms], ["sh", "cmd"]]
"""
import json, os, subprocess, sys, time

SDK = os.path.expanduser("~/Android/Sdk")
ADB = f"{SDK}/platform-tools/adb"
EMU = f"{SDK}/emulator/emulator"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APK = os.path.join(ROOT, "build", "pi-agent.apk")
SHOTS = os.path.join(ROOT, "build", "shots")
PKG = "dev.eissar.piagent"


def adb(*args, check=False, timeout=60):
    return subprocess.run([ADB, *args], capture_output=True, text=True, timeout=timeout, check=check)


def main():
    steps = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else [["sleep", 4], ["shot", "start"]]
    os.makedirs(SHOTS, exist_ok=True)
    emu = subprocess.Popen(
        [EMU, "-avd", "pi_test", "-no-window", "-no-audio", "-no-boot-anim",
         "-gpu", "swiftshader_indirect", "-accel", "on", "-no-snapshot-save"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        adb("wait-for-device", timeout=180)
        t0 = time.time()
        while adb("shell", "getprop", "sys.boot_completed").stdout.strip() != "1":
            if time.time() - t0 > 240:
                raise SystemExit("boot timeout")
            time.sleep(2)
        print(f"booted in {time.time() - t0:.0f}s")
        adb("shell", "settings", "put", "global", "window_animation_scale", "0")
        adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
        r = adb("install", "-r", APK, timeout=120)
        print("install:", r.stdout.strip(), r.stderr.strip())
        adb("logcat", "-c")
        adb("shell", "am", "start", "-n", f"{PKG}/android.app.NativeActivity")
        for st in steps:
            op, *a = st
            if op == "sleep":
                time.sleep(a[0])
            elif op == "shot":
                path = os.path.join(SHOTS, f"{a[0]}.png")
                with open(path, "wb") as f:
                    f.write(subprocess.run([ADB, "exec-out", "screencap", "-p"], capture_output=True).stdout)
                print("shot:", path)
            elif op == "tap":
                adb("shell", "input", "tap", str(a[0]), str(a[1]))
            elif op == "text":
                adb("shell", "input", "text", a[0].replace(" ", "%s"))
            elif op == "key":
                adb("shell", "input", "keyevent", a[0])
            elif op == "swipe":
                adb("shell", "input", "swipe", *[str(x) for x in a])
            elif op == "sh":
                print(adb("shell", a[0]).stdout)
        log = adb("logcat", "-d", "-s", "PiAgent:*", "AndroidRuntime:E", "DEBUG:*", "libc:*", "NativeActivity:*", "linker:*").stdout
        print("---- logcat ----")
        print(log[-6000:])
        pid = adb("shell", "pidof", PKG).stdout.strip()
        print("app pid:", pid or "(not running)")
    finally:
        adb("emu", "kill")
        try:
            emu.wait(timeout=30)
        except subprocess.TimeoutExpired:
            emu.kill()


if __name__ == "__main__":
    main()
