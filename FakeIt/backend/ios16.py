"""
iOS 16 and below: legacy com.apple.dt.simulatelocation via DtSimulateLocation (pymobiledevice3 9.x — async API).
"""

from __future__ import annotations

import contextlib

import pymobiledevice3.lockdown
from pymobiledevice3.services.simulate_location import DtSimulateLocation


async def run_set(udid: str, latitude: float, longitude: float) -> None:
    lockdown = await pymobiledevice3.lockdown.create_using_usbmux(serial=udid, autopair=True)
    try:
        async with DtSimulateLocation(lockdown) as sim:
            await sim.set(latitude, longitude)
    finally:
        with contextlib.suppress(Exception):
            await lockdown.close()


async def run_reset(udid: str) -> None:
    lockdown = await pymobiledevice3.lockdown.create_using_usbmux(serial=udid, autopair=True)
    try:
        async with DtSimulateLocation(lockdown) as sim:
            await sim.clear()
    finally:
        with contextlib.suppress(Exception):
            await lockdown.close()
