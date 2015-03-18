#!/bin/bash
#
# ownCloud
#
# @author Vincent Petry
# @author Morris Jobke
# @author Robin McCorkell
# @author Thomas Müller
# @author Andreas Fischer
# @author Joas Schilling
# @author Lukas Reschke
# @copyright 2012-2015 Thomas Müller thomas.mueller@tmit.eu
#

set -e

#$EXECUTOR_NUMBER is set by Jenkins and allows us to run autotest in parallel
DATABASENAME=oc_autotest$EXECUTOR_NUMBER
DATABASEUSER=oc_autotest$EXECUTOR_NUMBER
ADMINLOGIN=admin$EXECUTOR_NUMBER
BASEDIR=$PWD

DBCONFIGS="sqlite mysql pgsql oci"
PHPUNIT=$(which phpunit)

function print_syntax {
	echo -e "Syntax: ./autotest.sh [dbconfigname] [testfile]\n" >&2
	echo -e "\t\"dbconfigname\" can be one of: $DBCONFIGS" >&2
	echo -e "\t\"testfile\" is the name of a test file, for example lib/template.php" >&2
	echo -e "\nExample: ./autotest.sh sqlite lib/template.php" >&2
	echo "will run the test suite from \"tests/lib/template.php\"" >&2
	echo -e "\nIf no arguments are specified, all tests will be run with all database configs" >&2
}

if ! [ -x "$PHPUNIT" ]; then
	echo "phpunit executable not found, please install phpunit version >= 3.7" >&2
	exit 3
fi

PHPUNIT_VERSION=$("$PHPUNIT" --version | cut -d" " -f2)
PHPUNIT_MAJOR_VERSION=$(echo $PHPUNIT_VERSION | cut -d"." -f1)
PHPUNIT_MINOR_VERSION=$(echo $PHPUNIT_VERSION | cut -d"." -f2)

if ! [ $PHPUNIT_MAJOR_VERSION -gt 3 -o \( $PHPUNIT_MAJOR_VERSION -eq 3 -a $PHPUNIT_MINOR_VERSION -ge 7 \) ]; then
	echo "phpunit version >= 3.7 required. Version found: $PHPUNIT_VERSION" >&2
	exit 4
fi

if ! [ \( -w config -a ! -f config/config.php \) -o \( -f config/config.php -a -w config/config.php \) ]; then
	echo "Please enable write permissions on config and config/config.php" >&2
	exit 1
fi

if [ "$1" ]; then
	FOUND=0
	for DBCONFIG in $DBCONFIGS; do
		if [ "$1" = $DBCONFIG ]; then
			FOUND=1
			break
		fi
	done
	if [ $FOUND = 0 ]; then
		echo -e "Unknown database config name \"$1\"\n" >&2
		print_syntax
		exit 2
	fi
fi

# Back up existing (dev) config if one exists and backup not already there
if [ -f config/config.php ] && [ ! -f config/config-autotest-backup.php ]; then
	mv config/config.php config/config-autotest-backup.php
fi

function cleanup_config {
	cd "$BASEDIR"
	# Restore existing config
	if [ -f config/config-autotest-backup.php ]; then
		mv config/config-autotest-backup.php config/config.php
	fi
	# Remove autotest config
	if [ -f config/autoconfig.php ]; then
		rm config/autoconfig.php
	fi
}

# restore config on exit
trap cleanup_config EXIT

# use tmpfs for datadir - should speedup unit test execution
if [ -d /dev/shm ]; then
  DATADIR=/dev/shm/data-autotest$EXECUTOR_NUMBER
else
  DATADIR=$BASEDIR/data-autotest
fi

echo "Using database $DATABASENAME"

function execute_tests {
	echo "Setup environment for $1 testing ..."
	# back to root folder
	cd "$BASEDIR"

	# revert changes to tests/data
	git checkout tests/data

	# reset data directory
	rm -rf "$DATADIR"
	mkdir "$DATADIR"

	cp tests/preseed-config.php config/config.php

	# drop database
	if [ "$1" == "mysql" ] ; then
		mysql -u $DATABASEUSER -powncloud -e "DROP DATABASE IF EXISTS $DATABASENAME" || true
	fi
	if [ "$1" == "pgsql" ] ; then
		dropdb -U $DATABASEUSER $DATABASENAME || true
	fi
	if [ "$1" == "oci" ] ; then
		echo "drop the database"
		sqlplus -s -l / as sysdba <<EOF
			drop user $DATABASENAME cascade;
EOF

		echo "create the database"
		sqlplus -s -l / as sysdba <<EOF
			create user $DATABASENAME identified by owncloud;
			alter user $DATABASENAME default tablespace users
			temporary tablespace temp
			quota unlimited on users;
			grant create session
			, create table
			, create procedure
			, create sequence
			, create trigger
			, create view
			, create synonym
			, alter session
			to $DATABASENAME;
			exit;
EOF
		DATABASEUSER=$DATABASENAME
		DATABASENAME='XE'
	fi

	# trigger installation
	echo "Installing ...."
	./occ maintenance:install --database=$1 --database-name=$DATABASENAME --database-host=localhost --database-user=$DATABASEUSER --database-pass=owncloud --database-table-prefix=oc_ --admin-user=$ADMINLOGIN --admin-pass=admin --data-dir=$DATADIR

	#test execution
	echo "Testing with $1 ..."
	cd tests
	rm -rf "coverage-html-$1"
	mkdir "coverage-html-$1"
	php -f enable_all.php | grep -i -C9999 error && echo "Error during setup" && exit 101
	if [ -z "$NOCOVERAGE" ]; then
		"$PHPUNIT" --debug --verbose --configuration phpunit-autotest.xml --log-junit "autotest-results-$1.xml" --coverage-clover "autotest-clover-$1.xml" --coverage-html "coverage-html-$1" "$2" "$3"
		RESULT=$?
	else
		echo "No coverage"
		"$PHPUNIT" --debug --verbose --configuration phpunit-autotest.xml --log-junit "autotest-results-$1.xml" "$2" "$3"
		RESULT=$?
	fi
}

#
# start test execution
#
if [ -z "$1" ]
  then
	# run all known database configs
	for DBCONFIG in $DBCONFIGS; do
		execute_tests $DBCONFIG
	done
else
	FILENAME="$2"
	if [ ! -z "$2" ] && [ ! -f "tests/$FILENAME" ]; then
		FILENAME="../$FILENAME"
	fi
	execute_tests "$1" "$FILENAME" "$3"
fi

#
# NOTES on mysql:
#  - CREATE DATABASE oc_autotest;
#  - CREATE USER 'oc_autotest'@'localhost' IDENTIFIED BY 'owncloud';
#  - grant all on oc_autotest.* to 'oc_autotest'@'localhost';
#
#  - for parallel executor support with EXECUTOR_NUMBER=0:
#  - CREATE DATABASE oc_autotest0;
#  - CREATE USER 'oc_autotest0'@'localhost' IDENTIFIED BY 'owncloud';
#  - grant all on oc_autotest0.* to 'oc_autotest0'@'localhost';
#
# NOTES on pgsql:
#  - su - postgres
#  - createuser -P oc_autotest (enter password and enable superuser)
#  - to enable dropdb I decided to add following line to pg_hba.conf (this is not the safest way but I don't care for the testing machine):
# local	all	all	trust
#
#  - for parallel executor support with EXECUTOR_NUMBER=0:
#  - createuser -P oc_autotest0 (enter password and enable superuser)
#
# NOTES on oci:
#  - it's a pure nightmare to install Oracle on a Linux-System
#  - DON'T TRY THIS AT HOME!
#  - if you really need it: we feel sorry for you
#
