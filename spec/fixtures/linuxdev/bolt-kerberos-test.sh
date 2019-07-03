#!/bin/bash
set -e

cd ~/bolt

bundle exec bolt command run "whoami" --nodes winrm://omiserver.bolt.test:5985 --user bolt --password bolt --no-ssl
bundle exec bolt command run "whoami" --nodes winrm://omiserver.bolt.test:5986 --user bolt --password bolt --no-ssl-verify


# TODO: looks like the bugs are around
# httpauth.c line 2145
# https://github.com/microsoft/omi/blob/049c361978731425549f35067ab25b0b14febd01/Unix/http/httpauth.c#L2145
# httpauth.c line 894
# https://github.com/microsoft/omi/blob/049c361978731425549f35067ab25b0b14febd01/Unix/http/httpauth.c#L894
bundle exec bolt command run "whoami" --nodes winrm://omiserver.bolt.test:5985 --realm BOLT.TEST --no-ssl --debug --verbose --connect-timeout 9999
bundle exec bolt command run "whoami" --nodes winrm://omiserver.bolt.test:5986 --realm BOLT.TEST --no-ssl-verify --debug --verbose --connect-timeout 9999


# can do this in pwsh
# Invoke-Command -ComputerName omiserver -Command { whoami } -Authentication Kerberos -Credential (New-Object System.Management.Automation.PSCredential("${ENV:SMB_ADMIN}@${ENV:KRB5_REALM}", (ConvertTo-SecureString $ENV:SMB_ADMIN_PASSWORD -AsPlainText -Force)))
