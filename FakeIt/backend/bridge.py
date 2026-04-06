#!/usr/bin/env python3
"""
FakeIt Python bridge — CLI contract for the macOS app (pymobiledevice3 only).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from typing import NoReturn

import device_utils
import ios16
import ios17
from pymobiledevice3.exceptions import (
    DeveloperModeError,
    DeveloperModeIsNotEnabledError,
    DeviceNotFoundError,
    NoDeviceConnectedError,
    NotTrustedError,
    PasscodeRequiredError,
    PasswordRequiredError,
    TunneldConnectionError,
    UserDeniedPairingError,
)


def _fail(reason: str) -> NoReturn:
    print(f"ERROR: {reason}", flush=True)
    raise SystemExit(1)


def _ok() -> None:
    print("SUCCESS", flush=True)


def _classify(exc: BaseException) -> str:
    if isinstance(exc, (DeviceNotFoundError, NoDeviceConnectedError)):
        return "no_device_found"
    if isinstance(exc, (NotTrustedError, UserDeniedPairingError, PasswordRequiredError, PasscodeRequiredError)):
        return "device_locked — unlock your iPhone and tap Trust"
    if isinstance(exc, (DeveloperModeIsNotEnabledError, DeveloperModeError)):
        return "developer_mode_off — enable Developer Mode in Settings > Privacy & Security"
    if isinstance(exc, TunneldConnectionError):
        return "needs_sudo"
    return str(exc)


def _run(coro):
    return asyncio.run(coro)


def cmd_list_devices() -> None:
    try:
        devices = _run(device_utils.async_list_usb_devices())
        print(json.dumps(devices), flush=True)
    except SystemExit:
        raise
    except BaseException as e:
        _fail(_classify(e))


def _resolve_udid(udid: str | None) -> str:
    if udid:
        return udid
    found = _run(device_utils.async_first_usb_udid())
    if not found:
        _fail("no_device_found")
    return found


def cmd_set(lat: float, lon: float, udid: str | None) -> None:
    target = _resolve_udid(udid)
    try:
        major = _run(device_utils.async_ios_major(target))
    except BaseException as e:
        _fail(_classify(e))

    try:
        if major >= 17:
            ios17.run_hold_set(target, lat, lon)
        else:
            _run(ios16.run_set(target, lat, lon))
            _ok()
    except SystemExit:
        raise
    except BaseException as e:
        _fail(_classify(e))


def cmd_reset(udid: str | None) -> None:
    target = _resolve_udid(udid)
    try:
        major = _run(device_utils.async_ios_major(target))
    except BaseException as e:
        _fail(_classify(e))

    try:
        if major >= 17:
            ios17.run_reset(target)
        else:
            _run(ios16.run_reset(target))
        _ok()
    except SystemExit:
        raise
    except BaseException as e:
        _fail(_classify(e))


def main() -> None:
    parser = argparse.ArgumentParser(prog="bridge.py")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list_devices", help="List USB devices as JSON")

    p_set = sub.add_parser("set", help="Set simulated location")
    p_set.add_argument("latitude", type=float)
    p_set.add_argument("longitude", type=float)
    p_set.add_argument("--udid", default=None, help="Device UDID (default: first USB device)")

    p_reset = sub.add_parser("reset", help="Clear simulated location")
    p_reset.add_argument("--udid", default=None, help="Device UDID (default: first USB device)")

    args = parser.parse_args()

    if args.command == "list_devices":
        cmd_list_devices()
    elif args.command == "set":
        cmd_set(args.latitude, args.longitude, args.udid)
    elif args.command == "reset":
        cmd_reset(args.udid)
    else:
        _fail(f"unknown command {args.command!r}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except KeyboardInterrupt:
        sys.exit(130)
    except BaseException as e:
        _fail(_classify(e))
