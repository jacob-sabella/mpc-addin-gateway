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
- [ ] 6. Device test: Key 37 and MPC Sample
- [ ] 7. mpc-vst-plugins branch (local commit only)
- [ ] 8. Repo public, release dry run, draft 0.1.0

## Changes other addins need (not made here)
One line each in their addin.manifest (and the release that ships it):
- mpc-addin-filebrowser: `ADDIN_WEB_PORT=6760` and `ADDIN_WEB_PORT_SETTING=port`. Only add `ADDIN_WEB_PATH=/files/`
  together with writing FileBrowser Quantum's `server.baseURL: "/files/"` in filebrowser-run.sh; until then it gets port 16760.
- mpc-addin-remote: `ADDIN_WEB_PORT=6720` and `ADDIN_WEB_PORT_SETTING=port` (check its settings key name).
- mpc-addin-commander: `ADDIN_WEB_PORT=6730` and `ADDIN_WEB_PORT_SETTING=port` (check its settings key name).
- mpc-addin-filebrowser and mpc-addin-remote: their is_mpc_process() only accepts "MPC", so they never start on the
  MPC Sample (whose binary is "/usr/bin/MPC Sample"); Commander already accepts both.
For the device test (step 6) the gateway's own routes.d / forward= can stand in, or the installed manifests on the test
device can get the lines by hand (they're the device copies, not the repos).
