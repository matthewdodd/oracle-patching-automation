#!/usr/bin/bash
##usage: mount_check.bash <ORACLE_SID> <mount point list separated by spaces>
##

echo "Date_Time:" `date +"%Y.%m.%d_%I.%M%p"`

mountpoints_missing=""

function getMountPointParam () {
  echo $1 | sed 's:\[::' | sed 's:^u::' | sed 's:,::' | sed 's:\]::'
}

#Loop through the given mount point parameters and check that each is mounted
for i in "${@:2}"
do
  mountpoint=$(getMountPointParam $i)
  ### To be continued...
  if [ ! -z $mountpoint ]
  then
    #check with mount command
    mount | grep -wq $mountpoint
    if [ $? -eq 0 ]
    then
      #check again with df command
      df $mountpoint | sed 1d | awk '{print $NF}' | grep -wq $mountpoint
      if [ $? -eq 0 ]
      then
        echo checking mount point: $mountpoint ... good
      else
        echo checking mount point: $mountpoint ... ... bad
        mountpoints_missing="$mountpoints_missing $mountpoint"
      fi
    else
      echo checking mount point: $mountpoint ... ... bad
      mountpoints_missing="$mountpoints_missing $mountpoint"
    fi
  fi
done

if [ ! -z "$mountpoints_missing" ] 
then
  echo "Error: Mount points not mounted: $mountpoints_missing"
  exit 4
else
  echo "Mount points check completed successfully."
fi

