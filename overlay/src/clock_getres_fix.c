/*
 * Work around a bug in the FLSUN Speeder Pad's vendor Linux 4.9.191 kernel:
 * its arm64 vDSO clock_getres() reports a bogus resolution of about
 * 547 seconds for CLOCK_REALTIME/CLOCK_MONOTONIC. Python's asyncio uses that
 * value as its timer granularity, so every timeout shorter than ~9 minutes
 * fires immediately (KlipperScreen "ping timed out", Moonraker D-Bus and git
 * timeouts). The clock_getres system call itself is correct, so route
 * clock_getres() to it. Installed via /etc/ld.so.preload.
 */
#define _GNU_SOURCE
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

int clock_getres(clockid_t clk, struct timespec *res)
{
    return (int)syscall(SYS_clock_getres, clk, res);
}
