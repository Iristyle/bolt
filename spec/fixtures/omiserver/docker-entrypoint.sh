#!/bin/bash
set -e

/opt/omi/bin/omiserver --version
pwsh --version

cat << EOF

************************************************************
Daemonizing OMI server
************************************************************

EOF

/opt/omi/bin/omiserver -d
# there is a race here which may cause the log to not be created yet
sync

./verify-omi-authentication.sh

cat << EOF

************************************************************
Tailing OMI Server Logs
************************************************************

EOF

tail -f /var/opt/omi/log/omiserver.log
