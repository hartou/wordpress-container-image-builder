#!/bin/bash

#import database

setup_cdn_variables() {
    IS_CDN_ENABLED="False"
    if [[ $CDN_ENABLED ]] && [[ "$CDN_ENABLED" == "true" || "$CDN_ENABLED" == "TRUE" || "$CDN_ENABLED" == "True" ]] && [[ $CDN_ENDPOINT ]]; then
    	IS_CDN_ENABLED="True"
    fi
    
    IS_AFD_ENABLED="False"
    if [[ $AFD_ENABLED ]] && [[ "$AFD_ENABLED" == "true" || "$AFD_ENABLED" == "TRUE" || "$AFD_ENABLED" == "True" ]] && [[ $AFD_ENDPOINT ]]; then
    	IS_AFD_ENABLED="True"
    fi
    
    IS_BLOB_STORAGE_ENABLED="False"
    if [[ $BLOB_STORAGE_ENABLED ]] && [[ "$BLOB_STORAGE_ENABLED" == "true" || "$BLOB_STORAGE_ENABLED" == "TRUE" || "$BLOB_STORAGE_ENABLED" == "True" ]] \
    && [[ $STORAGE_ACCOUNT_NAME ]] && [[ $STORAGE_ACCOUNT_KEY ]] && [[ $BLOB_CONTAINER_NAME ]]; then
	IS_BLOB_STORAGE_ENABLED="True"
    fi

}

MIGRATION_STATUSFILE_PATH="/home/dev/migrate/import_status.txt"
trycount=$1
error="False"

test ! -d /home/dev/migrate/ && mkdir -p /home/dev/migrate/
test ! -e $MIGRATION_STATUSFILE_PATH && touch $MIGRATION_STATUSFILE_PATH

if (( $trycount > 0 )); then
	if [[ $MIGRATION_IN_PROGRESS ]] && [[ "$MIGRATION_IN_PROGRESS" == "true" || "$MIGRATION_IN_PROGRESS" == "TRUE" || "$MIGRATION_IN_PROGRESS" == "True" ]]  \
	&& [[ $MIGRATE_NEW_DATABASE_NAME ]] && [[ $MIGRATE_MYSQL_DUMP_PATH ]] \
	&& [ ! $(grep "MYSQL_DB_IMPORT_COMPLETED" $MIGRATION_STATUSFILE_PATH) ]; then
		if apk add mysql-client --no-cache \
		&& mysql -h $DATABASE_HOST -u $DATABASE_USERNAME --password=$DATABASE_PASSWORD -e "DROP DATABASE IF EXISTS $MIGRATE_NEW_DATABASE_NAME; CREATE DATABASE $MIGRATE_NEW_DATABASE_NAME;" --ssl=true \
		&& mysql -h $DATABASE_HOST -u $DATABASE_USERNAME --password=$DATABASE_PASSWORD $MIGRATE_NEW_DATABASE_NAME < $MIGRATE_MYSQL_DUMP_PATH  --ssl=true; then
			test ! -e $MIGRATION_STATUSFILE_PATH && mkdir -p $MYSQL_IMPORT_STATUSFILE_DIR && touch $MIGRATION_STATUSFILE_PATH
			echo "MYSQL_DB_IMPORT_COMPLETED" >> $MIGRATION_STATUSFILE_PATH
		else
			echo "MYSQL_DB_IMPORT_FAIL_E" >> $MIGRATION_STATUSFILE_PATH
			error="True"
		fi
	fi
	
	
	if [ ! $(grep "W3TC_PLUGIN_INSTALLED" $MIGRATION_STATUSFILE_PATH) ]; then
		if wp plugin install w3-total-cache --force --activate --path=$WORDPRESS_HOME --allow-root; then
			echo "W3TC_PLUGIN_INSTALLED" >> $MIGRATION_STATUSFILE_PATH
			if [ ! $(grep "W3TC_PLUGIN_INSTALLED" $WORDPRESS_LOCK_FILE) ]; then
				echo "W3TC_PLUGIN_INSTALLED" >> $WORDPRESS_LOCK_FILE
			fi
		else
			error="True"
		fi
        fi
        
        if [ $(grep "W3TC_PLUGIN_INSTALLED" $MIGRATION_STATUSFILE_PATH) ] && [ ! $(grep "W3TC_PLUGIN_CONFIG_UPDATED" $MIGRATION_STATUSFILE_PATH) ]; then
		if mkdir -p $WORDPRESS_HOME/wp-content/cache/tmp \
		&& mkdir -p $WORDPRESS_HOME/wp-content/w3tc-config \
		&& wp w3-total-cache import $WORDPRESS_SOURCE/w3tc-config.json --path=$WORDPRESS_HOME --allow-root; then
			echo "W3TC_PLUGIN_CONFIG_UPDATED" >> $MIGRATION_STATUSFILE_PATH
			if [ ! $(grep "W3TC_PLUGIN_CONFIG_UPDATED" $WORDPRESS_LOCK_FILE) ]; then
				echo "W3TC_PLUGIN_CONFIG_UPDATED" >> $WORDPRESS_LOCK_FILE
			fi
		else
			error="True"
		fi
	fi
    
	setup_cdn_variables
    
	if [ $(grep "W3TC_PLUGIN_CONFIG_UPDATED" $MIGRATION_STATUSFILE_PATH) ] && [ ! $(grep "BLOB_STORAGE_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ] \
	&& [ ! $(grep "FIRST_TIME_SETUP_COMPLETED" $MIGRATION_STATUSFILE_PATH) ] && [[ "$IS_BLOB_STORAGE_ENABLED" == "True" ]]; then

		if ! [[ $BLOB_STORAGE_URL ]]; then
			BLOB_STORAGE_URL="${STORAGE_ACCOUNT_NAME}.blob.core.windows.net"
		fi

		if wp w3-total-cache import $WORDPRESS_SOURCE/w3tc-blob-config.json --path=$WORDPRESS_HOME --allow-root \
		&& wp w3-total-cache option set cdn.azure.user $STORAGE_ACCOUNT_NAME --path=$WORDPRESS_HOME --allow-root \
		&& wp w3-total-cache option set cdn.azure.container $BLOB_CONTAINER_NAME --path=$WORDPRESS_HOME --allow-root \
		&& wp w3-total-cache option set cdn.azure.key $STORAGE_ACCOUNT_KEY --path=$WORDPRESS_HOME --allow-root \
		&& wp w3-total-cache option set cdn.enabled true --type=boolean --path=$WORDPRESS_HOME --allow-root \
		&& wp w3-total-cache option set cdn.azure.cname $BLOB_STORAGE_URL --type=array --path=$WORDPRESS_HOME --allow-root \
		&& wp plugin deactivate w3-total-cache --quiet --path=$WORDPRESS_HOME --allow-root \
		&& wp plugin activate w3-total-cache --path=$WORDPRESS_HOME --allow-root; then
			echo "BLOB_STORAGE_CONFIGURATION_COMPLETE" >> $MIGRATION_STATUSFILE_PATH
			if [ ! $(grep "BLOB_STORAGE_CONFIGURATION_COMPLETE" $WORDPRESS_LOCK_FILE) ]; then
				echo "BLOB_STORAGE_CONFIGURATION_COMPLETE" >> $WORDPRESS_LOCK_FILE
			fi
		else
			error="True"
		fi
	fi
    
	if [ $(grep "W3TC_PLUGIN_CONFIG_UPDATED" $MIGRATION_STATUSFILE_PATH) ] && [ "$IS_CDN_ENABLED" == "True" ] \
	&& [ ! $(grep "BLOB_CDN_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ] && [ ! $(grep "CDN_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ]; then
		if [ "$IS_BLOB_STORAGE_ENABLED" == "True" ] && [ $(grep "BLOB_STORAGE_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ] \
		&& [ ! $(grep "BLOB_CDN_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ]; then
			if wp w3-total-cache option set cdn.azure.cname $CDN_ENDPOINT --type=array --path=$WORDPRESS_HOME --allow-root \
			&& wp w3-total-cache option set cdn.includes.enable true --type=boolean --path=$WORDPRESS_HOME --allow-root \
			&& wp w3-total-cache option set cdn.theme.enable true --type=boolean --path=$WORDPRESS_HOME --allow-root \
			&& wp w3-total-cache option set cdn.custom.enable true --type=boolean --path=$WORDPRESS_HOME --allow-root; then
				echo "BLOB_CDN_CONFIGURATION_COMPLETE" >> $MIGRATION_STATUSFILE_PATH
				if [ ! $(grep "BLOB_CDN_CONFIGURATION_COMPLETE" $WORDPRESS_LOCK_FILE) ]; then
					echo "BLOB_CDN_CONFIGURATION_COMPLETE" >> $WORDPRESS_LOCK_FILE
				fi
			else
				error="True"
			fi
		elif [ "$IS_BLOB_STORAGE_ENABLED" != "True" ] && [ ! $(grep "CDN_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ]; then
			if wp w3-total-cache option set cdn.enabled true --type=boolean --path=$WORDPRESS_HOME --allow-root \
			&& wp w3-total-cache option set cdn.engine "mirror" --path=$WORDPRESS_HOME --allow-root \
			&& wp w3-total-cache option set cdn.mirror.domain $CDN_ENDPOINT --type=array --path=$WORDPRESS_HOME --allow-root; then
				echo "CDN_CONFIGURATION_COMPLETE" >> $MIGRATION_STATUSFILE_PATH
				if [ ! $(grep "CDN_CONFIGURATION_COMPLETE" $WORDPRESS_LOCK_FILE) ]; then
					echo "CDN_CONFIGURATION_COMPLETE" >> $WORDPRESS_LOCK_FILE
				fi
				
			else
				error="True"
			fi
		fi
	fi
    
	if [ $(grep "W3TC_PLUGIN_CONFIG_UPDATED" $MIGRATION_STATUSFILE_PATH) ] && [ "$IS_AFD_ENABLED" == "True" ] \
	&& [ ! $(grep "BLOB_AFD_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ] && [ ! $(grep "AFD_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ]; then
		afd_url="\$http_protocol . \$_SERVER['HTTP_HOST']"
		if [[ $AFD_ENABLED ]]; then
			if [[ $AFD_CUSTOM_DOMAIN ]]; then
				afd_url="\$http_protocol . '$AFD_CUSTOM_DOMAIN'"
			elif [[ $AFD_ENDPOINT ]]; then
				afd_url="\$http_protocol . '$AFD_ENDPOINT'"
			fi
		fi

		if wp config set WP_HOME "$afd_url" --raw --allow-root --path=/home/site/wwwroot \
		&& wp config set WP_SITEURL "$afd_url" --raw --path=$WORDPRESS_HOME --allow-root; then
			if [ "$IS_BLOB_STORAGE_ENABLED" == "True" ] && [ $(grep "BLOB_STORAGE_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ] \
			&& [ ! $(grep "BLOB_AFD_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ] \
			&& wp w3-total-cache option set cdn.azure.cname $AFD_ENDPOINT --type=array --path=$WORDPRESS_HOME --allow-root; then
				echo "BLOB_AFD_CONFIGURATION_COMPLETE" >> $MIGRATION_STATUSFILE_PATH
				if [ ! $(grep "BLOB_AFD_CONFIGURATION_COMPLETE" $WORDPRESS_LOCK_FILE) ]; then
					echo "BLOB_AFD_CONFIGURATION_COMPLETE" >> $WORDPRESS_LOCK_FILE
				fi
			elif [ "$IS_BLOB_STORAGE_ENABLED" != "True" ] && [ ! $(grep "AFD_CONFIGURATION_COMPLETE" $MIGRATION_STATUSFILE_PATH) ]; then
				echo "AFD_CONFIGURATION_COMPLETE" >> $MIGRATION_STATUSFILE_PATH
				if [ ! $(grep "AFD_CONFIGURATION_COMPLETE" $WORDPRESS_LOCK_FILE) ]; then
					echo "AFD_CONFIGURATION_COMPLETE" >> $WORDPRESS_LOCK_FILE
				fi
			else
				error="True"
			fi
		else
			error="True"
		fi
	fi
	
	if [[ "$error" == "True" ]]; then
		service atd start
		nextcount=$(($trycount-1))
		echo "bash /usr/local/bin/migrate.sh $nextcount" | at now +0 minutes
	else
		echo "IMPORT_POST_PROCESSING_COMPLETED" >> $MIGRATION_STATUSFILE_PATH
	fi
else
	echo "IMPORT_POST_PROCESSING_FAILED" >> $MIGRATION_STATUSFILE_PATH
fi
