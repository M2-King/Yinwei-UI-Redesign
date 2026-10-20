"""Check the PINNED DLL, never the source build or running backend.

From the repository root:
  python yinwei/apps/yinwei_player/tool/remote/check_array_file_tap.py
  # After stopping backend playback (test audio uses the default output device):
  python yinwei/apps/yinwei_player/tool/remote/check_array_file_tap.py --run --backend-idle

Default is hash inspection only. --run starts an isolated child process with
its own DLL globals and temporary working directory. It opens the default audio
device and plays a generated test WAV; it cannot guarantee inaudibility or
exclusive-device coexistence. Do not run alongside backend playback. No DLL,
bundle, deployment, environment, or backend configuration is modified.
"""
import argparse
import ctypes as C
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import wave

PINNED_SHA = "eb764148534b6f0df3d0de60c7b6f184fcbf5164ed7298d53a3de95bb6e8c036"
DEFAULT_DLL = Path(__file__).resolve().parents[5] / "outputs/w19/windows/spatial_core.dll"


class Meta(C.Structure):
    _fields_ = [("epoch", C.c_uint64), ("sequence", C.c_uint64),
                ("firstFrame", C.c_uint64), ("sampleRate", C.c_uint32),
                ("frameCount", C.c_uint32), ("mode", C.c_uint32),
                ("dropped", C.c_uint32), ("az", C.c_float), ("el", C.c_float)]


def metrics(frames):
    if not frames:
        raise RuntimeError("No file output-tap frames: inconclusive")
    left = math.sqrt(sum(l*l for l, _ in frames) / len(frames))
    right = math.sqrt(sum(r*r for _, r in frames) / len(frames))
    return {"frames": len(frames), "rmsL": left, "rmsR": right,
            "balance": (right-left) / max(left+right, 1e-12),
            "energy": math.hypot(left, right)}


def verdict(samples):
    left, right, muted = (samples[k] for k in ("left", "right", "muted"))
    active = min(left["energy"], right["energy"])
    mute_ratio = muted["energy"] / max(active, 1e-12)
    balance_change = abs(left["balance"] - right["balance"])
    # Both checks matter: a pre-array tap may contain the original stereo WAV,
    # which has energy but does not follow the isolated third speaker's mute.
    passed = active > 1e-5 and mute_ratio < 0.2 and balance_change > 0.03
    return {"result": "PASS" if passed else "FAIL_OR_INCONCLUSIVE",
            "muteEnergyRatio": mute_ratio, "azimuthBalanceChange": balance_change}


def worker(dll_path):
    if os.name != "nt":
        raise RuntimeError("Native probe requires Windows")
    dll = C.CDLL(str(dll_path))

    def bind(name, args, result=C.c_int32):
        f = getattr(dll, name); f.argtypes = args; f.restype = result
        return f

    last_error = bind("yinwei_last_error", [C.c_char_p, C.c_size_t])

    def check(f, *args):
        code = f(*args)
        if code != 0:
            buf = C.create_string_buffer(4096); last_error(buf, len(buf))
            raise RuntimeError(f"{f.__name__}: {code}: {buf.value.decode('utf-8', 'replace')}")

    open_file = bind("yinwei_open", [C.c_char_p])
    set_mode = bind("yinwei_set_mode", [C.c_int32])
    set_array = bind("yinwei_set_array", [C.c_int32])
    set_count = bind("yinwei_set_speaker_count", [C.c_int32])
    set_speaker = bind("yinwei_set_speaker", [C.c_int32, C.c_float, C.c_float,
        C.c_float, C.c_float, C.c_int32, C.c_int32])
    play = bind("yinwei_play", [])
    pause = bind("yinwei_pause", [])
    dispose = bind("yinwei_dispose", [])
    enable = bind("yinwei_output_tap_enable", [C.c_int32])
    version = bind("yinwei_output_tap_version", [], C.c_uint32)
    read = bind("yinwei_output_tap_read", [C.POINTER(C.c_float), C.c_uint32, C.POINTER(Meta)])
    if version() != 1 or C.sizeof(Meta) != 48:
        raise RuntimeError("Unsupported file tap ABI")
    wav_path = Path.cwd() / "array-tap-tone.wav"
    with wave.open(str(wav_path), "wb") as wav:
        wav.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
        # Stationary repeated one-second wide-band tone. Samples and reports
        # live only in this temporary directory (deleted by the parent).
        pcm = bytearray()
        for i in range(48000):
            v = int(2500 * sum(math.sin(2*math.pi*f*i/48000) for f in (440, 880, 1760)))
            pcm.extend(struct.pack("<hh", v, v))
        for _ in range(30):
            wav.writeframes(pcm)
    pcm = (C.c_float * 1024)(); meta = Meta(); samples = {}

    def collect(seconds, keep):
        frames = []; end = time.monotonic() + seconds
        while time.monotonic() < end:
            n = read(pcm, 512, C.byref(meta))
            if n < 0 or n > 512:
                raise RuntimeError(f"Tap read failed: {n}")
            if n and (meta.frameCount != n or meta.mode != 1):
                raise RuntimeError(f"Not spatial processed PCM: mode={meta.mode}, count={meta.frameCount}")
            if keep:
                frames.extend((pcm[2*i], pcm[2*i+1]) for i in range(n))
            if not n:
                time.sleep(0.002)
        return frames

    try:
        check(open_file, str(wav_path).encode())
        check(set_mode, 1); check(set_array, 1); check(set_count, 3)
        # Isolate the added voice, leaving the required L/R present but muted.
        check(set_speaker, 0, -30, 0, 1.8, 0, 1, 0)
        check(set_speaker, 1, 30, 0, 1.8, 0, 1, 1)
        check(enable, 1); check(play)
        for name, az, mute in (("left", -90, 0), ("right", 90, 0), ("muted", 90, 1)):
            check(set_speaker, 2, az, 0, 1.8, 0, mute, 2)
            collect(2.0, False)  # discard buffered/slewed signal and reverb tail
            samples[name] = metrics(collect(0.7, True))
        result = {"samples": samples, **verdict(samples)}
        print(json.dumps(result, indent=2), flush=True)
        return 0 if result["result"] == "PASS" else 2
    finally:
        enable(0); pause(); dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, default=DEFAULT_DLL)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--backend-idle", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    path = args.dll.resolve()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(json.dumps({"dll": str(path), "sha256": digest, "pinnedMatch": digest == PINNED_SHA}), flush=True)
    if digest != PINNED_SHA:
        raise RuntimeError("Hash mismatch: this probe is pinned to w19")
    if args.worker:
        return worker(path)
    if not args.run:
        print("Inspection only. Audio remains unverified. See --help for the explicit audible probe.")
        return 0
    if not args.backend_idle:
        parser.error("--run requires --backend-idle: first stop backend playback; test audio will be audible")
    with tempfile.TemporaryDirectory(prefix="yinwei-array-tap-") as folder:
        child = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--dll", str(path), "--worker"],
                               cwd=folder, timeout=40)
        return child.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"FAIL_OR_INCONCLUSIVE: {error}", file=sys.stderr)
        sys.exit(2)
