/*
 * MacGameHub XInput fix.
 *
 * The Wine runtime reports XInput thumbstick Y axes upside down (pushing a stick up gives a negative
 * ThumbLY, measured on this runtime with a raw HID capture next to an XInput one). This DLL is
 * installed into bottles as native xinput1_3 / xinput1_4 / xinput9_1_0 and forwards every call to
 * Wine's builtin xinput1_2 (same implementation, not overridden), flipping ThumbLY and ThumbRY.
 *
 * Controller bridge: when MACGAMEHUB_CONTROLLER_FILE names a file (MacGameHub sets it in bridge mode),
 * controllers come from there instead: MacGameHub reads them with macOS's GameController framework and
 * writes their state into that file, so input never goes through winebus/wineserver. Layout
 * (little endian, see Sources/HubCore/ControllerBridge.swift):
 *   0  u32 magic 'MGHC'   4 u32 version (1)   8 u32 packet   12 u32 heartbeat
 *   16 + 16*slot: u8 connected, u8 pad, u16 buttons, u8 lt, u8 rt, s16 lx, ly, rx, ry, u16 pad
 *
 * Build: Support/xinput-fix/build.sh (needs zig); the result is embedded in
 * Sources/HubCore/XInputFixDLLs.swift.
 */
#include <windows.h>

typedef struct {
    WORD wButtons;
    BYTE bLeftTrigger, bRightTrigger;
    SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY;
} XINPUT_GAMEPAD;

typedef struct {
    DWORD dwPacketNumber;
    XINPUT_GAMEPAD Gamepad;
} XINPUT_STATE;

static HMODULE backend;

/* ---- controller bridge ---- */

#define BRIDGE_MAGIC 0x4348474D /* 'MGHC' */
#define BRIDGE_SIZE (16 + 16 * 4)
#define GUIDE_BUTTON 0x0400

static HANDLE bridge_file = INVALID_HANDLE_VALUE;
static BOOL bridge_checked;
static DWORD last_heartbeat;
static ULONGLONG heartbeat_seen;

/* Whether bridge mode is on for this process; opens the state file the first time. */
static BOOL bridge_enabled(void)
{
    WCHAR unix_path[1024], dos_path[1030];
    DWORD len, i;

    if (bridge_checked) return bridge_file != INVALID_HANDLE_VALUE;
    bridge_checked = TRUE;
    len = GetEnvironmentVariableW(L"MACGAMEHUB_CONTROLLER_FILE", unix_path, 1024);
    if (!len || len >= 1024) return FALSE;
    dos_path[0] = 'Z'; dos_path[1] = ':';
    for (i = 0; i <= len; i++) dos_path[i + 2] = unix_path[i] == '/' ? '\\' : unix_path[i];
    bridge_file = CreateFileW(dos_path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              NULL, OPEN_EXISTING, 0, NULL);
    return TRUE; /* bridge mode even if MacGameHub hasn't written the file yet: report no controller */
}

/* Reads one slot; FALSE when no controller is there or MacGameHub stopped updating the file. */
static BOOL bridge_read(DWORD index, XINPUT_STATE *state)
{
    BYTE buf[BRIDGE_SIZE];
    const BYTE *slot = buf + 16 + 16 * index;
    OVERLAPPED at = {0};
    DWORD got = 0, heartbeat;
    ULONGLONG now = GetTickCount64();

    if (index >= 4) return FALSE;
    if (bridge_file == INVALID_HANDLE_VALUE)
    {
        bridge_checked = FALSE; /* the file may exist by now */
        if (!bridge_enabled() || bridge_file == INVALID_HANDLE_VALUE) return FALSE;
    }
    if (!ReadFile(bridge_file, buf, BRIDGE_SIZE, &got, &at) || got < BRIDGE_SIZE) return FALSE;
    if (*(DWORD *)buf != BRIDGE_MAGIC) return FALSE;
    heartbeat = *(DWORD *)(buf + 12);
    if (heartbeat != last_heartbeat) { last_heartbeat = heartbeat; heartbeat_seen = now; }
    else if (now - heartbeat_seen > 1000) return FALSE; /* MacGameHub isn't running */
    if (!slot[0]) return FALSE;
    if (state)
    {
        state->dwPacketNumber = *(DWORD *)(buf + 8);
        state->Gamepad.wButtons = *(WORD *)(slot + 2);
        state->Gamepad.bLeftTrigger = slot[4];
        state->Gamepad.bRightTrigger = slot[5];
        state->Gamepad.sThumbLX = *(SHORT *)(slot + 6);
        state->Gamepad.sThumbLY = *(SHORT *)(slot + 8);
        state->Gamepad.sThumbRX = *(SHORT *)(slot + 10);
        state->Gamepad.sThumbRY = *(SHORT *)(slot + 12);
    }
    return TRUE;
}

typedef struct {
    BYTE Type, SubType;
    WORD Flags;
    XINPUT_GAMEPAD Gamepad;
    WORD wLeftMotorSpeed, wRightMotorSpeed;
} XINPUT_CAPABILITIES;

static void bridge_caps(XINPUT_CAPABILITIES *caps)
{
    caps->Type = 1;    /* XINPUT_DEVTYPE_GAMEPAD */
    caps->SubType = 1; /* XINPUT_DEVSUBTYPE_GAMEPAD */
    caps->Flags = 0;
    caps->Gamepad.wButtons = 0xf3ff;
    caps->Gamepad.bLeftTrigger = caps->Gamepad.bRightTrigger = 0xff;
    caps->Gamepad.sThumbLX = caps->Gamepad.sThumbLY = caps->Gamepad.sThumbRX = caps->Gamepad.sThumbRY = (SHORT)0xffc0;
    caps->wLeftMotorSpeed = caps->wRightMotorSpeed = 0;
}

static FARPROC backend_proc(const char *name)
{
    if (!backend) backend = LoadLibraryA("xinput1_2.dll");
    return backend ? GetProcAddress(backend, name) : NULL;
}

static SHORT flip(SHORT value)
{
    return value == -32768 ? 32767 : (SHORT)-value;
}

static void fix_state(DWORD result, XINPUT_STATE *state)
{
    if (result != ERROR_SUCCESS || !state) return;
    state->Gamepad.sThumbLY = flip(state->Gamepad.sThumbLY);
    state->Gamepad.sThumbRY = flip(state->Gamepad.sThumbRY);
}

typedef DWORD (WINAPI *state_fn)(DWORD, XINPUT_STATE *);
typedef DWORD (WINAPI *ptr_fn)(DWORD, void *);
typedef DWORD (WINAPI *flags_ptr_fn)(DWORD, DWORD, void *);

DWORD WINAPI XInputGetState(DWORD index, XINPUT_STATE *state)
{
    if (bridge_enabled())
    {
        if (!state) return ERROR_BAD_ARGUMENTS;
        if (!bridge_read(index, state)) return ERROR_DEVICE_NOT_CONNECTED;
        state->Gamepad.wButtons &= ~GUIDE_BUTTON;
        return ERROR_SUCCESS;
    }
    state_fn fn = (state_fn)backend_proc("XInputGetState");
    DWORD result = fn ? fn(index, state) : ERROR_DEVICE_NOT_CONNECTED;
    fix_state(result, state);
    return result;
}

DWORD WINAPI XInputGetStateEx(DWORD index, XINPUT_STATE *state)
{
    if (bridge_enabled())
    {
        if (!state) return ERROR_BAD_ARGUMENTS;
        return bridge_read(index, state) ? ERROR_SUCCESS : ERROR_DEVICE_NOT_CONNECTED;
    }
    state_fn fn = (state_fn)backend_proc("XInputGetStateEx");
    if (!fn) return XInputGetState(index, state);
    DWORD result = fn(index, state);
    fix_state(result, state);
    return result;
}

DWORD WINAPI XInputSetState(DWORD index, void *vibration)
{
    if (bridge_enabled()) return bridge_read(index, NULL) ? ERROR_SUCCESS : ERROR_DEVICE_NOT_CONNECTED;
    ptr_fn fn = (ptr_fn)backend_proc("XInputSetState");
    return fn ? fn(index, vibration) : ERROR_DEVICE_NOT_CONNECTED;
}

DWORD WINAPI XInputGetCapabilities(DWORD index, DWORD flags, void *caps)
{
    if (bridge_enabled())
    {
        if (!bridge_read(index, NULL)) return ERROR_DEVICE_NOT_CONNECTED;
        if (caps) bridge_caps(caps);
        return ERROR_SUCCESS;
    }
    flags_ptr_fn fn = (flags_ptr_fn)backend_proc("XInputGetCapabilities");
    return fn ? fn(index, flags, caps) : ERROR_DEVICE_NOT_CONNECTED;
}

DWORD WINAPI XInputGetCapabilitiesEx(DWORD unknown, DWORD index, DWORD flags, void *caps)
{
    typedef DWORD (WINAPI *fn_t)(DWORD, DWORD, DWORD, void *);
    if (bridge_enabled())
    {
        BYTE *ex = caps;
        if (!bridge_read(index, NULL)) return ERROR_DEVICE_NOT_CONNECTED;
        if (ex)
        {
            bridge_caps((XINPUT_CAPABILITIES *)ex);
            *(WORD *)(ex + sizeof(XINPUT_CAPABILITIES)) = 0x045e;     /* VendorId */
            *(WORD *)(ex + sizeof(XINPUT_CAPABILITIES) + 2) = 0x028e; /* ProductId: Xbox 360 pad */
            *(WORD *)(ex + sizeof(XINPUT_CAPABILITIES) + 4) = 0x0114; /* VersionNumber */
        }
        return ERROR_SUCCESS;
    }
    fn_t fn = (fn_t)backend_proc("XInputGetCapabilitiesEx");
    return fn ? fn(unknown, index, flags, caps) : XInputGetCapabilities(index, flags, caps);
}

void WINAPI XInputEnable(BOOL enable)
{
    typedef void (WINAPI *fn_t)(BOOL);
    fn_t fn = (fn_t)backend_proc("XInputEnable");
    if (fn) fn(enable);
}

DWORD WINAPI XInputGetBatteryInformation(DWORD index, BYTE type, void *info)
{
    if (bridge_enabled())
    {
        if (!bridge_read(index, NULL)) return ERROR_DEVICE_NOT_CONNECTED;
        if (info) { ((BYTE *)info)[0] = 1 /* BATTERY_TYPE_WIRED */; ((BYTE *)info)[1] = 3 /* FULL */; }
        return ERROR_SUCCESS;
    }
    typedef DWORD (WINAPI *fn_t)(DWORD, BYTE, void *);
    fn_t fn = (fn_t)backend_proc("XInputGetBatteryInformation");
    return fn ? fn(index, type, info) : ERROR_DEVICE_NOT_CONNECTED;
}

DWORD WINAPI XInputGetKeystroke(DWORD index, DWORD reserved, void *keystroke)
{
    if (bridge_enabled()) return ERROR_EMPTY;
    flags_ptr_fn fn = (flags_ptr_fn)backend_proc("XInputGetKeystroke");
    return fn ? fn(index, reserved, keystroke) : ERROR_EMPTY;
}

DWORD WINAPI XInputGetDSoundAudioDeviceGuids(DWORD index, GUID *render, GUID *capture)
{
    typedef DWORD (WINAPI *fn_t)(DWORD, GUID *, GUID *);
    fn_t fn = (fn_t)backend_proc("XInputGetDSoundAudioDeviceGuids");
    return fn ? fn(index, render, capture) : ERROR_DEVICE_NOT_CONNECTED;
}

DWORD WINAPI XInputGetAudioDeviceIds(DWORD index, WCHAR *render, UINT *render_count, WCHAR *capture, UINT *capture_count)
{
    if (render_count) *render_count = 0;
    if (capture_count) *capture_count = 0;
    return ERROR_DEVICE_NOT_CONNECTED;
}

/* Undocumented ordinals some games use; nothing behind them in Wine either. */
DWORD WINAPI XInputWaitForGuideButton(DWORD index, DWORD flags, void *listen) { return ERROR_NOT_SUPPORTED; }
DWORD WINAPI XInputCancelGuideButtonWait(DWORD index) { return ERROR_NOT_SUPPORTED; }
DWORD WINAPI XInputPowerOffController(DWORD index) { return ERROR_NOT_SUPPORTED; }
DWORD WINAPI XInputGetBaseBusInformation(DWORD index, void *info) { return ERROR_NOT_SUPPORTED; }
