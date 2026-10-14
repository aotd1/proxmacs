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

## Implemented workaround and failure behavior

Retaining noVNC instances across navigation reduces reconnects within a page. Reload, closing the browser,
loss of connectivity and restarting the panel still close browser connections, so frontend retention alone
cannot prevent the zero-client transition.

`console-runner.py` now establishes a passive, shared RFB 3.8 graphical connection before publishing the
per-boot console endpoint. It uses macOS CommonCrypto for VNC authentication (no secrets in subprocess argv),
negotiates standard display encodings, requests a single 1×1 update, then continuously drains/discards server
traffic in bounded chunks. It does not request a continuous video stream, store images, or send guest input.
No clipboard, Fence or continuous-update extensions are negotiated. A worker thread and a bounded startup
deadline keep the independent PF checks running during connection setup.

The persistent client belongs to the supervisor/Tart lifetime, independently of the panel and browsers.
If authentication, display initialization or the established connection fails, the endpoint is withdrawn.
No new console session is published; existing panel bridges observe endpoint removal within two seconds.
There is no anchor retry and no VM restart. The VM remains available through SSH/guest services, and an
operator can schedule a clean restart to recover the console. PF protection loss retains its separate
fail-closed behavior: kill Tart, remove credentials and pause its system launcher.

Publication and withdrawal share a lock to prevent a failed anchor being republished. This is not an atomic
transaction with Apple's server: a connection already in flight when the anchor fails can still overlap
with the zero-client transition. This workaround protects ordinary browser reloads while its connection
is healthy; it is not a general repair of Apple's private VNC implementation.

## Validation

- Isolated RFB fixture completes authentication and a framebuffer update before the endpoint is exposed.
- Dropping only the persistent socket removes the endpoint, denies new console sessions, and closes an
  existing WebSocket bridge. The mock VM and supervisor remain alive, with no pause marker, reconnect or input.
- Unit tests cover protocol rejection, bounded initialization, publication ordering, anchor withdrawal,
  unchanged PF failure handling, and supervisor upgrade hash checks/rollback on metadata write failure.
- Production negotiation was first tested directly on a fresh guest: the same standard encoding list and
  1×1 request accepted by Apple VNC, followed by ten full-display clients closed with TCP resets. The Tart
  PID stayed unchanged; the temporary test connection was then removed with a clean guest restart.
- The production supervisor was installed on both guests on 2026-10-14 and activated with clean restarts.
  Each guest completed **60 full graphical RFB connections through the authenticated HTTPS/WebSocket bridge**
  (two simultaneous clients, 15 cycles before and 15 after restarting the Proxmacs panel). Both Tart PIDs
  remained unchanged. These are reload-equivalent protocol tests, not an automated browser-page reload.
- The panel restart did not restart the supervisors or guests. Guest SSH, CI runner, friend Internet access
  and fresh PF health were checked. No new Tart crash reports appeared; the latest remained the controlled
  reproduction at 18:41:07.
- Web and headless release Swift builds passed; 5 supervisor tests, 17 PF/upgrade tests, 9 input tests and
  the isolated HTTP/WebSocket integration passed. `swift test` remains blocked by missing XCTest in the
  host Command Line Tools. Long-duration operation, host reboot and Recovery remain unverified.

An Apple fix or a different display backend would remove this dependency; neither has been validated here.
