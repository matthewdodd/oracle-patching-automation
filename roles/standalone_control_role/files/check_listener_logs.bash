#!/bin/bash
##Usage: check_listenerlogs.bash <oracle_sid> <listener names separated by spaces>
##

ORACLE_SID=`echo $1 | awk '{print tolower($0)}'`

. /local/$ORACLE_SID.env
echo ORACLE_SID is: $ORACLE_SID
echo ORACLE_HOME  : $ORACLE_HOME

if [ ! -d $ORACLE_BASE/diag/tnslsnr/ ]
then
  echo "Error: log directories not mounted: $ORACLE_BASE/diag/tnslsnr/"
  exit 4
fi

#set failFlag for listener log files
failFlag=0

for i in "${@:2}"
  do
    listenerName=`echo $i | awk '{print tolower($0)}'`
    listenerLog=""
    failFlag=0

    if [ ! -z $listenerName ]
    then

      if [ -f $ORACLE_BASE/diag/tnslsnr/`uname -n`/$listenerName/trace/$listenerName.log ]
      then
        listenerLog="$ORACLE_BASE/diag/tnslsnr/`uname -n`/$listenerName/trace/$listenerName.log"
      else
        listenerLog=$(find $ORACLE_BASE -type f -name $listenerName.log 2>/dev/null | grep `uname -n`)
      fi

      if [ ! -z $listenerLog ]
      then
        echo
        echo "Checking log: $listenerLog"
        logErrors=`egrep 'Error|ORA-' $listenerLog`

        if [ ${#logErrors} -gt 0 ]
        then
          egrep 'Error|ORA-' $listenerLog | uniq
          failFlag=1
          #echo Found errors or warnings
        else
          echo This listener log is clean!
        fi

      else
        echo
        echo "Error: listener log for $listenerName not found"
        failFlag=1
      fi
    fi
done


if [ $failFlag -eq 1 ]
then
  exit 4
fi


