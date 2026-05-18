# Two-stage build: the SAP installer payload extracts to ~2 GB under
# /opt/tmp during the build. By doing the install in a builder stage
# and copying only /opt/sybase to the runtime stage, we keep none of
# that staging junk in the published image.

# SAP ASE 16 Developer Edition tarball. SAP rotates these CloudFront paths
# from time to time; if the download starts returning an error page, get a
# fresh link from the trial page and pass it via --build-arg ASE_SUITE_URL=
#   Trial:   https://www.sap.com/products/data-cloud/sybase-ase/trial.html
#   Linux:   https://d1cuw2q49dpd0p.cloudfront.net/ASE16/Current/ASE_Suite.linuxamd64.tgz
#   Windows: https://d1cuw2q49dpd0p.cloudfront.net/ASE16/Current/ASE_Suite.winx64.zip
ARG ASE_SUITE_URL=https://d1cuw2q49dpd0p.cloudfront.net/ASE16/Current/ASE_Suite.linuxamd64.tgz


# ============================================================
# Stage 1 — install SAP ASE under /opt/sybase
# ============================================================
FROM rockylinux:9 AS builder

ARG ASE_SUITE_URL

# SAP installer build deps
# - libaio: ASE links against it even with async I/O disabled at runtime
# - gtk2: InstallAnywhere loads gtk libs at startup even in silent mode
# - glibc.i686: setup.bin and a few legacy ASE tools are 32-bit
# - findutils: rockylinux minimal does not ship find/xargs, used by the
#   setup.bin discovery below
RUN dnf install -y libaio gtk2 glibc.i686 findutils \
 && dnf clean all

RUN set -x \
 && curl -fLS -o ASE_Suite.linuxamd64.tgz "${ASE_SUITE_URL}" \
 && mkdir -p /opt/tmp/ \
 && tar xfz ASE_Suite.linuxamd64.tgz -C /opt/tmp/ \
 && rm -rf ASE_Suite.linuxamd64.tgz

COPY assets/* /opt/tmp/

# Install Sybase. The SAP tarball contains several setup.bin (one per
# product: ASE itself, SySAM license manager, possibly OCS, etc.). The
# top-level directory naming also drifts between releases, so locate
# the ASE installer dynamically: exclude sysam_setup/, then pick the
# first remaining match. Run it from its own directory because the
# InstallAnywhere LAX runtime resolves its resources relative to cwd.
RUN set -ex \
 && ALL_SETUPS="$(find /opt/tmp -maxdepth 3 -name setup.bin -type f)" \
 && SETUP_BIN="$(echo "$ALL_SETUPS" | grep -iv sysam | head -1)" \
 && if [ -z "$SETUP_BIN" ]; then \
      echo "ASE setup.bin not found under /opt/tmp; tarball layout changed?"; \
      echo "All setup.bin found:"; echo "$ALL_SETUPS"; \
      ls -la /opt/tmp/; \
      exit 1; \
    fi \
 && echo "Using SAP installer at: $SETUP_BIN" \
 && cd "$(dirname "$SETUP_BIN")" \
 && ./setup.bin -f /opt/tmp/sybase-response.txt \
    -i silent \
    -DAGREE_TO_SAP_LICENSE=true \
    -DRUN_SILENT=true

# All post-install steps below resolve the ASE install directory from
# $SYBASE_ASE (set by SYBASE.sh), so they keep working when SAP bumps
# the SP and installs under a different versioned dir than ASE-16_0.
# The .rs templates in assets/ also have internal /opt/sybase/ASE-16_0
# references (errorlog, tape_config_file); rewrite them before srvbuildres
# consumes them.
RUN source /opt/sybase/SYBASE.sh \
 && sed -i "s|/opt/sybase/ASE-16_0|/opt/sybase/${SYBASE_ASE}|g" \
        /opt/tmp/sybase-ase.rs /opt/tmp/sybase-bs.rs \
 && cp /opt/tmp/sybase-ase.rs /opt/sybase/${SYBASE_ASE}/sybase-ase.rs \
 && cp /opt/tmp/sybase-bs.rs  /opt/sybase/${SYBASE_ASE}/sybase-bs.rs

# Build ASE server
RUN source /opt/sybase/SYBASE.sh \
 && /opt/sybase/${SYBASE_ASE}/bin/srvbuildres -r /opt/sybase/${SYBASE_ASE}/sybase-ase.rs

# Disable async I/O (kAIO often unavailable / misbehaving in Docker)
RUN source /opt/sybase/SYBASE.sh \
 && sed -i 's|allow sql server async i/o = DEFAULT|allow sql server async i/o = 0|g' \
        /opt/sybase/${SYBASE_ASE}/MYSYBASE.cfg

# Add trace flag -T11889 to RUN_MYSYBASE (workaround for tempdb default
# segment check that prevents ASE Dev Edition from starting in some envs)
RUN source /opt/sybase/SYBASE.sh \
 && sed -i '$ d' /opt/sybase/${SYBASE_ASE}/install/RUN_MYSYBASE \
 && echo "-T11889" >> /opt/sybase/${SYBASE_ASE}/install/RUN_MYSYBASE \
 && sed -i 's|-T11889|-T11889 \\|g' /opt/sybase/${SYBASE_ASE}/install/RUN_MYSYBASE

# Build Backup Server
RUN source /opt/sybase/SYBASE.sh \
 && /opt/sybase/${SYBASE_ASE}/bin/srvbuildres -r /opt/sybase/${SYBASE_ASE}/sybase-bs.rs

# Install the custom interfaces file and entrypoint script into the
# layout the runtime stage will COPY from.
RUN mv /opt/sybase/interfaces /opt/sybase/interfaces.backup \
 && cp /opt/tmp/interfaces /opt/sybase/ \
 && cp /opt/tmp/sybase-entrypoint.sh /usr/local/bin/ \
 && chmod +x /usr/local/bin/sybase-entrypoint.sh

# Trim ~1.25 GB from /opt/sybase that the runtime stage does not need.
# Mostly diag* debug builds of dataserver/backupserver/xpserver (400 MB
# of diagserver alone), several copies of bundled JREs that only the
# Java-based SAP admin tools use, the JDBC driver, dev libs (we ship
# only the runtime shared libs), and installer leftovers.
RUN set -ex \
 && rm -rf /opt/sybase/sybuninstall \
           /opt/sybase/jre64 \
           /opt/sybase/shared/SAPMACHINE-21_00_10_64BIT \
           /opt/sybase/shared/SAPJRE-8_1_108_64BIT \
           /opt/sybase/shared/ase/SAPJRE-8_1_108_64BIT \
           /opt/sybase/jConnect-16_1 \
           /opt/sybase/jutils-3_0 \
           /opt/sybase/WLA \
           /opt/sybase/WS-16_1 \
           /opt/sybase/SYBDIAG \
           /opt/sybase/log \
           /opt/sybase/OCS-16_1/devlib \
           /opt/sybase/OCS-16_1/devlib3p64 \
 && find /opt/sybase/ASE-16_1/bin -maxdepth 1 \
        \( -name 'diag*' -o -name '*.sym' \) -delete


# ============================================================
# Stage 2 — lean runtime image (no /opt/tmp, no findutils)
# ============================================================
FROM rockylinux:9

LABEL org.opencontainers.image.authors="Tuan Vo <vohungtuan@gmail.com>"

# Runtime deps. procps-ng for `ps`, which for diagnostics inside the
# container (both used by the CI smoke test and by users).
RUN dnf install -y libaio gtk2 glibc.i686 procps-ng which \
 && dnf clean all

COPY --from=builder /opt/sybase /opt/sybase
COPY --from=builder /usr/local/bin/sybase-entrypoint.sh /usr/local/bin/
RUN ln -s /usr/local/bin/sybase-entrypoint.sh /sybase-entrypoint.sh

# Auto-source SYBASE.sh in every interactive shell so `docker exec -it
# <container> bash` has isql / dataserver / SYBASE_ASE / etc. in the
# environment without having to source it manually. /etc/profile.d/*.sh
# is read by /etc/bashrc on Rocky, which is sourced by root's ~/.bashrc.
RUN echo '. /opt/sybase/SYBASE.sh' > /etc/profile.d/sybase.sh

# SAP's locales.dat does not know "C.UTF-8" (Rocky 9 default), and isql
# refuses to start without a matching entry. Set en_US.UTF-8 in both
# /etc/locale.conf (which /etc/profile.d/lang.sh sources for every
# interactive login/non-login shell, overwriting any prior LANG value)
# and ENV (for non-interactive contexts like the entrypoint and
# `docker exec my-sybase bash -c '...'`). en_US.UTF-8 is in locales.dat
# and matches the glibc-langpack-en pulled in as a dep above.
RUN echo 'LANG=en_US.UTF-8' > /etc/locale.conf
ENV LANG=en_US.UTF-8

ENTRYPOINT ["/sybase-entrypoint.sh"]

EXPOSE 5000 5001
