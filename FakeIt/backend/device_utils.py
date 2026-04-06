"""
Shared USB device discovery and iOS version helpers (pymobiledevice3 9.x — async usbmux/lockdown).
"""

from __future__ import annotations

import contextlib
import re
from typing import Optional

import pymobiledevice3.lockdown
import pymobiledevice3.usbmux


def udid_matches(a: str, b: str) -> bool:
    """Compare UDIDs ignoring hyphens / case."""
    na = re.sub(r"[^0-9A-Fa-f]", "", a).upper()
    nb = re.sub(r"[^0-9A-Fa-f]", "", b).upper()
    return na == nb


async def _safe_close_lockdown(ld: Optional[object]) -> None:
    if ld is None:
        return
    with contextlib.suppress(Exception):
        await ld.close()  # type: ignore[union-attr]


async def async_list_usb_devices() -> list[dict[str, str]]:
    """USB-connected iPhones/iPads with trust + pairing; skipped rows on failure."""
    out: list[dict[str, str]] = []
    for d in await pymobiledevice3.usbmux.list_devices():
        if not d.is_usb:
            continue
        lockdown = None
        try:
            lockdown = await pymobiledevice3.lockdown.create_using_usbmux(serial=d.serial, autopair=True)
            name = lockdown.display_name or "iPhone"
            ver = lockdown.product_version
            out.append({"udid": d.serial, "name": name, "ios_version": ver})
        except Exception:
            pass
        finally:
            await _safe_close_lockdown(lockdown)
    return out


async def async_first_usb_udid() -> Optional[str]:
    devices = await async_list_usb_devices()
    return devices[0]["udid"] if devices else None


async def async_ios_major(udid: str) -> int:
    lockdown = None
    try:
        lockdown = await pymobiledevice3.lockdown.create_using_usbmux(serial=udid, autopair=True)
        v = lockdown.product_version
        return int(v.strip().split(".")[0])
    finally:
        await _safe_close_lockdown(lockdown)


def ios_major_from_string(version: str) -> int:
    try:
        return int(version.strip().split(".")[0])
    except (ValueError, IndexError):
        return 0
