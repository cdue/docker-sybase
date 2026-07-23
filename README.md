# Docker Sybase ASE image (2K page size)

[![build](https://github.com/cdue/docker-sybase/actions/workflows/build.yml/badge.svg)](https://github.com/cdue/docker-sybase/actions/workflows/build.yml)

Docker image for **SAP ASE 16.0 Developer Edition** with a **2 KB logical page size** (instead of the upstream 16 KB) so it can `LOAD DATABASE` dumps from legacy 2K Sybase instances. A **Backup Server** (`MYSYBASE_BS`, port 5001) is built and started alongside the dataserver to make `DUMP` / `LOAD DATABASE` work out of the box.

This repo is inspired by [`nguoianphu/docker-sybase`](https://github.com/nguoianphu/docker-sybase) and also incorporates the dev-ergonomics layer from [`DataGrip/docker-env/sybase/16.0`](https://github.com/DataGrip/docker-env/tree/master/sybase/16.0) (async I/O off, `-T11889` trace flag, entrypoint auto-creates a configurable user database on first boot).

## Build

        docker build -t sybase .

The build downloads a ~500 MB tarball from a SAP Cloudfront URL and runs the ASE installer + two `srvbuildres` passes. Expect 10–20 minutes.

## Run

        docker run -d -p 5000:5000 -p 5001:5001 --name my-sybase sybase

Port 5000 is the dataserver (`MYSYBASE`), port 5001 is the Backup Server (`MYSYBASE_BS`). Follow the boot with `docker logs -f my-sybase` and wait for the line `SYBASE INITIALIZED` (~60–120 s on a warm host).

### Default credentials

#### Admin user (created by `srvbuildres` at image build time, password hardcoded in `assets/sybase-ase.rs`)

| Field | Default value |
| --- | --- |
| `SYBASE_USER` | `sa` |
| `SYBASE_PASSWORD` | `myPassword` |

#### Developer user (created by the entrypoint on first boot, configurable via env vars)

| Environment variable | Default value |
| --- | --- |
| `SYBASE_USER` | `tester` |
| `SYBASE_PASSWORD` | `guest1234` |
| `SYBASE_DB` | `testdb` |
| `SYBASE_DB_SIZE` | `48` (MB) |
| `SYBASE_TEMPDB_SIZE` | `80` (MB) |

`SYBASE_DB_SIZE` controls the size of `$SYBASE_DB` (the user database the entrypoint creates on first boot, carved from the `master` device — `master` itself stays at 80 MB and is not exposed). `SYBASE_TEMPDB_SIZE` controls the size of `tempdb`, which matters for `LOAD DATABASE` of larger dumps and for sort- or temp-table-heavy queries. Both grow their backing devices at runtime, in the container's writable layer, so the **published image stays the same size** regardless of the values you pick — only the running container uses more disk.

Override the developer user / database at `docker run`:

        docker run -d -p 5000:5000 -p 5001:5001 \
          -e SYBASE_USER=foo -e SYBASE_PASSWORD=bar -e SYBASE_DB=baz \
          --name my-sybase sybase

Override the database / tempdb sizes (useful when restoring larger dumps):

        docker run -d -p 5000:5000 -p 5001:5001 \
          -e SYBASE_DB_SIZE=200 -e SYBASE_TEMPDB_SIZE=500 \
          --name my-sybase sybase

### Check with isql

        docker exec -it my-sybase /bin/bash
        source /opt/sybase/SYBASE.sh
        isql -U sa -P myPassword -S MYSYBASE

        select @@maxpagesize
        go
        -- should return 2048

### Mount licenses (optional)

        docker run -d -p 5000:5000 -p 5001:5001 \
          -v /path/to/sybase_licenses:/opt/sybase/SYSAM-2_0/licenses \
          --name my-sybase sybase

## Refreshing the SAP installer URL

The Dockerfile downloads the SAP ASE 16 Developer Edition tarball from a CloudFront URL that SAP rotates from time to time. The default in `Dockerfile` (`ARG ASE_SUITE_URL=…`) is what was valid at the time of writing; if a build starts failing with a curl error or `tar: stdin: not in gzip format`, the URL has changed and you need to refresh it.

To get a fresh link, go to the **[SAP ASE Developer Edition trial page](https://www.sap.com/products/data-cloud/sybase-ase/trial.html)**, accept the licence and copy the **Linux** download URL (typically `https://d1cuw2q49dpd0p.cloudfront.net/ASE16/…/ASE_Suite.linuxamd64.tgz`).

Override the URL locally at build time:

        docker build --build-arg ASE_SUITE_URL=<new URL> -t sybase .

Or, in CI, set this **Repository variable** (Settings → Secrets and variables → Actions → Variables) so the workflow keeps building without touching the Dockerfile:

| Type | Name | Example |
| --- | --- | --- |
| Variable | `ASE_SUITE_URL` | `https://d1cuw2q49dpd0p.cloudfront.net/ASE16/Current/ASE_Suite.linuxamd64.tgz` |

When `ASE_SUITE_URL` is unset on the repo, the workflow falls back to the default URL baked into the `Dockerfile`.

## Publishing to Docker Hub

The GitHub Actions workflow (`.github/workflows/build.yml`) pushes the image to Docker Hub after a successful build, on every push to a branch (not on pull requests). The tag is the branch name, except `main` and `master` which both publish as `latest`. Slashes in branch names are sanitized to dashes (`feature/foo` → `feature-foo`).

The push is **off by default** in any fork — it only runs if the Docker Hub variable below is set, so forking the repo never breaks CI.

To enable it, go to **Settings → Secrets and variables → Actions** in your fork and add the following at the **Repository** scope:

| Type | Name | Example | Purpose |
| --- | --- | --- | --- |
| Secret | `DOCKERHUB_USERNAME` | `your-dockerhub-username` | Docker Hub login |
| Secret | `DOCKERHUB_TOKEN` | (Docker Hub access token) | Generated under Docker Hub → Account Settings → Security → Access Tokens with `Read & Write` scope. Do **not** use your account password. |
| Variable | `DOCKERHUB_IMAGE` | `your-dockerhub-username/docker-sybase` | Full Docker Hub repo path to push to |

Then pull the published image:

        docker run -d -p 5000:5000 -p 5001:5001 --name my-sybase $DOCKERHUB_IMAGE:latest

(replace `$DOCKERHUB_IMAGE` with the value you configured, e.g. `your-dockerhub-username/docker-sybase`).

## SAP ASE Developer Edition reference

- Trial / download page: https://www.sap.com/products/data-cloud/sybase-ase/trial.html
- Linux: https://d1cuw2q49dpd0p.cloudfront.net/ASE16/Current/ASE_Suite.linuxamd64.tgz
- Windows: https://d1cuw2q49dpd0p.cloudfront.net/ASE16/Current/ASE_Suite.winx64.zip
