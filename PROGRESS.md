# Progress: mpc-addin-gateway 0.1.0

Working notes for the autonomous build (goal: a Caddy gateway that lists and routes the web services other addins
declare in addin.manifest). Each step is ticked with the date and its evidence (offline = Docker/QEMU, device = hardware).

- [x] 1. Smoke test green on both CPUs (2026-11-09, offline). One admin-off stand-in Caddy for the backends; a new run
      stops the earlier run's script (run.pid) before its Caddy, so a lingering MPC can't restart the old Caddy.
      `tests/smoke.sh armv7` and `aarch64`: 19/19 ok, PASSED. Note: VmRSS under qemu-user reads ~100 MB, which includes
      the emulator; measure on a device (step 6).
- [ ] 2. ADDIN_WEB_* manifest keys drive routes and forwards
- [ ] 3. Landing page with up/down from /proc/net/tcp
- [ ] 4. Host tests (tests/test.sh) + smoke coverage for the keys
- [ ] 5. Workflows + README
- [ ] 6. Device test: Key 37 and MPC Sample
- [ ] 7. mpc-vst-plugins branch (local commit only)
- [ ] 8. Repo public, release dry run, draft 0.1.0

## Changes other addins need (not made here)
(filled in at step 2)
