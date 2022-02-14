#!/usr/bin/bash

ora_db_patch_dir=/tmp/ora_db_patch_$1
echo "ora_db_patch_dir is: $ora_db_patch_dir"

# startup database
startup_database () { 
  sqlplus <<EOF
      connect / as sysdba
      startup;
EOF
}

# startup database in upgrade
startup_database_in_upgrade () { 
  sqlplus <<EOF
      connect / as sysdba
      startup upgrade;
      alter pluggable database all open upgrade;
EOF
}

# check db jvm components
check_db_jvm_components () { 
  sqlplus <<EOF
    connect / as sysdba
    SPOOL $ora_db_patch_dir/db_jvm_components.txt
    column COMP_NAME forma a35;
    column VERSION forma a20;
    column status forma a10;
    select COMP_NAME, VERSION, status from dba_registry where upper(COMP_NAME) like '%JAVA%';
    SPOOL OFF
EOF
}

# check for invalid objects
check_for_invalid_objects () { 
  sqlplus <<EOF
    connect / as sysdba
    SPOOL $ora_db_patch_dir/patch_invalid_objects.txt
    col object_name FORMAT A30
    col owner format a10
    set linesize 200
    /* # owner, object_type, object_name, status */
    SELECT count(*) 
    FROM   dba_objects WHERE  status = 'INVALID'
    ORDER BY object_type, object_name;
    SPOOL OFF
EOF
}

utlrp_for_invalid_objects () {
  sqlplus <<EOF
    connect / as sysdba
    SPOOL $ora_db_patch_dir/utlrp_for_invalid_objects.txt
    @?/rdbms/admin/utlrp.sql
    SPOOL OFF
EOF
}

check_datapatch_status () {
  sqlplus <<EOF
    connect / as sysdba
    SPOOL $ora_db_patch_dir/patch_status.txt
    col patch_id format 99999999
    col version format a10
    col action format a8
    col status format a12
    col action_time format a26
    col description format a55
    set linesize 200
    set pagesize 30
    select patch_id, status, install_id, action, action_time, description
    from dba_registry_sqlpatch order by action_time desc;
    SPOOL OFF
EOF
}

# shutdown database
shutdown_database () {
  sqlplus <<EOF
    connect / as sysdba
    shutdown immediate;
EOF
}

# check database state
check_database_state () {
  sqlplus <<EOF
    connect / as sysdba
    SPOOL $ora_db_patch_dir/database_state.txt
    SELECT INSTANCE_NAME, STATUS, DATABASE_STATUS FROM V\$INSTANCE;
    SPOOL OFF
EOF
}

check_opatch_status () {
  opatch_status=$($ORACLE_HOME/OPatch/opatch lsinv | tail -1)
  if [ ! -z "$opatch_status" ]
  then
    if [[ $opatch_status == *"OPatch succeeded"* ]]; then
      echo "opatch_status=$opatch_status, opatch succeeded"
    else
      echo "opatch_status=$opatch_status, opatch did not succeed"
      exit 1
    fi
  else
    echo "opatch did not succeed"
    exit 1
  fi
}

check_opatch_prereq_status_from_file () {
  opatch_status=$(tail -1 $ora_db_patch_dir/opatch_status.txt)
  if [ ! -z "$opatch_status" ]
  then
    if [[ $opatch_status == *"OPatch succeeded"* ]]; then
      echo "opatch_status=$opatch_status, opatch succeeded"
    else
      echo "opatch_status=$opatch_status, opatch did not succeed"
      exit 1
    fi
  else
    echo "opatch did not succeed"
    exit 1
  fi
}

check_opatch_status_from_file () {
  opatch_success_expression="OPatch succeeded"
  opatch_ignore_success="OPatch completed with warnings"
  # if AIX, OPatch completed with warnings, is considered successfull
  if [[ $OSTYPE == "aix"* ]]; then
    opatch_success_expression="OPatch completed with warnings"
  fi

  opatch_status=$(tail -1 $ora_db_patch_dir/opatch_status.txt)
  if [ ! -z "$opatch_status" ]
  then
    if [[ $opatch_status == *"$opatch_success_expression"* ]]; then
      echo "opatch_status=$opatch_status, opatch succeeded"
    else
      if [[ $opatch_status == *"$opatch_ignore_success"* ]]; then
        echo "opatch_status=$opatch_status, opatch succeeded"
      else
        echo "opatch_status=$opatch_status, opatch did not succeed"
        exit 1
      fi
    fi
  else
    echo "opatch did not succeed"
    exit 1
  fi
}

check_jvm_patch_status () {
  jvm_patch_id_status_line=$(grep $jvm_patch_id $ora_db_patch_dir/patch_status.txt | head -1)
  if [ ! -z "$jvm_patch_id_status_line" ]
  then
    if [[ $jvm_patch_id_status_line == *"WITH ERRORS"* ]]; then
      echo $jvm_patch_id_status_line
      echo "$jvm_patch_id in WITH ERRORS state, failed"
      return 1
    else
      echo "$jvm_patch_id successfull"
    fi
  else
    echo "$jvm_patch_id not found in database"
  fi
  return 0
}

vercomp () {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

if [[ -z "$1" ]]
then
  echo "first argument must be ORACLE_SID"
  exit 1
elif [[ -z "$2" ]]
then
  echo "second argument must be one of status, apply, or rollback"
  exit 1
elif [[ -z "$3" ]]
then
  echo "patch_folder_name parameter required, i.e. /u01/zdbcom/software_dir/19c/jan20"
  exit 1
fi

ORACLE_SID=$1
. /local/$ORACLE_SID.env

db_patch_update_string="Database * Release Update"
jvm_patch_update_string="\- Oracle JavaVM Component"

patch_folder_name=$3

patch_root_folder=$patch_folder_name
lines=$(find $patch_root_folder -type d -name '[0-9]*')
while read -r line ; do
  if [ -e $line/README.html ]; then
    grep_count=$(grep "$db_patch_update_string" $line/README.html | wc -l)
    if [[ $grep_count -gt 0 ]] ; then
      db_patch_folder=$line
    fi
    grep_count=$(grep "$jvm_patch_update_string" $line/README.html | wc -l)
    if [[ $grep_count -gt 1 ]] ; then
      jvm_patch_folder=$line
       echo jvm_patch_folder=$jvm_patch_folder
    fi
  fi
done <<< "$lines"
echo db_patch_folder=$db_patch_folder
echo jvm_patch_folder=$jvm_patch_folder

if [ ! -z "$db_patch_folder" ]
then
  db_patch_id="$(basename $db_patch_folder)"
  echo db_patch_id=$db_patch_id
  if [ -z "$db_patch_id" ]
  then
    echo "db_patch_id not found"
    exit 1
  fi
else
  echo "db_patch_folder not found"
  exit 1
fi

if [ ! -z "$jvm_patch_folder" ]
then
  jvm_patch_id="$(basename $jvm_patch_folder)"
  echo jvm_patch_id=$jvm_patch_id
  if [ -z "$jvm_patch_id" ]
  then
    echo "jvm_patch_id not found"
    exit 1
  fi
else
  echo "jvm_patch_folder not found, that's okay, not mandatory"
fi

case $2 in
'test')

  db_patch_update_string="Database * Release Update"
  jvm_patch_update_string="\- Oracle JavaVM Component Release Update"
  patch_folder_name=$3
  patch_root_folder=$patch_folder_name
  lines=$(find $patch_root_folder -type d -name '[0-9]*')
  while read -r line ; do
    if [ -e $line/README.html ]; then
      grep_count=$(grep "$db_patch_update_string" $line/README.html | wc -l)
      if [[ $grep_count -gt 0 ]] ; then
        db_patch_folder=$line
      fi
      grep_count=$(grep "$jvm_patch_update_string" $line/README.html | wc -l)
      if [[ $grep_count -gt 1 ]] ; then
        jvm_patch_folder=$line
      fi
    fi
  done <<< "$lines"
  echo db_patch_folder=$db_patch_folder
  echo jvm_patch_folder=$jvm_patch_folder

;;

'prereq')
  ################################################################################
  # perform prereq
  ################################################################################

  # Check if OPatch needs to be updated
  if [ -d "$patch_folder_name/OPatch" ]; then
    echo "Check if OPatch needs to be updated..."
    old_opatch_version=$(grep "OPATCH_VERSION" $ORACLE_HOME/OPatch/version.txt | sed -e "s/OPATCH_VERSION\://g")
    new_opatch_version=$(grep "OPATCH_VERSION" $patch_folder_name/OPatch/version.txt | sed -e "s/OPATCH_VERSION\://g")
    echo old_opatch_version=$old_opatch_version
    echo new_opatch_version=$new_opatch_version
    vercomp $old_opatch_version $new_opatch_version

    if [ $? == "2" ]; then
      echo "Update OPatch, new_opatch_version=$new_opatch_version is GREATER THAN old_opatch_version=$old_opatch_version"
      cd $ORACLE_HOME
      rm -rf $ORACLE_HOME/OPatch.old
      mv $ORACLE_HOME/OPatch $ORACLE_HOME/OPatch.old
      cp -R $patch_folder_name/OPatch .
      $ORACLE_HOME/OPatch/opatch version
    fi
  fi

  cd $db_patch_folder
  $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph . 2>&1 | tee $ora_db_patch_dir/opatch_status.txt
  check_opatch_prereq_status_from_file

  if [ ! -z "$jvm_patch_folder" ]
  then
    cd $jvm_patch_folder
    $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph . 2>&1 | tee $ora_db_patch_dir/opatch_status.txt
    check_opatch_prereq_status_from_file
  fi

;;

'utlrp')
  ################################################################################
  # perform utlrp
  ################################################################################

  utlrp_for_invalid_objects
  file_name=$ora_db_patch_dir/utlrp_for_invalid_objects.txt
  grep_count=$(grep "ORACLE not available" $file_name | wc -l)
  if [[ $grep_count -gt 0 ]] ; then
    echo "ORACLE not available, something is wrong"
    exit 1
  fi

;;

'qopiprep')
  ################################################################################
  # if AIX and 12.1 then change this file to avoid issues
  ################################################################################
  
  prep="$(head -n 1 $ORACLE_HOME/QOpatch/qopiprep.bat)"

  echo "Updating:    $ORACLE_HOME/QOpatch/qopiprep.bat"
  echo "changing 'sh' to 'ksh93'"

  chmod 0777 $ORACLE_HOME/QOpatch/qopiprep.bat

  case $prep in
    (*/bin/sh*)
      sed 's/\/bin\/sh/\/bin\/ksh93/' $ORACLE_HOME/QOpatch/qopiprep.bat > $ORACLE_BASE/tmp.$$
      mv $ORACLE_BASE/tmp.$$ $ORACLE_HOME/QOpatch/qopiprep.bat
      echo "attempted to automatically fix the issue"
  esac

  chmod 0744 $ORACLE_HOME/QOpatch/qopiprep.bat

  prep2="$(head -n 1 $ORACLE_HOME/QOpatch/qopiprep.bat)"
  echo $prep2
  echo "Was that using 'ksh93'?"

  case $prep2 in
    (*/bin/sh*)
       echo "Unsuccessful update to: $ORACLE_HOME/QOpatch/qopiprep.bat"
       echo "This will likely be a problem"
       exit 1
  esac

  echo "Yes, it was using 'ksh93'"  

  sqlplus <<EOF
    connect / as sysdba

    select dbms_sqlpatch.verify_queryable_inventory from dual;

    drop table OPATCH_XML_INV;

    CREATE TABLE opatch_xml_inv
    (
      xml_inventory CLOB
    )
    ORGANIZATION EXTERNAL
    (
      TYPE oracle_loader
      DEFAULT DIRECTORY opatch_script_dir
      ACCESS PARAMETERS
      (
      RECORDS DELIMITED BY NEWLINE CHARACTERSET UTF8
      DISABLE_DIRECTORY_LINK_CHECK
      READSIZE 8388608
      preprocessor opatch_script_dir:'qopiprep.bat'
      BADFILE opatch_script_dir:'qopatch_bad.bad'
      LOGFILE opatch_log_dir:'qopatch_log.log'
      FIELDS TERMINATED BY 'UIJSVTBOEIZBEFFQBL'
      MISSING FIELD VALUES ARE NULL
      REJECT ROWS WITH ALL NULL FIELDS
      (
      xml_inventory CHAR(100000000)
      )
      )
      LOCATION(opatch_script_dir:'qopiprep.bat')
    )
    PARALLEL 1
    REJECT LIMIT UNLIMITED;

    alter package sys.DBMS_QOPATCH compile body;

    select dbms_sqlpatch.verify_queryable_inventory from dual;
EOF

;;

'status')
  ################################################################################
  # check patch status in db
  ################################################################################
  db_patch_id_apply=false

  check_database_state
  grep_count=$(grep "OPEN" $ora_db_patch_dir/database_state.txt | wc -l)
  if [[ $grep_count -eq 0 ]] ; then
    startup_database
  fi

  check_db_jvm_components
  check_datapatch_status

  file_name=$ora_db_patch_dir/patch_status.txt
  grep_count=$(grep "ORACLE not available" $file_name | wc -l)
  if [[ $grep_count -gt 0 ]] ; then
    echo "ORACLE not available, something is wrong"
    exit 1
  fi

  # get first line that matches db_patch_id
  db_patch_id_status_line=$(grep $db_patch_id $ora_db_patch_dir/patch_status.txt | head -1)
  if [ ! -z "$db_patch_id_status_line" ]
  then
    if [[ $db_patch_id_status_line == *"APPLY"* ]]; then
      echo "$db_patch_id already applied, nothing to do..."
      # exit code 2 to reflect that rollback can occur    
      exit 2
    else
      if [[ $db_patch_id_status_line == *"WITH ERRORS"* ]]; then
        echo "$db_patch_id is WITH ERRORS, do not proceed..."
        exit 1
      else
        echo "$db_patch_id not in APPLY state, we can proceed to apply..."
        db_patch_id_apply=true
        exit 0
      fi
    fi
  else
    echo "$db_patch_id not found in database, we can proceed to apply..."
    db_patch_id_apply=true
    exit 0
  fi

;;

'apply')
  ################################################################################
  # apply opatch and patch
  ################################################################################

  check_database_state
  grep_count=$(grep "OPEN" $ora_db_patch_dir/database_state.txt | wc -l)
  if [[ $grep_count -gt 0 ]] ; then
    echo "Oracle still running, database and listeners must be shutdown"
    exit 1
  fi

  # PREPARE apply patch via OPatch
  $ORACLE_HOME/OPatch/opatch apply -silent $db_patch_folder 2>&1 | tee $ora_db_patch_dir/opatch_status.txt
  check_opatch_status_from_file

  # jvm plugin status captured in advance in "status" block above
  grep_count=$(grep "Java" $ora_db_patch_dir/db_jvm_components.txt | wc -l)
  if [[ $grep_count -gt 0 ]] ; then
    if [ ! -z "$jvm_patch_folder" ]
    then
      $ORACLE_HOME/OPatch/opatch apply -silent $jvm_patch_folder 2>&1 | tee $ora_db_patch_dir/opatch_status.txt
      check_opatch_status_from_file
    else
      echo "jvm_patch_folder empty"
      exit 1
    fi
  fi

  # be careful about moving around the order of function calls below. They depend on the db being started.
  startup_database_in_upgrade

  check_for_invalid_objects
  file_name=$ora_db_patch_dir/patch_invalid_objects.txt
  count_invalid_objects_before_upgrade=$(grep -n "COUNT(\*)" $file_name | cut -d':' -f1 |  xargs  -n1 -I % awk 'NR<=%+2 && NR>=%-0' $file_name | tail -1 | sed -e "s/ //g")

  # APPLY apply patch to DB
  $ORACLE_HOME/OPatch/datapatch -verbose 2>&1 | tee $ora_db_patch_dir/run_datapatch.txt

  # if datapatch shows known jvm errors, rerun datapatch
  check_datapatch_status
  check_jvm_patch_status
  if [ $? == "1" ]; then
    $ORACLE_HOME/OPatch/datapatch -verbose 2>&1 | tee $ora_db_patch_dir/run_datapatch.txt
    # if datapatch shows known jvm errors TWICE, fail
    check_datapatch_status
    check_jvm_patch_status
    if [ $? == "1" ]; then
      echo "jvm_patch_id=$jvm_patch_id still failed after running twice"
      exit 1
    fi
  fi

  check_for_invalid_objects
  file_name=$ora_db_patch_dir/patch_invalid_objects.txt
  count_invalid_objects_after_upgrade=$(grep -n "COUNT(\*)" $file_name | cut -d':' -f1 |  xargs  -n1 -I % awk 'NR<=%+2 && NR>=%-0' $file_name | tail -1 | sed -e "s/ //g")

  # run utlrp.sql if "$count_invalid_objects_before_upgrade" < "$count_invalid_objects_after_upgrade"
  retry_count=0
  while [ $retry_count -lt 2 ]
  do
    if [ "$count_invalid_objects_before_upgrade" -lt "$count_invalid_objects_after_upgrade" ]
    then
        echo "count_invalid_objects_before_upgrade=$count_invalid_objects_before_upgrade < count_invalid_objects_after_upgrade=$count_invalid_objects_after_upgrade, invalid objects introduced, running utlrp.sql"
        retry_count=$(( $retry_count + 1 ))
        utlrp_for_invalid_objects
        check_for_invalid_objects
        file_name=$ora_db_patch_dir/patch_invalid_objects.txt
        count_invalid_objects_after_upgrade=$(grep -n "COUNT(\*)" $file_name | cut -d':' -f1 |  xargs  -n1 -I % awk 'NR<=%+2 && NR>=%-0' $file_name | tail -1 | sed -e "s/ //g")
    else
      break
    fi
  done

  check_datapatch_status

  shutdown_database

  if [ "$count_invalid_objects_before_upgrade" -lt "$count_invalid_objects_after_upgrade" ]
  then
      echo "count_invalid_objects_before_upgrade=$count_invalid_objects_before_upgrade < count_invalid_objects_after_upgrade=$count_invalid_objects_after_upgrade, invalid objects introduced, not resolved, upgrade failed"
  fi

  # get first line that matches db_patch_id
  db_patch_id_status_line=$(grep $db_patch_id $ora_db_patch_dir/patch_status.txt | head -1)
  if [ ! -z "$db_patch_id_status_line" ]
  then
    if [[ $db_patch_id_status_line == *"APPLY"* ]]; then
      echo "$db_patch_id successfully applied"
    else
      echo $db_patch_id_status_line
      echo "$db_patch_id not not in APPLY state, upgrade failed"
      exit 1
    fi
  else
    echo "$db_patch_id not found in database, upgrade failed"
    exit 1
  fi
;;

esac;
