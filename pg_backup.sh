#!/bin/bash
while true; do
	# Start a background timer BEFORE the payload runs.
    sleep 60 &
	###########################
	####### LOAD CONFIG #######
	###########################
	while [ $# -gt 0 ]; do
		case $1 in
		-c)
			if [ -r "$2" ]; then
				source "$2"
				shift 2
			else
				${ECHO} "Unreadable config file \"$2\"" 1>&2
				exit 1
			fi
			;;
		*)
			${ECHO} "Unknown Option \"$1\"" 1>&2
			exit 2
			;;
		esac
	done

	if [ $# = 0 ]; then
		SCRIPTPATH=$(cd ${0%/*} && pwd -P)
		source $SCRIPTPATH/pg_backup.config
	fi

	###########################
	### INITIALISE DEFAULTS ###
	###########################

	if [ ! $HOSTNAME ]; then
		HOSTNAME="localhost"
	fi

	if [ ! $USERNAME ]; then
		USERNAME="postgres"
	fi

	if [ ! $PORT ]; then
		PORT="5432"
	fi

	if [ ! $PASSWORD ]; then
		PASSWORD=""
	fi

	if [ ! $BACKUP_DIR ]; then
		BACKUP_DIR="./postgres_backup/"
	fi

	if [ ! $BACKUP_TIME ]; then
		BACKUP_TIME=$(date +%H:%M)
	fi

	currenttime=$(date +%H:%M)

	if [[ "$currenttime" == "$BACKUP_TIME" ]]; then
		###########################
		#### PRE-BACKUP CHECKS ####
		###########################

		# Make sure we're running as the required backup user
		if [ "$BACKUP_USER" != "" -a "$(id -un)" != "$BACKUP_USER" ]; then
			echo "This script must be run as $BACKUP_USER. Exiting." 1>&2
			exit 1
		fi

		###########################
		#### START THE BACKUPS ####
		###########################

		# FINAL_BACKUP_DIR=$BACKUP_DIR"`date +\%Y-\%m-\%d`/"
		FINAL_BACKUP_DIR=$BACKUP_DIR

		echo "Making backup directory in $FINAL_BACKUP_DIR"

		if ! mkdir -p $FINAL_BACKUP_DIR; then
			echo "Cannot create backup directory in $FINAL_BACKUP_DIR. Go and fix it!" 1>&2
			exit 1
		fi

		#######################
		### GLOBALS BACKUPS ###
		#######################

		echo -e "\n\nPerforming globals backup"
		echo -e "--------------------------------------------\n"

		if [ $ENABLE_GLOBALS_BACKUPS = "yes" ]; then
			echo "Globals backup"

			set -o pipefail
			if ! pg_dump -Fc --dbname=postgresql://$USERNAME:$PASSWORD@$HOSTNAME:$PORT | gzip >$FINAL_BACKUP_DIR"globals".sql.gz.in_progress; then
				echo "[!!ERROR!!] Failed to produce globals backup" 1>&2
			else
				mv $FINAL_BACKUP_DIR"globals".sql.gz.in_progress $FINAL_BACKUP_DIR"globals".sql.gz
			fi
			set +o pipefail
		else
			echo "None"
		fi

		###########################
		### SCHEMA-ONLY BACKUPS ###
		###########################

		for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }; do
			SCHEMA_ONLY_CLAUSE="$SCHEMA_ONLY_CLAUSE or datname ~ '$SCHEMA_ONLY_DB'"
		done

		SCHEMA_ONLY_QUERY="select datname from pg_database where false $SCHEMA_ONLY_CLAUSE order by datname;"

		echo -e "\n\nPerforming schema-only backups"
		echo -e "--------------------------------------------\n"

		SCHEMA_ONLY_DB_LIST=$(psql postgresql://"$USERNAME":"$PASSWORD"@"$HOSTNAME":"$PORT" -At -c "$SCHEMA_ONLY_QUERY")
		# SCHEMA_ONLY_DB_LIST=`psql -h "$HOSTNAME" -U "$USERNAME" -At -c "$SCHEMA_ONLY_QUERY" postgres`

		echo -e "The following databases were matched for schema-only backup:\n${SCHEMA_ONLY_DB_LIST}\n"

		for DATABASE in $SCHEMA_ONLY_DB_LIST; do
			echo "Schema-only backup of $DATABASE"

			set -o pipefail
			if ! pg_dump -Fc --dbname=postgresql://"$USERNAME":"$PASSWORD"@"$HOSTNAME":"$PORT"/"$DATABASE" | gzip >$FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz.in_progress; then
				echo "[!!ERROR!!] Failed to backup database schema of $DATABASE" 1>&2
			else
				mv $FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz.in_progress $FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz
			fi
			set +o pipefail
		done

		###########################
		###### FULL BACKUPS #######
		###########################

		for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }; do
			EXCLUDE_SCHEMA_ONLY_CLAUSE="$EXCLUDE_SCHEMA_ONLY_CLAUSE and datname !~ '$SCHEMA_ONLY_DB'"
		done

		FULL_BACKUP_QUERY="select datname from pg_database where not datistemplate and datallowconn $EXCLUDE_SCHEMA_ONLY_CLAUSE order by datname;"

		echo -e "\n\nPerforming full backups"
		echo -e "--------------------------------------------\n"

		# for DATABASE in `psql -h "$HOSTNAME" -U "$USERNAME" -At -c "$FULL_BACKUP_QUERY" postgres`
		for DATABASE in $(psql postgresql://"$USERNAME":"$PASSWORD"@"$HOSTNAME":"$PORT" -At -c "$FULL_BACKUP_QUERY" postgres); do
			if [ $ENABLE_PLAIN_BACKUPS = "yes" ]; then
				echo "Plain backup of $DATABASE"

				set -o pipefail
				if ! pg_dump -Fc --dbname=postgresql://$USERNAME:$PASSWORD@$HOSTNAME:$PORT/"$DATABASE" | gzip >$FINAL_BACKUP_DIR"$DATABASE".sql.gz.in_progress; then
					echo "[!!ERROR!!] Failed to produce plain backup database $DATABASE" 1>&2
				else
					mv $FINAL_BACKUP_DIR"$DATABASE".sql.gz.in_progress $FINAL_BACKUP_DIR"$DATABASE".sql.gz
				fi
				set +o pipefail
			fi

			if [ $ENABLE_CUSTOM_BACKUPS = "yes" ]; then
				echo "Custom backup of $DATABASE"

				if ! pg_dump -Fc --dbname=postgresql://$USERNAME:$PASSWORD@$HOSTNAME:$PORT/"$DATABASE" -f $FINAL_BACKUP_DIR"$DATABASE".custom.in_progress; then
					echo "[!!ERROR!!] Failed to produce custom backup database $DATABASE" 1>&2
				else
					mv $FINAL_BACKUP_DIR"$DATABASE".custom.in_progress $FINAL_BACKUP_DIR"$DATABASE".custom
				fi
			fi

		done

		echo -e "\nAll database backups complete!"
	else
		echo "Time for backup doesn't match"
	fi

    wait
done
