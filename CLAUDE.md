# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Fork of `nguoianphu/docker-sybase` that builds a Docker image for SAP ASE 16 Developer Edition (rockylinux:9 base — upstream uses centos:7 which is EOL and ships glibc 2.17, incompatible with both the JRE bundled in SAP's current installer and the ASE dataserver binary itself, which now requires glibc 2.29+).

Two branches matter:
- `main` — original upstream behaviour (16K pages, dataserver only, no auto-init).
- `sybase-2k` — current line of work. Switches to **2K logical page size** (required to `LOAD DATABASE` from legacy 2K dumps), builds and starts a **Backup Server** (`MYSYBASE_BS`, port 5001) so `DUMP`/`LOAD DATABASE` work, and ports DataGrip's dev-ergonomics layer (async I/O off, `-T11889`, entrypoint auto-creates a user DB on first boot).

## Commands

Build is heavy: downloads a ~500 MB tarball from a SAP Cloudfront URL, installs RPMs, runs `srvbuildres` for the dataserver and (on `sybase-2k`) the Backup Server, then patches generated config files. Expect 10–20 minutes; CI job timeout is 45 min.

```bash
# build
docker build -t sybase .

# run (sybase-2k exposes both ports)
docker run -d -p 5000:5000 -p 5001:5001 --name my-sybase sybase

# follow boot; on sybase-2k, look for "SYBASE INITIALIZED" — the entrypoint
# only reaches that marker after master.dat allocation, "Finished
# initialization." and the init SQL have all completed (~60–120s).
docker logs -f my-sybase

# connect as sa (password is hardcoded in assets/sybase-ase.rs)
docker exec -it my-sybase /bin/bash
source /opt/sybase/SYBASE.sh
isql -U sa -P myPassword -S MYSYBASE

# sybase-2k only: override the auto-created dev user/db (defaults tester/guest1234/testdb)
docker run -d -p 5000:5000 -p 5001:5001 \
  -e SYBASE_USER=foo -e SYBASE_PASSWORD=bar -e SYBASE_DB=baz \
  --name my-sybase sybase
```

CI (`.github/workflows/build.yml`) runs the same `docker build` + smoke test on every push and on PRs to `main`.

## Architecture

The Dockerfile is the whole project — there is no application code. What it actually does, in order:

1. Pull the ASE tarball from the URL in `ARG ASE_SUITE_URL` (overridable with `--build-arg ASE_SUITE_URL=…`, or via the repo variable `vars.ASE_SUITE_URL` in CI), extract to `/opt/tmp/`, copy everything under `assets/` to `/opt/tmp/` as well. The default URL is what SAP serves at the time of the commit; it expires periodically — see README "Refreshing the SAP installer URL" for the recovery procedure.
2. `dnf install -y libaio gtk2 glibc.i686 findutils procps-ng` (SAP setup.bin / ASE need both 64- and 32-bit libc; gtk2 is loaded by InstallAnywhere even in silent mode; findutils for the `find` used by `setup.bin` discovery and the final `/opt/tmp` cleanup; procps-ng for the `ps` used by the CI smoke test).
3. Run the SAP `setup.bin` installer in silent mode driven by `assets/sybase-response.txt` (`SY_CONFIG_*_SERVER=false` everywhere — no server is configured by the installer).
4. **`srvbuildres -r sybase-ase.rs`** generates the dataserver: writes `master.dat`, `MYSYBASE.cfg`, `install/RUN_MYSYBASE`, `install/MYSYBASE.log`, etc. The values in `assets/sybase-ase.rs` (page size, device paths/sizes, sa password, default backup server name) define the server.
5. **(sybase-2k)** Three `sed`/`echo` patches mutate the files srvbuildres just generated:
   - `MYSYBASE.cfg` → `allow sql server async i/o = 0` (kAIO is flaky under Docker).
   - `install/RUN_MYSYBASE` → inject `-T11889` (works around a tempdb default-segment check that prevents Dev Edition from starting in some envs).
   These patches depend on srvbuildres' exact output format — if a future ASE SP changes it, they break silently. There is a known cleaner alternative (replace `RUN_MYSYBASE` wholesale with a hand-crafted `dataserver …` invocation); we chose not to, to keep `sybase-ase.rs` as the single source of truth for paths.
6. **(sybase-2k)** Second `srvbuildres -r sybase-bs.rs` builds the Backup Server. The BS resource file declares `server_name: MYSYBASE_BS` and `port: 5001` — these must match the entry already in `assets/interfaces` and the `sqlsrv.default_backup_server: MYSYBASE_BS` line in `sybase-ase.rs`. Changing names or ports means editing all three.
7. Replace `/opt/sybase/interfaces` with `assets/interfaces`, install `assets/sybase-entrypoint.sh` as `/usr/local/bin/sybase-entrypoint.sh` (symlinked to `/sybase-entrypoint.sh`), expose ports, set entrypoint.

### Entrypoint flow (sybase-2k)

`assets/sybase-entrypoint.sh` is bash (uses `(( ))`, heredocs). Order matters:
1. Start Backup Server in background via `startserver -f RUN_MYSYBASE_BS &`.
2. Start dataserver in background via `RUN_MYSYBASE > /dev/null &` (foreground would block init).
3. Poll `MYSYBASE.log` for `Performing space allocation for device '/opt/sybase/data/master.dat'` (≤60s), then `Finished initialization.` (≤30s). These are byte-count thresholds on `grep | wc -c`, not exact matches.
4. Run two `isql -U sa -P myPassword -S MYSYBASE` scripts to `disk resize` master, `create database $SYBASE_DB`, `create login $SYBASE_USER`, set dev-friendly `sp_dboption`s, `sp_adduser` and grant DDL.
5. `while … sleep 1` with a `trap` on INT/TERM to keep PID 1 alive and shut down cleanly.

The sa password used by the entrypoint's `isql` (`myPassword`) is the same string set by `sqlsrv.sa_password` in `sybase-ase.rs` — if you change one, change both.

## Files you will rarely need to touch

- `assets/sybase-response.txt` — installer config; nothing relevant to page size / BS is set here, do not bother adding `SY_CFG_ASE_PAGESIZE` etc.
- `assets/sybase-response-example.txt` — reference only, not used by the build.
- `assets/sysctl.conf` — system bootstrap, leave alone.
- `assets/interfaces` — already declares both `MYSYBASE` and `MYSYBASE_BS`; only edit if you rename a server or change a port.

## Commit messages

This repo uses [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) for every commit from the fork forward. Format: `<type>[optional scope]: <description>` for the subject, then an optional body. Common types used here: `feat`, `fix`, `docs`, `ci`, `chore`, `refactor`. Examples: `feat: add 2k page size and Backup Server support`, `ci: push image to Docker Hub after successful build`, `docs: rewrite README around the 2k + Backup Server objective`.
