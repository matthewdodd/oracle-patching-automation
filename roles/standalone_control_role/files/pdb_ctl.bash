#!/usr/bin/bash
##
#Usage: pdb_ctl <start/stop> <oracle_sid> <pdb name>
##

ORACLE_SID=$2
PDB_NAME=$3
. /local/$ORACLE_SID.env
echo ORACLE_SID is: $ORACLE_SID
echo ORACLE_HOME  : $ORACLE_HOME

if [ ! -d $ORACLE_HOME ]
then
  echo "Failed Error: ORACLE_HOME not mounted. Check ORACLE_SID and the set environment variables"
  exit 1
fi

case $1 in
'start')
  ##Starting the Oracle CDB if it's not already started
  if [ "$(ps -ef | grep -v grep | grep -v patrol | grep ora_smon_$ORACLE_SID | wc -l)" -eq 0 ]
  then
    echo "Starting database $ORACLE_SID ..."
    echo "startup" | sqlplus / as sysdba
    if [ "$(ps -ef | grep -v grep | grep -v patrol | grep ora_smon_$ORACLE_SID | wc -l)" -gt 0 ] 
    then
      echo "Database $ORACLE_SID started successfully"
      echo "Starting PDB..."
      echo "alter pluggable database ${PDB_NAME} open;" | sqlplus / as sysdba
    else
      echo "Failed to start database $ORACLE_SID." 1>&2
      exit 1
    fi
  else
  ##Starting the PDB
    echo "alter pluggable database ${PDB_NAME} open;" | sqlplus / as sysdba

    if [[ ${PDB_NAME} = 'all' || ${PDB_NAME} = 'ALL' || -z ${PDB_NAME} ]]
    then
      echo "select name, open_mode from v\$pdbs where name not like 'PDB%SEED' and open_mode != 'READ WRITE';" | sqlplus / as sysdba | grep -q "NAME"
      if [ $? -eq 0 ]
      then
        echo "Error: Failed to open all PDBs"
        exit 1
      fi
    else
      echo "select name, open_mode from v\$pdbs where name = upper('${PDB_NAME}') and open_mode != 'READ WRITE';" | sqlplus / as sysdba | grep -q "NAME"
      if [ $? -eq 0 ]
      then
        echo "Error: Failed to open PDB ${PDBNAME}"
        exit 1
      fi
    fi


  fi
;;

'stop')
  if [ "$(ps -ef | grep -v grep | grep -v patrol | grep ora_smon_$ORACLE_SID | wc -l)" -gt 0 ]
  then
    echo "Closing PDB ${PDB_NAME} ..."
    echo "alter pluggable database ${PDB_NAME} close;" | sqlplus / as sysdba
    
    #checking if PDB(s) still opened
    if [[ ${PDB_NAME} = 'all' || ${PDB_NAME} = 'ALL' || -z ${PDB_NAME} ]]
    then
      echo "select name, open_mode from v\$pdbs where name not like 'PDB%SEED' and open_mode != 'MOUNTED';" | sqlplus / as sysdba | grep -q "no rows selected"
      if [ $? -eq 1 ]
      then
        echo "Error: Failed to close all PDBs"
        exit 1
      fi
    else
      echo "select name, open_mode from v\$pdbs where name = upper('${PDB_NAME}') and open_mode != 'MOUNTED';" | sqlplus / as sysdba | grep -q "no rows selected"
      if [ $? -eq 1 ]
      then
        echo "Error: Failed to close PDB ${PDBNAME}"
        exit 1
      fi
    fi

    echo "PDB closed"

  else
    echo "Looks like database container $ORACLE_SID and PDB is already stopped."
  fi
;;
esac;
