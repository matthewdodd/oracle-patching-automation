#!/bin/bash

ORACLE_SID=`echo $1 | awk '{print tolower($0)}'`

#Rename logs older than 1 minute old (i.e. A fresh log everytime task is rerun)
now=`date +"%Y.%m.%d_%I.%M%p"`

. /local/$ORACLE_SID.env
echo ORACLE_SID is: $ORACLE_SID
echo ORACLE_HOME  : $ORACLE_HOME
echo

if [ ! -d $ORACLE_BASE/diag/tnslsnr/ ]
then
  echo "Error: log directories not mounted: $ORACLE_BASE/diag/tnslsnr/"
  exit 4
fi

alertLog="$ORACLE_BASE/diag/rdbms/$ORACLE_SID/$ORACLE_SID/trace/alert_$ORACLE_SID.log"

#if alert log is not found where it is expected, then search for it
if [ ! -f $alertLog ]
then
  alertLog=`find $ORACLE_BASE -type f -name "alert_$ORACLE_SID.log" 2>/dev/null`
fi

failFlag=0

#If alert log exist, rename alert log (and listener logs)
if [ ${#alertLog} -gt 0 ]
then
  echo "alert log        : $alertLog"
  #Make a copy of alert log before reseting it to empty (same as rename log)
  cp $alertLog $alertLog.$now
  echo > $alertLog
  echo "alert log renamed: $alertLog.$now"
  echo

else
  echo "Alert log for $ORACLE_SID not found"
  failFlag=1
fi

if [ $failFlag -eq 1 ]
then
  exit 4
fi
