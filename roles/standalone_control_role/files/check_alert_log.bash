#!/usr/bin/bash

##This script checks the alert log for error/warning keywords
##Usage: check_alert_log.bash <ORACLE_SID> 

ORACLE_SID=$1

. /local/$ORACLE_SID.env
echo -e ORACLE_SID is: $ORACLE_SID
echo -e ORACLE_HOME  : $ORACLE_HOME

if [ ! -d $ORACLE_BASE ]
then
  echo "Error: log directories not mounted: $ORACLE_BASE"
  exit 1
fi

alertLog="$ORACLE_BASE/diag/rdbms/$ORACLE_SID/$ORACLE_SID/trace/alert_$ORACLE_SID.log"

if [ ! -f $alertLog ]
then
  alertLog=`find $ORACLE_BASE -type f -name "alert_$ORACLE_SID.log" 2>/dev/null`
fi

if [ ${#alertLog} -eq 0 ]
then
  echo "Error: alertLog_$ORACLE_SID not found"
else
  ##To Check Alert Log for Errors and Warnings.
  ##keywords to check: Error ORA- Warning

  echo -e "\n"
  echo "Checking alert log: $alertLog"

  logErrors=`egrep 'Error|ORA-|Warning' $alertLog | uniq`

  if [ ${#logErrors} -gt 0 ]
  then
    echo "The following Errors/Warnings found in alert log:"
    egrep 'Error|ORA-|Warning' $alertLog | uniq
  else
    echo "Alert log looks clean!"
  fi
fi
