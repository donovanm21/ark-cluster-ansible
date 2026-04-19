#!/bin/sh
/usr/local/bin/arkmanager checkmodupdate;
if [ $? -eq 1 ]; then
  echo "No updates available";
else
  echo "New update available";
  /bin/sh /home/ark/ark_system_update.sh
fi