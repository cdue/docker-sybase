# Dockerfile for sybase server

# docker build -t sybase .


FROM centos:7

MAINTAINER Tuan Vo <vohungtuan@gmail.com>

# Adding resources

# SAP ASE 16 Developer Edition tarball. SAP rotates these CloudFront paths
# from time to time; if the download starts returning an error page, get a
# fresh link from the trial page and pass it via --build-arg ASE_SUITE_URL=
#   Trial:   https://www.sap.com/products/data-cloud/sybase-ase/trial.html
#   Linux:   https://d1cuw2q49dpd0p.cloudfront.net/ASE16/Current/ASE_Suite.linuxamd64.tgz
#   Windows: https://d1cuw2q49dpd0p.cloudfront.net/ASE16/Current/ASE_Suite.winx64.zip
ARG ASE_SUITE_URL=https://d1cuw2q49dpd0p.cloudfront.net/ASE16/Current/ASE_Suite.linuxamd64.tgz

RUN set -x \
 && curl -fLS -o ASE_Suite.linuxamd64.tgz "${ASE_SUITE_URL}" \
 && mkdir -p /opt/tmp/ \
 && tar xfz ASE_Suite.linuxamd64.tgz -C /opt/tmp/ \
 && rm -rf ASE_Suite.linuxamd64.tgz


COPY assets/* /opt/tmp/


# Setting kernel.shmmax and 
RUN set -x \
 && cp /opt/tmp/sysctl.conf /etc/ \
 && true || /sbin/sysctl -p

# Installing Sybase RPMs
RUN set -x \
 && rpm -ivh --nodeps /opt/tmp/libaio-0.3.109-13.el7.x86_64.rpm \
 && rpm -ivh --nodeps /opt/tmp/gtk2-2.24.28-8.el7.x86_64.rpm \
 && rpm -Uvh --oldpackage --nodeps /opt/tmp/glibc-2.17-105.el7.i686.rpm


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

# Change the Sybase interface
# Set the Sybase startup script in entrypoint.sh

RUN mv /opt/sybase/interfaces /opt/sybase/interfaces.backup \
 && cp /opt/tmp/interfaces /opt/sybase/ \
 && cp /opt/tmp/sybase-entrypoint.sh /usr/local/bin/ \
 && chmod +x /usr/local/bin/sybase-entrypoint.sh \
 && ln -s /usr/local/bin/sybase-entrypoint.sh /sybase-entrypoint.sh
 

# Setup the ENV
# https://docs.docker.com/engine/reference/builder/#run
# RUN ["/bin/bash", "-c", "source /opt/sybase/SYBASE.sh"]

ENTRYPOINT ["/sybase-entrypoint.sh"]

# CMD []

EXPOSE 5000 5001

# Remove tmp
RUN find /opt/tmp/ -type f | xargs -L1 rm -f

# Share the Sybase data directory
#VOLUME ["/opt/sybase/data"]

# When run it
# docker run -d -p 8000:5000 -p 8001:5001 --name my-sybase sybase