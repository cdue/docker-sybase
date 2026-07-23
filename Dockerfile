# Two-stage build: keep the ~2 GB SAP installer payload in the builder
# stage and copy only /opt/sybase into the runtime image.

# SAP rotates this CloudFront URL periodically — see README
# "Refreshing the SAP installer URL" if the build starts failing.
ARG ASE_SUITE_URL=https://d1cuw2q49dpd0p.cloudfront.net/ASE16/Current/ASE_Suite.linuxamd64.tgz

# SAP ASE only ships x86_64 binaries (and the installer needs 32-bit
# x86 glibc), so default both stages to amd64 — on Apple Silicon the
# build then runs under Rosetta emulation instead of failing on
# glibc.i686. An ARG (not a constant) keeps the BuildKit linter happy
# and the value overridable, even though no other platform can work.
ARG ASE_PLATFORM=linux/amd64


# ============================================================
# Stage 1 — install SAP ASE under /opt/sybase
# ============================================================
FROM --platform=$ASE_PLATFORM rockylinux:9 AS builder

ARG ASE_SUITE_URL

# - libaio:     ASE links against it even with async I/O disabled.
# - gtk2:       InstallAnywhere loads gtk libs even in silent mode.
# - glibc.i686: setup.bin and a few legacy ASE tools are 32-bit.
# - findutils:  rockylinux minimal does not ship find; used to locate
#               setup.bin in the tarball below.
RUN dnf install -y libaio gtk2 glibc.i686 findutils \
 && dnf clean all

RUN set -x \
 && curl -fLS -o ASE_Suite.linuxamd64.tgz "${ASE_SUITE_URL}" \
 && mkdir -p /opt/tmp/ \
 && tar xfz ASE_Suite.linuxamd64.tgz -C /opt/tmp/ \
 && rm -rf ASE_Suite.linuxamd64.tgz

COPY assets/* /opt/tmp/

# The tarball contains several setup.bin (ASE, SySAM, FaultManager, …)
# under directory names that drift between releases — locate the ASE
# one dynamically by excluding the known non-ASE installers
# (sysam_setup, FaultManager). Run it from its own directory because
# the InstallAnywhere LAX runtime resolves resources relative to cwd.
RUN set -ex \
 && ALL_SETUPS="$(find /opt/tmp -maxdepth 3 -name setup.bin -type f)" \
 && SETUP_BIN="$(echo "$ALL_SETUPS" | grep -ivE 'sysam|faultmanager' | head -1)" \
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

# Resolve the ASE install dir from $SYBASE_ASE (set by SYBASE.sh) so
# everything below keeps working when SAP bumps the SP and installs
# under a different versioned dir (ASE-16_1 instead of ASE-16_0). The
# .rs templates also contain internal /opt/sybase/ASE-16_0 references
# (errorlog, tape_config_file) — rewrite those before srvbuildres
# consumes them.
RUN source /opt/sybase/SYBASE.sh \
 && sed -i "s|/opt/sybase/ASE-16_0|/opt/sybase/${SYBASE_ASE}|g" \
        /opt/tmp/sybase-ase.rs /opt/tmp/sybase-bs.rs \
 && cp /opt/tmp/sybase-ase.rs /opt/sybase/${SYBASE_ASE}/sybase-ase.rs \
 && cp /opt/tmp/sybase-bs.rs  /opt/sybase/${SYBASE_ASE}/sybase-bs.rs

RUN source /opt/sybase/SYBASE.sh \
 && /opt/sybase/${SYBASE_ASE}/bin/srvbuildres -r /opt/sybase/${SYBASE_ASE}/sybase-ase.rs

# kAIO is often unavailable or misbehaving in Docker.
RUN source /opt/sybase/SYBASE.sh \
 && sed -i 's|allow sql server async i/o = DEFAULT|allow sql server async i/o = 0|g' \
        /opt/sybase/${SYBASE_ASE}/MYSYBASE.cfg

# -T11889 disables a tempdb default-segment check that prevents Dev
# Edition from starting in some envs.
RUN source /opt/sybase/SYBASE.sh \
 && sed -i '$ d' /opt/sybase/${SYBASE_ASE}/install/RUN_MYSYBASE \
 && echo "-T11889" >> /opt/sybase/${SYBASE_ASE}/install/RUN_MYSYBASE \
 && sed -i 's|-T11889|-T11889 \\|g' /opt/sybase/${SYBASE_ASE}/install/RUN_MYSYBASE

RUN source /opt/sybase/SYBASE.sh \
 && /opt/sybase/${SYBASE_ASE}/bin/srvbuildres -r /opt/sybase/${SYBASE_ASE}/sybase-bs.rs

RUN mv /opt/sybase/interfaces /opt/sybase/interfaces.backup \
 && cp /opt/tmp/interfaces /opt/sybase/ \
 && cp /opt/tmp/sybase-entrypoint.sh /usr/local/bin/ \
 && chmod +x /usr/local/bin/sybase-entrypoint.sh

# Trim ~1.25 GB the runtime stage does not need: diag* debug builds of
# dataserver/backupserver/xpserver (400 MB of diagserver alone), bundled
# JREs used only by the Java-based SAP admin tools, the JDBC driver,
# dev libs (we ship only the runtime shared libs), installer leftovers.
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
FROM --platform=$ASE_PLATFORM rockylinux:9

# procps-ng provides `ps`, and `which` is used for diagnostics inside
# the container (both by the CI smoke test and by users at the prompt).
RUN dnf install -y libaio gtk2 glibc.i686 procps-ng which \
 && dnf clean all

COPY --from=builder /opt/sybase /opt/sybase
COPY --from=builder /usr/local/bin/sybase-entrypoint.sh /usr/local/bin/
RUN ln -s /usr/local/bin/sybase-entrypoint.sh /sybase-entrypoint.sh

# Auto-source SYBASE.sh in every interactive shell so `docker exec -it`
# has isql / dataserver / $SYBASE_ASE / etc. without manual sourcing.
RUN echo '. /opt/sybase/SYBASE.sh' > /etc/profile.d/sybase.sh

# SAP's locales.dat does not know Rocky 9's default C.UTF-8 and isql
# refuses to start without a matching entry. Set en_US.UTF-8 in both
# /etc/locale.conf (read by /etc/profile.d/lang.sh in interactive
# shells, where it overwrites any prior LANG) and ENV (for the
# entrypoint and `docker exec … bash -c '…'`).
RUN echo 'LANG=en_US.UTF-8' > /etc/locale.conf
ENV LANG=en_US.UTF-8

ENTRYPOINT ["/sybase-entrypoint.sh"]

EXPOSE 5000 5001
