#!/bin/bash
set -e

/opt/omi/bin/omiserver --version
pwsh --version

./kerberos-client-config.sh
./domain-join.sh

cat << EOF

************************************************************
Daemonizing OMI server
************************************************************

EOF

/opt/omi/bin/omiserver -d
# there is a race here which may cause the log to not be created yet
sync

./omi-enable-kerberos-auth.sh
./verify-omi-authentication.sh

cat << EOF

************************************************************
Tailing OMI Server Logs
************************************************************

EOF

# TODO: can we tail multiple logs simultaneously when debug is on?
tail -f /var/opt/omi/log/omiserver.log
