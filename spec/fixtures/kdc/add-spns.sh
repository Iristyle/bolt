#!/bin/sh
set -e

# TODO: add SPNs using samba-tool with env vars
cat << EOF

************************************************************
Adding SPNs
************************************************************

EOF

# wait for the DC to be listening
until samba-tool computer list | grep -q OMISERVER\\$
do
    echo "Waiting for computer OMISERVER\$ to be domain joined... exit status: $?"
    sleep 1s
done
# TESTING THIS for now to see if it works before OMISERVER$ is domain joined
# samba-tool spn add HTTP/bolt.test OMISERVER$
# TODO: not sure if this second one is necessary!
# this is how the WinRM gem requests the SPN
# https://github.com/WinRb/WinRM/blob/2a9a2ff55c5bbd903a019d63b1d134ac32ead4c7/lib/winrm/http/transport.rb#L299
samba-tool spn add HTTP/OMISERVER@BOLT.TEST OMISERVER$
samba-tool spn add HTTP/omiserver.bolt.test@BOLT.TEST OMISERVER$
samba-tool spn list OMISERVER$
samba-tool computer show OMISERVER$
