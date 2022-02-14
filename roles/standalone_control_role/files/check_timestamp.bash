#!/usr/bin/bash
##usage: timestamp_check.bash <ORACLE_SID> <mount point list seprated by spaces>

echo Script Begin Date_Time: `date +"%Y.%m.%d_%I.%M.%S%p"`

#Check that timestamps must be more recent than the number of minutes specified here (1440 = 1 day)
minutesAgo=1440
fileFound=""
failFlag=0


function getMountPointParam () {
  echo $1 | sed 's:\[::' | sed 's:^u::' | sed 's:,::' | sed 's:\]::'
}

echo -e "Checks timestamp of the most recently updated file in each mount point:\n(Timestamp must not be older than $minutesAgo minutes ago)\n"

#Looping through each mount point and check timestamp of the most recent updated file.
for i in "${@:2}"
do
  mountpoint=$(getMountPointParam $i)
  ##If mount point is not empty or not a zdbgrd pount point (ending with z)
  if [ ! -z $mountpoint ] && [ ! `echo -n $mountpoint | tail -c 1` = "z" ]
  then
    fileFound=`find $mountpoint -name "*.*" -type f -mmin -$minutesAgo -exec ls -lt "{}" + 2>/dev/null | head -1`
    if [ ${#fileFound} -eq 0 ]
    then
      failFlag=1
      echo -e "Error ${mountpoint}: No file found or timestamp in files are older than $minutesAgo minutes ago:"
      echo -e "Fail: `find $mountpoint -name "*.*" -type f -exec ls -lt "{}" + 2>/dev/null | head -1` \n"
    fi
  fi
done

if [ $failFlag -eq 1 ]
then
  echo Script End Date_Time: `date +"%Y.%m.%d_%I.%M.%S%p"`
  exit 4
fi

echo Script End Date_Time: `date +"%Y.%m.%d_%I.%M.%S%p"`
