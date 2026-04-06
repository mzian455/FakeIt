#!/usr/bin/env python3
"""
FakeIt location bridge: iOS 17+ uses tunneld → RemoteServiceDiscoveryService → DVT
(no CoreDeviceTunnelProxy). iOS < 17 uses lockdown DVT. Process stays alive for 17+
until FakeIt sends SIGTERM.

Requires pymobiledevice3 >= 9.0 (DvtProvider + async LocationSimulation).
iOS 17+: run `sudo python3 -m pymobiledevice3 remote tunneld` in another terminal first.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import re
import signal
import sys

STOP = False


def _on_signal(*_args) -> None:
    global STOP
    STOP = True


def _major(version: str) -> int:
    try:
        return int(version.strip().split(".")[0])
    except (ValueError, IndexError):
        return 18


def _norm_udid(u: str) -> str:
    return re.sub(r"[^0-9A-Fa-f]", "", u).upper()


async def _acquire_rsd_for_udid(udid: str):
    """One connected RSD from tunneld for this UDID; closes the rest."""
    from pymobiledevice3.tunneld.api import get_tunneld_devices

    nu = _norm_udid(udid)
    try:
        rsds = await get_tunneld_devices()
    except Exception as e:
        raise RuntimeError(
            "Cannot reach tunneld (start: sudo python3 -m pymobiledevice3 remote tunneld)"
        ) from e

    if not rsds:
        raise RuntimeError(
            "No active device tunnels — start: sudo python3 -m pymobiledevice3 remote tunneld"
        )

    selected = None
    for r in rsds:
        if _norm_udid(r.udid) == nu:
            selected = r
            break

    if selected is None:
        for r in rsds:
            with contextlib.suppress(Exception):
                await r.close()
        raise RuntimeError(f"No tunnel for this UDID (is tunneld running for this device?): {udid}")

    for r in rsds:
        if r is not selected:
            with contextlib.suppress(Exception):
                await r.close()

    return selected


async def _hold_ios17_tunneld(udid: str, lat: float, lon: float) -> None:
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

    rsd = await _acquire_rsd_for_udid(udid)
    try:
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as location_simulation:
            await location_simulation.set(lat, lon)
            while not STOP:
                await asyncio.sleep(0.5)
            with contextlib.suppress(Exception):
                await location_simulation.clear()
    finally:
        with contextlib.suppress(Exception):
            await rsd.close()


async def _hold_ios16(udid: str, lat: float, lon: float) -> None:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.mobile_image_mounter import auto_mount
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

    lockdown = await create_using_usbmux(serial=udid, autopair=True)
    try:
        await auto_mount(lockdown)
    except Exception:
        pass
    async with DvtProvider(lockdown) as dvt, LocationSimulation(dvt) as location_simulation:
        await location_simulation.clear()
        await location_simulation.set(lat, lon)
        while not STOP:
            await asyncio.sleep(0.5)


async def _clear_ios17_tunneld(udid: str) -> None:
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

    rsd = await _acquire_rsd_for_udid(udid)
    try:
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as location_simulation:
            await location_simulation.clear()
    finally:
        with contextlib.suppress(Exception):
            await rsd.close()


async def _clear_ios16(udid: str) -> None:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

    lockdown = await create_using_usbmux(serial=udid, autopair=True)
    async with DvtProvider(lockdown) as dvt, LocationSimulation(dvt) as location_simulation:
        await location_simulation.clear()


def main() -> int:
    parser = argparse.ArgumentParser(description="FakeIt pymobiledevice3 location bridge.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_hold = sub.add_parser(
        "hold-set",
        help="Tunnel + set location; run until SIGTERM (FakeIt stops this when you reset or spoof again).",
    )
    p_hold.add_argument("udid")
    p_hold.add_argument("ios_version")
    p_hold.add_argument("latitude", type=float)
    p_hold.add_argument("longitude", type=float)

    p_clear = sub.add_parser("clear", help="Clear simulated location (one shot).")
    p_clear.add_argument("udid")
    p_clear.add_argument("ios_version")

    args = parser.parse_args()
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    try:
        if args.cmd == "hold-set":
            mv = _major(args.ios_version)
            coro = (
                _hold_ios17_tunneld(args.udid, args.latitude, args.longitude)
                if mv >= 17
                else _hold_ios16(args.udid, args.latitude, args.longitude)
            )
            asyncio.run(coro)
            return 0
        mv = _major(args.ios_version)
        coro = _clear_ios17_tunneld(args.udid) if mv >= 17 else _clear_ios16(args.udid)
        asyncio.run(coro)
        return 0
    except Exception as e:
        print(f"FakeIt bridge error: {e}", file=sys.stderr)
        import traceback

        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
