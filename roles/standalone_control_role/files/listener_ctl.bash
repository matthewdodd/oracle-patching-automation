#!/usr/bin/bash
## Use this script to start or stop the listener
## Usage: listener_ctl.bash <start/stop> <oracle_sid> <listener names separated by spaces>

ORACLE_SID=$2

. /local/$ORACLE_SID.env
echo ORACLE_SID is: $ORACLE_SID
echo ORACLE_HOME  : $ORACLE_HOME

if [ ! -d $ORACLE_HOME ]
then
  echo "Failed Error: ORACLE_HOME not mounted. Check ORACLE_SID and the set environment variables." 1>&2
  exit 4  
fi

case $1 in
'start')

  for i in "${@:3}"
  do
    LISTENER_NAME=`echo $i | awk '{print tolower($0)}'`

    lsnrctl status $LISTENER_NAME 1>/dev/null
    if [ $? -ne 0 ]
    then
      echo "Starting listener $LISTENER_NAME ..."
      lsnrctl start $LISTENER_NAME
      if [ $? -eq 0 ]
      then
        echo "Listener $LISTENER_NAME started successfully"
      else
        echo "Failed to start listener $LISTENER_NAME." 1>&2
        exit 4
      fi
    else
      echo "Looks like listener $LISTENER_NAME is already started."
      echo `ps -ef | grep -v grep | grep $ORACLE_HOME/bin/tnslsnr`
    fi

  done
;;

'stop')

  for i in "${@:3}"
  do
    LISTENER_NAME=`echo $i | awk '{print tolower($0)}'`

    lsnrctl status $LISTENER_NAME 1>/dev/null
    if [ $? -eq 0 ]
    then
      echo "Stopping listener $LISTENER_NAME ..."
      lsnrctl stop $LISTENER_NAME
      if [ $? -eq 0 ]
      then
        echo "Listener $LISTENER_NAME stopped successfully"
      else
        echo "Failed to stop listener $LISTENER_NAME ." 1>&2
        exit 1
      fi
    else
      echo "Looks like listener $LISTENER_NAME is already stopped."
      echo `ps -ef | grep -v grep | grep $ORACLE_HOME/bin/tnslsnr`
      exit 4
    fi
  done
;;
esac;
