#!/bin/sh
/usr/local/bin/arkmanager checkupdate;
if [ $? -eq 0 ]; then
  echo "No updates available";
else
  echo "New update available";
  /bin/sh /home/ark/ark_system_update.sh
fi