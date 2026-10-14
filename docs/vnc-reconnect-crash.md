# Apple VNC reconnect crash: macOS 27.2 beta

Confirmed on a Mac mini M2 Pro with Tart 2.40.1, host macOS 27.2 beta (26B5091g),
Virtualization.framework 308.2.4 (UUID `D2C5588D-DC5E-387C-B17A-C0B917A07B91`).
This finding is specific to this tested host build; other macOS versions were not tested.

## Mechanism

Reloading a browser console closes its VNC connection and creates a new one. In the inspected Apple
implementation, the VNC server increments `_activeClientCount`; when the previous count was zero and
a display/accessor exists, it schedules `_setupVirtualMachineAccessor`. That callback calls
`addAccessorObserver` with the VNC server object.

The disconnect path decrements the client count and disables presenter updates when the last client
leaves, but the inspected path does not remove that accessor observer. A later graphical connection
therefore registers the same observer again. `addAccessorObserver` detects the duplicate and deliberately
traps. Tart hosts this code in its own process, so the trap terminates Tart and interrupts the guest.
The launchd service subsequently starts a new guest process; this is not a graceful guest shutdown.

Read-only inspection of the loaded framework established:

- `_VZVNCServer._activeClientCount` is at offset `0x98` in the server object.
- `ServerDelegate::client_connection_created` increments the counter and calls setup for `0 -> 1`.
- `addAccessorObserver` searches `_accessorObservers` for the same object. Its duplicate branch calls
  `Base::assertion_trap` at function offset `0x2b8`. The crash reports show the matching return offset
  `700` (`0x2bc`), followed by the VNC setup callback.
- No framework or Tart executable was patched or injected into for this inspection.

## Controlled reproduction, 2026-10-14

Only the CI guest was tested. Its browser-console endpoint was temporarily gated so unrelated browser
connections could not affect the result. Tests connected directly to Tart on loopback, excluding
Proxmacs, WebSockets, reverse proxies and browser lifecycle code. Runtime credentials stayed local;
no keyboard/mouse input was sent and no framebuffer contents were recorded.

1. Boot a fresh guest and wait for SSH readiness. Complete RFB 3.8/VNC authentication and initialize
   the graphical session with noVNC-compatible pixel format, encoding list and framebuffer request.
2. At 18:40:54 MSK the first session succeeded (Tart PID 21767). Close it with a TCP reset matching the
   observed console teardown. After a ten-second pause, the VM was still running with the same PID.
3. At 18:41:06 the next connection failed. Tart crashed with the same accessor assertion:
   `tart-2026-10-14-184107.ips`, capture time 18:41:06.3142, PID 21767.
4. After automatic recovery, keep one authenticated graphical client connected to the fresh process.
   Five additional graphical clients connected and disconnected successfully; PID 22249 stayed unchanged.
5. Closing that final persistent client and waiting ten seconds did not crash the VM. No further
   connection was attempted on that process. A clean restart and restoration of the original panel
   configuration completed the experiment.

A preceding handshake-only control did not reproduce the crash. It must not be treated as equivalent
to an activated graphical session. An earlier raw-only-encoding experiment caused a different Apple
assertion (`receive_client_message_set_encodings`) and is not evidence for this reconnect mechanism.

## Impact and remediation boundary

Retaining noVNC instances across navigation avoids this transition during tab/VM switches. It does not
survive page reload, closing the browser, loss of connectivity, or restarting the panel. The experimental
console therefore remains unsafe to rely on for guest availability on this host build.

The direct test validates a candidate workaround: maintain a supervised graphical VNC client for the
entire Tart process lifetime, independent of browsers and the panel, so browser reconnects never return
from zero clients. A production implementation must establish it before exposing console credentials,
consume server traffic, and withdraw console availability if it fails. It must not blindly reconnect the
anchor after the client count may have reached zero or automatically sacrifice the VM to recover a console.
This workaround has **not** been deployed. The temporary diagnostic client was removed.

An Apple fix or a different display backend would remove this dependency; neither has been validated here.
Do not present the frontend navigation change as a fix for reload stability.
