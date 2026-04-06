"""
iOS 17+: location via tunneld → RemoteServiceDiscoveryService → DVT LocationSimulation.

Uses pymobiledevice3 9.x APIs (DvtProvider replaces removed DvtSecureSocketProxy).
Does NOT use CoreDeviceTunnelProxy — tunnels come from `remote tunneld` HTTP API.
"""

from __future__ import annotations

import asyncio
import contextlib
import signal

from pymobiledevice3.exceptions import DeviceNotFoundError, TunneldConnectionError
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.tunneld.api import get_tunneld_devices

import device_utils


async def _acquire_rsd_for_udid(udid: str):
    """
    Return a single connected RemoteServiceDiscoveryService for UDID, closing all others.
    Caller must close the returned RSD when done.
    """
    try:
        rsds = await get_tunneld_devices()
    except TunneldConnectionError:
        raise
    except Exception as e:
        raise TunneldConnectionError() from e

    if not rsds:
        raise TunneldConnectionError("no active tunnels")

    selected = None
    for r in rsds:
        if device_utils.udid_matches(r.udid, udid):
            selected = r
            break

    if selected is None:
        for r in rsds:
            with contextlib.suppress(Exception):
                await r.close()
        raise DeviceNotFoundError(udid)

    for r in rsds:
        if r is not selected:
            with contextlib.suppress(Exception):
                await r.close()

    return selected


async def hold_set(udid: str, latitude: float, longitude: float, stop: asyncio.Event) -> None:
    """Set location, print SUCCESS (caller must do flush timing), hold until stop is set."""
    rsd = await _acquire_rsd_for_udid(udid)
    try:
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as loc_sim:
            await loc_sim.set(latitude, longitude)
            print("SUCCESS", flush=True)
            await stop.wait()
            with contextlib.suppress(Exception):
                await loc_sim.clear()
    finally:
        with contextlib.suppress(Exception):
            await rsd.close()


def run_hold_set(udid: str, latitude: float, longitude: float) -> None:
    async def _main() -> None:
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            with contextlib.suppress(NotImplementedError, RuntimeError):
                loop.add_signal_handler(sig, stop.set)
        await hold_set(udid, latitude, longitude, stop)

    asyncio.run(_main())


async def _reset_async(udid: str) -> None:
    rsd = await _acquire_rsd_for_udid(udid)
    try:
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as loc_sim:
            await loc_sim.clear()
    finally:
        with contextlib.suppress(Exception):
            await rsd.close()


def run_reset(udid: str) -> None:
    asyncio.run(_reset_async(udid))
