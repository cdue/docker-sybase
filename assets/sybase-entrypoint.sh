#!/bin/sh

# Source in the Sybase environment variables

source /opt/sybase/SYBASE.sh

# Start the Backup Server in the background
${SYBASE}/${SYBASE_ASE}/install/startserver \
  -f ${SYBASE}/${SYBASE_ASE}/install/RUN_MYSYBASE_BS &

# Start MYSYBASE (dataserver) in the foreground so the container stays alive
${SYBASE}/${SYBASE_ASE}/install/RUN_MYSYBASE
RET=$?

# exit ${RET}
exit 0
