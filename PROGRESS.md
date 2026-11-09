# Progress: mpc-addin-gateway 0.1.0

Working notes for the autonomous build (goal: a Caddy gateway that lists and routes the web services other addins
declare in addin.manifest). Each step is ticked with the date and its evidence (offline = Docker/QEMU, device = hardware).

- [x] 1. Smoke test green on both CPUs (2026-11-09, offline). One admin-off stand-in Caddy for the backends; a new run
      stops the earlier run's script (run.pid) before its Caddy, so a lingering MPC can't restart the old Caddy.
      `tests/smoke.sh armv7` and `aarch64`: 19/19 ok, PASSED. Note: VmRSS under qemu-user reads ~100 MB, which includes
      the emulator; measure on a device (step 6).
- [x] 2. ADDIN_WEB_* manifest keys drive routes and forwards (2026-11-09, offline). Only ADDIN_WEB_PORT,
      ADDIN_WEB_PORT_SETTING, ADDIN_WEB_PATH, ADDIN_NAME, ADDIN_CONF are read, with sed. A path service is `redir
      /p /p/` + `handle /p/*` (not stripped: the addin declares it works under that path); otherwise port+10000 (next free).
      Hardcoded forward= defaults and gateway.caddy/`# name:` headers removed; forward= (empty) and routes.d/ stay for
      your own. Smoke: "a manifest holding shell code is never run" ($(touch /tmp/pwned) in both keys: no file, logged),
      port from the addin's settings (6761 over 6760), Host rewritten as through a tunnel. 26/26 both CPUs.
- [x] 3. Landing page with up/down from /proc/net/tcp (2026-11-09, offline). LISTEN rows on 127.0.0.1/0.0.0.0/::1/::
      for the declared port, nothing sent to it. services.json + server-rendered list (works without JS; the script
      refreshes every 5 s from location.origin), written only when it changed; Caddy reloads only when the services or
      addresses change (smoke: a service starting later turns up "without a reload"; an addin removed while running
      disappears and its port closes, the other routes survive). Headless Chromium screenshot checked by eye.
- [x] 4. Host tests + smoke coverage (2026-11-09, offline). tests/test.sh: 59/59 ok, PASSED (library launch rules in
      /bin/sh and a static BusyBox from busybox:1.36-musl; manifests: collisions move up past forward= ports, `..` paths,
      bad ports, a settings file outside the addin's folder never read, no reload when nothing changed, reload on
      install/removal; setting fallbacks; refusals). Smoke (real Caddy, QEMU) covers the keys, up/down and a removed addin.
- [x] 5. Workflows + README (2026-11-09, offline). test.yml/release.yml/upstream.yml from filebrowser's; release.yml
      pins mpc-vst-plugins 03af9a4 (main; its addin-release.yml has package_dir_aarch64/build_aarch64); YAML parses.
      README in the filebrowser style (not-a-Caddy-project warning, Vibe Coded, Caddy Apache-2.0 credit). Also found
      while checking the Sample: its process is "/usr/bin/MPC Sample", so the library now starts there too (host test
      "the MPC Sample's process (MPC Sample) starts it" ok).
- [x] 6. Device test (2026-11-09, device). Installed from the release zips with the shared installer (`install.sh -y -n`,
      then bind=0.0.0.0 and addins_dir=/data/gwtest in the gateway's own settings, then an MPC restart). The test
      addins_dir held copies of Remote/Commander/FileBrowser manifests with ADDIN_WEB_* added; their settings files were
      read through symlinks to the real ones, so no other addin's files changed. Plus a path-declared demo (a stand-in
      Caddy on 6799) and an addin with no web service.
      **Key 37 (Gen1, 3.9.1.2):** up ~4 s after MPC starts. 401 without/with a wrong password (0.17 s, bcrypt 10),
      200 with it (20 ms cached). Landing page lists Commander/FileBrowser/Remote up, demo down; demo started -> up with no
      Caddy reload; /demo/x routed (Host 127.0.0.1:6799), /demo -> 302 /demo/. FileBrowser via 16760 (its login page).
      Remote via 16720: /info, /screen.png, /stream (multipart, 9 frames in 4 s, not buffered), /mcp initialize OK
      through the Host rewrite. **Remote has no WebSocket** (the screen is the /stream multipart). Commander via 16730:
      /info, WebSocket /ws -> 101 (401 without the password), and its own web page in headless Chromium through the
      gateway shows "connected" (wss through basic auth). Certificate: CN Caddy Local Authority, SAN the device IP,
      verifies with the downloaded root.crt by bare IP. Caddy RSS 46-47 MB, 11 threads. CPU (10 s, % of one core):
      MPC stopped 0 / MPC 14; playing 0 / 20; playing + screen stream through it <1 / 44 (Remote's encoding, in MPC);
      playing + 200 page loads 20 / 22. Found and fixed on the device: its BusyBox head has no -c (password generation
      failed) -> dd bs=1 count=20, plus a host-test lint for head -c/-NUM.
      **MPC Sample (Gen2 aarch64, 1.3.0.12):** no addins were preloaded (no LD_PRELOAD, /etc not persistent; the
      installer's drop-in goes to /run). Found and fixed: the library only started in a process named "MPC"; the Sample's
      is "/usr/bin/MPC Sample" (now both; host test). Up ~1 s after MPC starts; 401/401(0.23 s)/200; landing page with
      Remote/Commander declared but down, demo up; /demo routed; a down service's port answers 502 "<name> isn't running
      on this device right now" (added after seeing a bare 502); certificate verifies by IP. Caddy RSS 49-51 MB; 200 page
      loads 9% of one core. MPC playback not measured on the Sample (no Remote loaded to press PLAY; nothing else touched).
      **Uninstall:** `uninstall.sh -y` on both; Key 37 drop-in md5 back to c0de1549 (baseline), Sample back to no
      drop-in and no LD_PRELOAD; nothing on 443/forward ports; no caddy process. The uninstaller keeps the folder
      (password, certificates: documented); deleted by hand with the test folders. Both devices left running MPC.
- [x] 7. mpc-vst-plugins branch addin-web-keys (2026-11-09, offline), local commits 9c243a8 + ed4ed1b, not pushed:
      the installer, release_addin.py and catalog_check.py read and check ADDIN_WEB_PORT / _PORT_SETTING / _PATH and
      ADDIN_LOGIN; the network prompt asks for a password with ADDIN_LOGIN=1 instead of "no login"; ADDINS.md,
      CATALOG_SPEC.md, NOTES.md (dated device facts). tools/test_addin.sh: "installer: all passed" (sh and BusyBox).
      tools/test_catalog.py: 181 tests OK. (A first run had 20 StoreTest failures, "MPC did not stop", the same on clean
      origin/main: three orphaned "MPC Sample" stand-ins from another repo's host tests, alive since 2026-11-06, made
      pidof "MPC Sample" true. Killed; StoreTest 33 OK, then the full suite 181 OK.) Also 63471af: the shared installer's
      head -c (absent from the devices' BusyBox) replaced by dd, with a test_addin.sh lint that fails on the old line. Gateway manifest gets ADDIN_LOGIN=1 only once
      a release pins tools that accept it (the release now pins 03af9a4, whose checker refuses unknown keys).
- [x] 8. Repo public, release dry run, draft 0.1.0 (2026-11-09). github.com/jacob-sabella/mpc-addin-gateway (public, pushed over
      SSH). Release dry run 42636740879: success (test.sh PASSED, smoke PASSED armv7 + aarch64, catalog_check on both zips).
      Release 42637263468: draft gateway-addin-v0.1.0 with both zips, draft=true, not published (publish as a prerelease
      only when asked). The draft's aarch64 zip is installed on the MPC Sample at the user's request (2026-11-09), bind=0.0.0.0
      (its only network is the USB link): 401 without the password, 200 with it. The shared installer printed
      "head: invalid option -- 'c'": fixed on the mpc-vst-plugins branch (63471af, dd), not yet in the pinned tools.

## Changes other addins need (not made here)
One line each in their addin.manifest (and the release that ships it):
- mpc-addin-filebrowser: `ADDIN_WEB_PORT=6760` and `ADDIN_WEB_PORT_SETTING=port`. Only add `ADDIN_WEB_PATH=/files/`
  together with writing FileBrowser Quantum's `server.baseURL: "/files/"` in filebrowser-run.sh; until then it gets port 16760.
- mpc-addin-remote: `ADDIN_WEB_PORT=6720` and `ADDIN_WEB_PORT_SETTING=port` (check its settings key name).
- mpc-addin-commander: `ADDIN_WEB_PORT=6730` and `ADDIN_WEB_PORT_SETTING=port` (check its settings key name).
- To live under the main port instead of +10000 ports (the user's preference, 2026-11-09): FileBrowser writes
  `server.baseURL` and declares `ADDIN_WEB_PATH=/files/`; Remote's page and Commander's web app use root-absolute
  URLs (`/stream`, `/ws`, ...) that must become relative before they can declare a path.
- mpc-addin-filebrowser and mpc-addin-remote: their is_mpc_process() only accepts "MPC", so their preloaded library never
  starts on the MPC Sample (whose binary is "/usr/bin/MPC Sample"); Commander already accepts both. Remote does run on
  the Sample through its `standalone` program (its own process; README, tested on 1.3.0.12 on 2026-10-16).
For the device test (step 6) the gateway's own routes.d / forward= can stand in, or the installed manifests on the test
device can get the lines by hand (they're the device copies, not the repos).

## Stop-condition evidence (2026-11-09)
- Video: the start page on the Key 37 from the draft 0.1.0 armv7 zip (bind=0.0.0.0, forward= to Remote, Commander,
  FileBrowser and a stand-in "demo" on 6799), 31 s at real speed, 64 frames of the live page: demo down (23 frames),
  up about 7 s after a stand-in server started on 6799 (21), down about 5 s after it stopped (20). Before recording: 401
  without the password, 200 with it; 16720/info, 16730/ and 16760/ all 200 through the gateway.
- Key 37 afterwards: uninstalled, drop-in md5 c0de1549 (baseline), no caddy, 443 and the forward ports closed, folder
  deleted, MPC running.
- MPC Sample: left with the gateway installed and running (bind=0.0.0.0 on its USB link), as the user asked.


## Settings page and default login (user request, 2026-11-09)
- Default login mpc / mpc (user= and password= in the settings); the start page warns while the password is the default.
- Settings page (/settings/) edits every setting through gateway-settings (static C, src/settings.c) on a socket in the
  gateway's folder, behind the password; a POST needs X-Gateway-Settings: 1; Save restarts the gateway with them.
- Host tests PASSED (sh and BusyBox), smoke PASSED armv7 + aarch64, catalog_check OK on both zips.
- Key 37 (device): 401 without the password, 200 with mpc/mpc, banner shown; API 403 without the header; in Chromium
  (DevTools protocol) the page loaded the device's settings, Save wrote rescan_s=9, Caddy and the backend restarted
  (new pids), mpc/mpc 200 afterwards. Then uninstalled; drop-in back to c0de1549; test folders deleted; MPC running.
- MPC Sample: upgraded to this build, left running at bind=0.0.0.0: mpc/mpc 200, settings page 200, backend running.
- Draft gateway-addin-v0.1.0 replaced by one from fca7643 (run 42642122508: all tests PASSED); still a draft.
- Start-page video with declared services (Key 37, addins_dir= test folder of manifest copies with ADDIN_WEB_* lines,
  nothing of the other addins changed): demo down -> up -> down, 31 s.
- Re-measured with the draft's armv7 zip (fca7643) on the Key 37, PLAY/STOP pressed through the gateway (Remote via
  forward=): idle Caddy 0% / MPC 13% of one core; playing 0% / 19%; playing + 200 page loads 22% / 16%. Caddy RSS
  46-48 MB, gateway-settings RSS 376 kB. Then uninstalled; drop-in c0de1549; MPC running.
- MPC Sample, declared services through its own settings page API (addins_dir set to a test folder with copies of its
  real remote and commander manifests plus ADDIN_WEB_* lines, and a declared /demo/): listed from the manifests, remote
  and commander down (not loaded on the Sample), /demo/ 502 while down, served and "up" once a stand-in listened.
  addins_dir restored through the API; folder deleted; gateway left running as the user asked.
- tested.json: the 0.1.0 entries for both devices (2026-11-09) cover this build (fca7643), tested on both today.
- Not tested, needs the user (outside this loop's authorization): Remote / Commander / FileBrowser declaring in their
  own manifests (their repos), and running them on the Sample (Remote and FileBrowser only start in a process named
  "MPC"; FileBrowser isn't installed there; Remote and Commander aren't loaded). Remote has no WebSocket (its screen is
  the multipart /stream, routed and tested on the Key 37); CPU while playing on the Sample needs something to press
  PLAY there (Remote isn't running on it).
- Video (stop-condition evidence): docs/screenshots/landing-key37-declared.mp4, the start page served by the Key 37,
  services from declared manifests (copies with ADDIN_WEB_* lines in an addins_dir test folder), the declared /demo/
  going down -> up -> down as a stand-in starts and stops; 31 s at real speed, 64 frames of the live page.

## User decisions (2026-11-09, after the stop)
- Published gateway-addin-v0.1.0 as a PRERELEASE (user's choice): both zips, from fca7643.
- The three manifest changes are committed locally on branch declare-web-page in each repo (not pushed): remote d9d84d5,
  commander 5403b12, filebrowser 4dd069e (also ADDIN_LOGIN=1). All three check OK with addin_manifest_problems() from
  mpc-vst-plugins addin-web-keys. Their next release needs tools from that branch: the pinned checker (a0dda4f) refuses
  unknown ADDIN_* keys.
- MPC Sample with the real Remote (2026-11-09): Remote's standalone (its own process, from a temp copy) on 6720, and
  addins_dir pointed (through the settings API) at the three repos' declare-web-page manifests. The start page listed
  them from those manifests: Remote up, Commander and FileBrowser down (not running there). Through 16720: /info 200,
  the page 200, 401 without the password, /stream multipart (160 kB in 3 s). Caddy RSS 49-55 MB; 13% of one core under
  200 page loads, 0% while relaying the stream. PLAY could NOT be measured: Remote's button fallback on the Sample writes
  /data/midi.in, which nothing reads while the midi-inject addin isn't loaded (screen unchanged). The four test presses
  (24 bytes) were trimmed off midi.in again (back to 183 bytes); standalone stopped, temp folders deleted, addins_dir
  restored; the gateway left running.
- Video with the real addins (2026-11-09): docs/screenshots/real-addins-key37.mp4, Key 37, prerelease 0.1.0 zip,
  addins_dir = the three repos' declare-web-page manifests (ADDIN_WEB_* declared, nothing forwarded): the start page
  lists Remote, Commander and FileBrowser as running; then each through the gateway: Remote (MPC's live screen),
  Commander ("connected": its WebSocket through basic auth), FileBrowser (its own login page). 16 s.

## One login for FileBrowser (user request, 2026-11-09)
- Gateway aec6cf9: every route to an addin sets X-MPC-Gateway-User to the logged-in user (a client's value replaced).
  Host test and smoke (armv7, aarch64) PASSED: the stand-in sees user=mpc even when the client sends admin.
- mpc-addin-filebrowser, local branch declare-web-page, 8eda5dc: gateway_login=1 (default 0) turns on FileBrowser's
  proxy login on that header, with every file permission (source defaultPermissions), only with bind=127.0.0.1 and the
  gateway addin installed beside it; otherwise off and logged. Admin password login stays. Found while testing and
  fixed in the same commit: a new run now stops an earlier run's script first (run.pid), as the gateway does.
  FileBrowser 2.0.1 facts (QEMU, real binary): password and proxy methods coexist; a header naming the password admin
  is refused ("invalid login method"); userDefaults.permissions is an unknown field (admin can't be granted that way).
  Host test PASSED; smoke PASSED armv7 + aarch64.
- Key 37 (device): gateway 0.1.1 build + a test copy of the new FileBrowser (port 6761, gateway_login=1, own folder,
  the installed FileBrowser untouched): through the gateway, FileBrowser opened straight to the drives as user mpc
  (loginMethod proxy, every permission), no FileBrowser login; a client header naming admin still came in as mpc.
  Cleaned up: test copy stopped and deleted, gateway uninstalled, drop-in c0de1549, MPC running.

## 0.1.1 (2026-11-09)

The release zips were installed on both devices with `sh install.sh -y`.
- **MPC Key 37:** 401 without a login, 200 as mpc/mpc, the settings page answers, and a POST without `X-Gateway-Settings` gets 403. A forward from the settings API was routed, with `header_up X-MPC-Gateway-User` in the Caddyfile. Uninstalled afterwards; the drop-in matches baseline.
- **MPC Sample:** upgraded in place, and its settings were kept (bind=0.0.0.0). The same login, API and 403 checks pass. It stays installed.
- **Known:** the bundled installer from mpc-vst-plugins main still calls `head -c`, which the devices' BusyBox lacks. The modes come out right from a tar copy. The fix is in mpc-vst-plugins PR #785; the next release picks it up.
- **MPC Sample idle, 0.1.1, 2026-11-09:**
  - Over 30 s, Caddy used 0 CPU ticks while MPC used 9% of one core.
  - Caddy's VmRSS is 47540 kB; gateway-settings' is 596 kB.
  - Readings with MPC playing are still open: MPC ignores the injected PLAY presses.
