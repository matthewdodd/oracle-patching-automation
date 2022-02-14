#!/usr/bin/bash
##
#Usage: database_ctl <start/stop> <oracle_sid> [<pdbnames>]
##

ORACLE_SID=$2
PDB_NAMES=$3

. /local/$ORACLE_SID.env
echo ORACLE_SID is: $ORACLE_SID
echo ORACLE_HOME  : $ORACLE_HOME

if [ ! -d $ORACLE_HOME ]
then
  echo "Failed Error: ORACLE_HOME not mounted. Check ORACLE_SID and the set environment variables"
  exit 4
fi

case $1 in
'start')
  if [ "$(ps -ef | grep -v grep | grep -v patrol | grep ora_smon_$ORACLE_SID | wc -l)" -eq 0 ]
  then
    echo "Starting database $ORACLE_SID ..."
    echo "startup" | sqlplus / as sysdba
    if [ "$(ps -ef | grep -v grep | grep -v patrol | grep ora_smon_$ORACLE_SID | wc -l)" -gt 0 ] 
    then
      echo "Database $ORACLE_SID started successfully";
    else
      echo "Failed to start database $ORACLE_SID." 1>&2
      exit 4
    fi
  else
    echo "Looks like database $ORACLE_SID is already started."
    echo `ps -ef | grep -v grep | grep -v patrol | grep ora_smon_$ORACLE_SID`
  fi

  ##Check if database is multitenant
  echo "select cdb from v\$database;" | sqlplus / as sysdba | grep -q "YES"
  if [ $? -eq 0 ]
  then

    #If there exist PDBs that are not opened, open all PDBs
    echo "select name, open_mode from v\$pdbs where name not like 'PDB%SEED' and open_mode != 'READ WRITE';" | sqlplus / as sysdba | grep -q "NAME"

    if [ $? -eq 0 ]
    then
      echo "alter pluggable database all open;" | sqlplus / as sysdba

      echo "select name, open_mode from v\$pdbs where name not like 'PDB%SEED' and open_mode != 'READ WRITE';" | sqlplus / as sysdba | grep -q "NAME"
      if [ $? -eq 0 ]
      then
        echo "Error: Failed to open PDBs in READ WRITE mode"
        exit 4
      fi

    fi
  fi


;;

'stop')
  if [ "$(ps -ef | grep -v grep | grep -v patrol | grep ora_smon_$ORACLE_SID | wc -l)" -gt 0 ]
  then
    echo "Stopping database $ORACLE_SID ..."
    echo "shutdown immediate" | sqlplus / as sysdba

    if [ "$(ps -ef | grep -v grep | grep -v patrol | grep ora_smon_$ORACLE_SID | wc -l)" -eq 0 ] 
    then
      echo "Database $ORACLE_SID stopped successfully"
    else
      echo "Failed to stop database $ORACLE_SID." 1>&2
      exit 1
    fi
  else
    echo "Looks like database $ORACLE_SID is already stopped."
    echo `ps -ef | grep -v grep | grep -v patrol | grep ora_smon_$ORACLE_SID`
  fi
;;
esac;
