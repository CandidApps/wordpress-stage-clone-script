#!/bin/bash -ex

# wordpress-stage-clone-script v1 by Christian Bolstad - christian@hippies.se  
# Creates a local clone of a remote wordpress installation, with search & replace of hostnames in the database

# TODO: 
#   * check if wp-config.php was parsed correctly (duplicate commented setup lines etc, DOMAIN_CURRENT site exists etc) 
#   * modify the stored procedure to skip wpmu-tables if they dont exist
#   * check if it's possible to connect to the remote server
#   * verify that rsync is installed on the remote server
#   * verify that the local database exist and is connectable
#   * verify that the remote database exist and is connectable
						
if [$1 == ''] ; then				 
   echo "Error: no config file passed as parameter, syntax: $0 myhostname.stageconf "
   exit 0
fi

source $1 

if [ ! -f $1 ] ; then
  echo "Error: my config does not exist: $1"
  exit 0
fi

if [ ! -d ${STAGING_ADDR} ] ; then
  echo "Error: directory ${STAGING_ADDR} does not exist."
  exit 0
fi

# rsync remote files to our local dir 
echo "* Syncing filesystem to ${STAGING_ADDR}/"
/usr/bin/rsync -e ssh --delete -avz --stats --progress ${PRODUCTION_SERVER}:${PRODUCTION_DIR} ${STAGING_ADDR}/

# parse wp-config to the the constants needed 
echo "* Fetching data from ${STAGING_ADDR}/wp-config.php"
WPCONFIG="${STAGING_ADDR}/wp-config.php" 
DATABASE_NAME=`cat ${WPCONFIG} | grep DB_NAME | cut -d \' -f 4`
STAGING_DB_USER=`cat $WPCONFIG | grep DB_USER | cut -d \' -f 4`
STAGING_DB_PWD=`cat $WPCONFIG | grep DB_PASSWORD | cut -d \' -f 4`
TBL_PREFIX=`cat $WPCONFIG | grep table_prefix | cut -d \' -f 2`
PRODUCTION_ADDR=`cat $WPCONFIG | grep DOMAIN_CURRENT_SITE | cut -d \' -f 4`

echo "* Got this data - make sure it's correct:"
echo Database 
echo ' \t ' user: ${STAGING_DB_USER}
echo ' \t ' password ${STAGING_DB_PWD}
echo ' \t ' database: ${DATABASE_NAME} 
echo ' \t ' tbl prefix: ${TBL_PREFIX}
echo Siteinfo
echo ' \t ' production hostname: ${PRODUCTION_ADDR}
echo ' \t ' stage hostname: ${STAGING_ADDR}


echo "* Updating ${WPCONFIG} with new hostname"

# replace the hostname in the our local wp-config.php
sed -i  -e s/${PRODUCTION_ADDR}/${STAGING_ADDR}/g ${WPCONFIG}
                
echo "! Will now sleep in 5 sec before starting migrating"

sleep 5

# do a dump from the remote database 
echo "* Dumping remote database"
ssh ${PRODUCTION_SERVER} "mysqldump -u ${STAGING_DB_USER} -p${STAGING_DB_PWD} --single-transaction ${DATABASE_NAME} " > dump.sql

# setting up local copy of database
mysql -u ${STAGING_DB_USER} -p${STAGING_DB_PWD} ${DATABASE_NAME} < dump.sql

echo "* Migrating database"

# update the database tables in the local database
# mysql store procedure by Niklas Lönn http://blog.wp.weightpoint.se/2012/01/04/synchronizing-wordpress-multisite-database-from-production-to-staging-enviorment/ 

mysql  --user=${STAGING_DB_USER} --password=${STAGING_DB_PWD} ${DATABASE_NAME} << EOF
delimiter //
DROP PROCEDURE IF EXISTS update_wp_procedure;
CREATE PROCEDURE update_wp_procedure()
BEGIN
        DECLARE done INT DEFAULT 0;
        DECLARE tblName TEXT;
        DECLARE tblCursor CURSOR FOR SELECT table_name FROM information_schema.TABLES where table_schema = '${DATABASE_NAME}' and ( table_name LIKE '${TBL_PREFIX}%_options' OR table_name = '${TBL_PREFIX}options');
        DECLARE tblCursor2 CURSOR FOR SELECT table_name FROM information_schema.TABLES where table_schema = '${DATABASE_NAME}' and ( table_name LIKE '${TBL_PREFIX}%_posts' OR table_name = '${TBL_PREFIX}posts');
        DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

        OPEN tblCursor;
        read_loop: LOOP
                FETCH tblCursor INTO tblName;
                IF done THEN
                        LEAVE read_loop;
                END IF;
                SET @cmd = CONCAT('update ',tblName,' set option_value = replace(option_value,''${PRODUCTION_ADDR}'',''${STAGING_ADDR}'') where option_name IN (''siteurl'', ''home'');');
                PREPARE stmt FROM @cmd;
                EXECUTE stmt;
                DROP PREPARE stmt;
        END LOOP;
        CLOSE tblCursor;

        OPEN tblCursor2;
        SET done = 0;
        read_loop2: LOOP
                FETCH tblCursor2 INTO tblName;
                IF done THEN
                        LEAVE read_loop2;
                END IF;

                SET @cmd = CONCAT('update ', tblName, ' set post_content = replace(post_content,''${PRODUCTION_ADDR}'',''${STAGING_ADDR}'');');
                PREPARE stmt FROM @cmd;
                EXECUTE stmt;
                DROP PREPARE stmt;
        END LOOP;
        CLOSE tblCursor2;
END//

delimiter ;

CALL update_wp_procedure();
DROP PROCEDURE update_wp_procedure;


update ${TBL_PREFIX}blogs set domain = replace(domain,'${PRODUCTION_ADDR}','${STAGING_ADDR}');
update ${TBL_PREFIX}site set domain = '${STAGING_ADDR}' where domain = '${PRODUCTION_ADDR}';

EOF

# remove temporary file 
rm dump.sql

echo "* Yay! All done."
