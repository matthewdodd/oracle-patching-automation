#!/usr/bin/bash

ORACLE_SID=$1
. /local/$ORACLE_SID.env
oracle_database_patch_testing_dir=/tmp/ora_db_patch_$1
echo $ORACLE_SID
echo "oracle_database_patch_testing_dir is: $oracle_database_patch_testing_dir"

# grab db version
check_database_version () {
  sqlplus <<EOF
    connect / as sysdba
    SPOOL $oracle_database_patch_testing_dir/db_version_init.txt
    select version from v\$instance;
    SPOOL OFF
EOF
}

check_database_version

grep '[0-9][0-9].[0-9]' $oracle_database_patch_testing_dir/db_version_init.txt > $oracle_database_patch_testing_dir/db_version.txt

cat $oracle_database_patch_testing_dir/db_version.txt
