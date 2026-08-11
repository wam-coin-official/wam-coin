#!/usr/bin/env python3
"""
TEMPORARY diagnostic: install a SIGSEGV/SIGABRT backtrace handler in bitcoind.

Injects a static-initialised handler so it is armed before main() runs, which
is necessary because the crash under investigation happens during static
initialisation or very early argument setup -- too early for a handler placed
inside main() to help.

Delete this file once the crash is understood. It is not part of the build.

    python3 scripts/_diag_segv.py <path-to-bitcoind.cpp>
"""
import io
import sys

SNIPPET = r'''
// ---------------- TEMPORARY WAM DIAGNOSTIC (remove before release) --------
#include <execinfo.h>
#include <csignal>
#include <cstring>
#include <unistd.h>

static void wam_diag_crash_handler(int sig)
{
    void* frames[40];
    const int n = backtrace(frames, 40);

    const char* banner = (sig == SIGABRT)
        ? "\n=== WAM DIAGNOSTIC: SIGABRT ===\n"
        : "\n=== WAM DIAGNOSTIC: SIGSEGV ===\n";
    ssize_t rc = write(2, banner, std::strlen(banner));
    (void)rc;

    backtrace_symbols_fd(frames, n, 2);
    _exit(139);
}

namespace {
struct WamDiagInstaller {
    WamDiagInstaller()
    {
        signal(SIGSEGV, wam_diag_crash_handler);
        signal(SIGABRT, wam_diag_crash_handler);
    }
};
// Static object: armed during static initialisation, i.e. before main().
WamDiagInstaller g_wam_diag_installer;
} // namespace
// ---------------- END TEMPORARY WAM DIAGNOSTIC ---------------------------
'''


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    path = sys.argv[1]
    src = io.open(path, encoding="utf-8").read()

    if "WAM DIAGNOSTIC" in src:
        print("  already injected")
        return 0

    anchor = "MAIN_FUNCTION"
    if anchor not in src:
        print(f"  could not find {anchor!r} in {path}")
        return 1

    i = src.index(anchor)
    out = src[:i] + SNIPPET + "\n" + src[i:]
    io.open(path, "w", encoding="utf-8").write(out)
    print("  injected the crash handler")
    return 0


if __name__ == "__main__":
    sys.exit(main())
