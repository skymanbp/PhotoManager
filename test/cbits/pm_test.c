/* Test-only fixture (2026-09-25 audit #8): put a THIRD-PARTY reparse point -- tag chosen by the
 * caller, generic GUID buffer -- on an existing file, so the suite can show which reparse points
 * pm follows.  It lives in the TEST suite's own c-sources, not in the library's cbits/pm_win.c:
 * pm.exe never links it.
 *
 * A normal (non-admin) token may do this on a file it can write: probed 2026-09-26 on
 * Windows 11 (build 26200) with tag 0x00000BEE -- attributes became "Archive, ReparsePoint",
 * `fsutil reparsepoint query` showed the tag, and opening the file for data failed with
 * ERROR_CANT_ACCESS_FILE (1920), since no filter driver owns the tag.  Bit 29 of the tag is the
 * name-surrogate bit (winnt.h IsReparseTagNameSurrogate); pm treats only such tags as links.
 *
 * Returns 1 on success; 0 with the Win32 error in *err. */
#include <windows.h>
#include <winioctl.h>
#include <string.h>

DWORD pm_test_set_foreign_reparse(LPCWSTR path, DWORD tag, DWORD *err)
{
    BYTE buf[REPARSE_GUID_DATA_BUFFER_HEADER_SIZE + 4];
    REPARSE_GUID_DATA_BUFFER *rb = (REPARSE_GUID_DATA_BUFFER *)buf;
    DWORD ret = 0;
    BOOL ok;
    HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                           FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (h == INVALID_HANDLE_VALUE) { *err = GetLastError(); return 0; }
    memset(buf, 0, sizeof buf);
    rb->ReparseTag = tag;
    rb->ReparseDataLength = 4;
    rb->ReparseGuid.Data1 = 0x706d7465; /* any non-zero GUID; fixed so the fixture is deterministic */
    ok = DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, buf, sizeof buf, NULL, 0, &ret, NULL);
    *err = ok ? 0 : GetLastError();
    CloseHandle(h);
    return ok ? 1 : 0;
}
