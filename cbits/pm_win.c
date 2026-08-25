/* P3b-15 (round-12 #3): GetFileAttributesW + GetLastError must be captured in
 * ONE foreign call.  As two separate Haskell FFI calls, the threaded RTS may
 * run them on different OS threads (GetLastError is per-OS-thread), so the
 * error code read back could belong to some other call.  One C function, one
 * OS thread, no assumption. */
#include <windows.h>

DWORD pm_get_file_attributes_err(LPCWSTR path, DWORD *err)
{
    DWORD a = GetFileAttributesW(path);
    *err = (a == INVALID_FILE_ATTRIBUTES) ? GetLastError() : 0;
    return a;
}

/* P5-D (round-28 #1): the path an OPEN HANDLE is actually bound to.
 *
 * This is the primitive that closes the TOCTOU window between "resolve the
 * path" and "open it by name".  The answer is derived from the handle we are
 * about to read from, so nothing an attacker does AFTER the open can change
 * it, and anything done BEFORE the open shows up as a different path.
 *
 * FILE_NAME_NORMALIZED | VOLUME_NAME_DOS (both 0) => "\\?\D:\dir\file".
 * Same one-call discipline as above: the return value and GetLastError must
 * be read on the same OS thread. */
DWORD pm_final_path_by_handle(HANDLE h, LPWSTR buf, DWORD cch, DWORD *err)
{
    DWORD n = GetFinalPathNameByHandleW(h, buf, cch, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    *err = (n == 0) ? GetLastError() : 0;
    return n;
}
