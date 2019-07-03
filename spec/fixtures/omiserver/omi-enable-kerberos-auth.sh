#!/bin/sh
set -e

if [ -z ${SMB_ADMIN} ]; then
    echo "No SMB_ADMIN_PASSWORD Provided. Exiting ..."
    exit 1
fi

if [ -z ${SMB_ADMIN_PASSWORD} ]; then
    echo "No SMB_ADMIN_PASSWORD Provided. Exiting ..."
    exit 1
fi

# it's important to generate the keytab *before* starting SSSD
cat << EOF

************************************************************
Updating Kerberos keytab file for ${SMB_ADMIN}
************************************************************

EOF

echo "${SMB_ADMIN_PASSWORD}" | net ads keytab add HTTP -U ${SMB_ADMIN}

cp /etc/krb5.keytab /etc/opt/omi/creds/omi.keytab
chown omi:omi /etc/opt/omi/creds/omi.keytab
# dumps the contents of the keyfile
klist -Kke


cat << EOF

************************************************************
Restarting sssd service
************************************************************

EOF

service sssd restart
service sssd status
# dump all the sssd log files
cat /var/log/sssd/*
