#!/usr/bin/env python3
"""Patch a Chroma/spoti.pw IPA so account/Plus login is a local false-positive.

This is a direct IPA patch for spoti.pw-0.50.0. It changes only the injected
Frameworks/spotifyglass.dylib account/auth status checks. The goal is to make
local login/status paths report success for test accounts instead of editing
individual Plus feature rows.
"""
from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

RET = bytes.fromhex("c0035fd6")
MOV_W0_0_RET = bytes.fromhex("00008052c0035fd6")
MOV_W0_1_RET = bytes.fromhex("20008052c0035fd6")
MOV_X0_0_RET = bytes.fromhex("000080d2c0035fd6")
NOP = bytes.fromhex("1f2003d5")


def enc_adrp(rd: int, pc: int, target: int) -> bytes:
    """Encode ADRP rd, target_page for ARM64."""
    pc_page = pc & ~0xFFF
    target_page = target & ~0xFFF
    imm = (target_page - pc_page) >> 12
    if not (-(1 << 20) <= imm < (1 << 20)):
        raise ValueError("ADRP target out of range")
    imm &= (1 << 21) - 1
    immlo = imm & 0x3
    immhi = imm >> 2
    word = 0x90000000 | (immlo << 29) | (immhi << 5) | rd
    return struct.pack("<I", word)


def enc_add_imm(rd: int, rn: int, imm: int, is64: bool = True) -> bytes:
    if not (0 <= imm < 4096):
        raise ValueError("ADD immediate out of range")
    word = (0x91000000 if is64 else 0x11000000) | (imm << 10) | (rn << 5) | rd
    return struct.pack("<I", word)


def enc_b(src: int, dst: int) -> bytes:
    off = dst - src
    if off % 4:
        raise ValueError("unaligned branch")
    imm = off >> 2
    if not (-(1 << 25) <= imm < (1 << 25)):
        raise ValueError("branch target out of range")
    return struct.pack("<I", 0x14000000 | (imm & 0x03FFFFFF))


def return_cfstring(addr: int, target: int) -> bytes:
    return enc_adrp(0, addr, target) + enc_add_imm(0, 0, target & 0xFFF) + RET


PLUS_IS_ON = 0x3407B8
THIS_ACCOUNT = 0x3407D8

PATCHES = [
    # Central local account check. Original required both stored email and pass.
    (0x00F6C0, MOV_W0_1_RET, "account-present check -> true"),

    # Stop background/refresh paths from asking chroma.pw and signing the fake
    # account back out during tests.
    (0x00FBC4, RET, "remote /api/app/me refresh -> no-op"),
    (0x00FF60, RET, "scheduled account refresh -> no-op"),

    # Local status/display helpers report a successful account.
    (0x00F764, return_cfstring(0x00F764, PLUS_IS_ON), "account status text -> 'Plus is on'"),
    (0x0159E4, return_cfstring(0x0159E4, THIS_ACCOUNT), "account label fallback -> 'this account'"),

    # Verification callback: treat the auth verify response as successful. The
    # caller already zeroes the out-error pointer before this helper is called.
    (0x0127DC, MOV_W0_1_RET, "auth verify response parser -> success"),

    # If the verify request itself reports a transport/server error, still route
    # through the success parser above instead of short-circuiting as failure.
    (0x013148, enc_b(0x013148, 0x013158), "auth verify callback ignores transport error"),
]

EXPECTED_STRINGS = [
    b"SGAccountPageController",
    b"spotipw.account.email",
    b"spotipw.account.pass",
    b"/api/app/auth/verify",
    b"Plus is on",
]


def run(cmd: list[str], cwd: Path | None = None) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=cwd, check=True)


def patch_dylib(path: Path) -> None:
    data = bytearray(path.read_bytes())
    if data[:4] != bytes.fromhex("cffaedfe"):
        raise SystemExit(f"{path} is not a little-endian 64-bit Mach-O")
    for needle in EXPECTED_STRINGS:
        if needle not in data:
            raise SystemExit(f"safety check failed: {needle!r} not found in {path}")

    for offset, patch, note in PATCHES:
        if offset + len(patch) > len(data):
            raise SystemExit(f"patch offset out of range: 0x{offset:x}")
        original = bytes(data[offset : offset + len(patch)])
        if original == patch:
            print(f"already patched: {note} @ 0x{offset:x}")
            continue
        first = struct.unpack_from("<I", data, offset)[0]
        # v0.50.0 safety: target sites are function prologues, a conditional
        # branch in the verify callback, or a previous patch.
        if first in (0xD65F03C0, 0x52800020, 0x52800000, 0xD2800000):
            pass
        elif not (
            (first & 0x9F000000) == 0x90000000  # ADRP
            or (first & 0xFFC00000) == 0xB9400000  # LDR-ish getter
            or (first & 0xFFC00000) == 0x39400000  # LDRB getter
            or (first & 0xFF000000) in (0xA9000000, 0xA8000000, 0x6D000000)  # STP prologue
            or (first & 0xFF000000) == 0xD1000000  # SUB SP prologue
            or (first & 0x7F000000) == 0x34000000  # CBZ/CBNZ
        ):
            raise SystemExit(
                f"safety check failed at 0x{offset:x}: unexpected first instruction 0x{first:08x}"
            )
        print(f"patching {note} @ 0x{offset:x}: {original.hex()} -> {patch.hex()}")
        data[offset : offset + len(patch)] = patch

    path.write_bytes(data)


def find_app(root: Path) -> Path:
    payload = root / "Payload"
    apps = list(payload.glob("*.app"))
    if not apps:
        raise SystemExit("No Payload/*.app found in IPA")
    return apps[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa", type=Path)
    ap.add_argument("-o", "--output", type=Path, required=True)
    ap.add_argument("--no-ldid", action="store_true", help="Do not ldid-sign the patched dylib")
    args = ap.parse_args()

    ipa = args.ipa.resolve()
    out = args.output.resolve()
    if not ipa.exists():
        raise SystemExit(f"No such IPA: {ipa}")
    out.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="fakelogin-ipa-") as td:
        root = Path(td)
        run(["unzip", "-q", str(ipa), "-d", str(root)])
        app = find_app(root)
        dylib = app / "Frameworks" / "spotifyglass.dylib"
        if not dylib.exists():
            raise SystemExit(f"spotifyglass.dylib not found at {dylib}")

        patch_dylib(dylib)

        if not args.no_ldid and shutil.which("ldid"):
            run(["ldid", "-S", str(dylib)])
        elif not args.no_ldid:
            print("warning: ldid not found; leaving patched dylib for installer-side re-signing", file=sys.stderr)

        if out.exists():
            out.unlink()
        run(["zip", "-qry", str(out), "Payload"], cwd=root)
        run(["unzip", "-tq", str(out)])
        print(f"Wrote {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
