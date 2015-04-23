#!/bin/sh
###############################################################################
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
###############################################################################

set -e

_db_helper() {
	case "$1" in
		(mysql:database)
			# database
			echo "CREATE DATABASE $2" | mysql --defaults-extra-file=/etc/mysql/debian.cnf
			;;
		(mysql:user)
			# database user password
			echo "GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,DROP,ALTER,LOCK TABLES,INDEX ON $2.* TO '$3'@'localhost' IDENTIFIED BY '$4';" | mysql --defaults-extra-file=/etc/mysql/debian.cnf
			echo "FLUSH PRIVILEGES;" | mysql --defaults-extra-file=/etc/mysql/debian.cnf
			;;
		(mysql:import)
			# database
			if [ -e /srv/ofbiz-localdev-base/dumps/mysql_$2.sql.gz ]; then
				zcat /srv/ofbiz-localdev-base/dumps/mysql_$2.sql.gz | mysql --defaults-extra-file=/etc/mysql/debian.cnf $2
			fi
			;;
		(postgresql:database)
			# database
			su - postgres -c "createdb '$2'"
			;;
		(postgresql:user)
			# database user password
			(echo "$4"; echo "$4") | su - postgres -c "createuser --no-createdb --no-createrole --no-superuser --pwprompt '$3'"
			;;
		(postgresql:import)
			# database 
			if [ -e /srv/ofbiz-localdev-base/dumps/postgresql_$2.sql.gz ]; then
				zcat /srv/ofbiz-localdev-base/dumps/postgresql_$2.sql.gz | su - postgres -c "psql '$2'"
			fi
			;;
	esac
}

. /srv/ofbiz-localdev-base/config/settings.sh

_create_local_user() {
	addgroup --gid "$local_gid" local-group
	adduser --disabled-password --force-badname --no-create-home --uid "$local_uid" --gid "$local_gid" --home /home/local-user --gecos "Local User" local-user
	echo local-user:local-user | chpasswd
	adduser ofbiz local-group
	adduser www-data local-group
}

_onexit() {
	/etc/init.d/postgresql stop
	/etc/init.d/mysql stop
	rm -f /tmp/*.xml
}

trap '_onexit' EXIT

mkdir -p /srv/client-config

cmd="$1"
shift

case "$cmd" in
	(db-init)
		/etc/init.d/mysql start
		/etc/init.d/postgresql start

		if ! [ "z${POSTGRESQL_OFBIZ_DATABASE}" = "z" ]; then
			DATASOURCE_TYPE=postgresql
			_db_helper postgresql:database ${POSTGRESQL_OFBIZ_DATABASE}
			_db_helper postgresql:database ${POSTGRESQL_OFBIZ_DATABASE}olap
			_db_helper postgresql:database ${POSTGRESQL_OFBIZ_DATABASE}tenant
			_db_helper postgresql:user ${POSTGRESQL_OFBIZ_DATABASE} ${POSTGRESQL_OFBIZ_USER} "${POSTGRESQL_OFBIZ_PASSWORD}"
		elif ! [ "z${MYSQL_OFBIZ_DATABASE}" = "z" ]; then
			DATASOURCE_TYPE=mysql
			_db_helper mysql:database ${MYSQL_OFBIZ_DATABASE}
			_db_helper mysql:database ${MYSQL_OFBIZ_DATABASE}olap
			_db_helper mysql:database ${MYSQL_OFBIZ_DATABASE}tenant
			_db_helper mysql:user ${MYSQL_OFBIZ_DATABASE} ${MYSQL_OFBIZ_USER} "${MYSQL_OFBIZ_PASSWORD}"
			_db_helper mysql:user ${MYSQL_OFBIZ_DATABASE}olap ${MYSQL_OFBIZ_USER} "${MYSQL_OFBIZ_PASSWORD}"
			_db_helper mysql:user ${MYSQL_OFBIZ_DATABASE}tenant ${MYSQL_OFBIZ_USER} "${MYSQL_OFBIZ_PASSWORD}"
		fi


		_db_helper mysql:database ${MYSQL_WORDPRESS_DATABASE}
		_db_helper mysql:user ${MYSQL_WORDPRESS_DATABASE} ${MYSQL_WORDPRESS_USER} "${MYSQL_WORDPRESS_PASSWORD}"

		sed -i \
			-e "s,\@CLIENT_DEV_SITENAME@,${CLIENT_DEV_SITENAME},g" \
			-e "s,\@MYSQL_WORDPRESS_DATABASE@,${MYSQL_WORDPRESS_DATABASE},g" \
			-e "s,\@MYSQL_WORDPRESS_USER@,${MYSQL_WORDPRESS_USER},g" \
			-e "s,\@MYSQL_WORDPRESS_PASSWORD@,${MYSQL_WORDPRESS_PASSWORD},g" \
			/srv/ofbiz-localdev-base/config/wp-config.php

		case "$DATASOURCE_TYPE" in
			(postgresql)
				sed -i \
					-e "s,\@POSTGRESQL_OFBIZ_DATABASE@,${POSTGRESQL_OFBIZ_DATABASE},g" \
					-e "s,\@POSTGRESQL_OFBIZ_USER@,${POSTGRESQL_OFBIZ_USER},g" \
					-e "s,\@POSTGRESQL_OFBIZ_PASSWORD@,${POSTGRESQL_OFBIZ_PASSWORD},g" \
					/srv/ofbiz-localdev-base/config/ofbiz/postgresql-datasources.xml

				sed -i \
					-e "s/\@DATASOURCE_TYPE@/${DATASOURCE_TYPE}/g" \
					-e '/^\@DATASOURCES@$/{
						s/^\@DATASOURCES@$//
						r /srv/ofbiz-localdev-base/config/ofbiz/postgresql-datasources.xml
					}
				' \
					/srv/ofbiz-localdev-base/config/ofbiz/entityengine.xml
				;;
			(mysql)
				sed -i \
					-e "s,\@MYSQL_OFBIZ_DATABASE@,${MYSQL_OFBIZ_DATABASE},g" \
					-e "s,\@MYSQL_OFBIZ_USER@,${MYSQL_OFBIZ_USER},g" \
					-e "s,\@MYSQL_OFBIZ_PASSWORD@,${MYSQL_OFBIZ_PASSWORD},g" \
					/srv/ofbiz-localdev-base/config/ofbiz/mysql-datasources.xml

				sed -i \
					-e "s/\@DATASOURCE_TYPE@/${DATASOURCE_TYPE}/g" \
					-e '/^\@DATASOURCES@$/{
						s/^\@DATASOURCES@$//
						r /srv/ofbiz-localdev-base/config/ofbiz/mysql-datasources.xml
					}
				' \
					/srv/ofbiz-localdev-base/config/ofbiz/entityengine.xml
				;;
		esac
		;;

	(db-import)
		/etc/init.d/mysql start
		/etc/init.d/postgresql start

		_db_helper postgresql:import ${POSTGRESQL_OFBIZ_DATABASE}
		_db_helper postgresql:import ${POSTGRESQL_OFBIZ_DATABASE}olap
		_db_helper postgresql:import ${POSTGRESQL_OFBIZ_DATABASE}tenant
		_db_helper postgresql:import ${MYSQL_OFBIZ_DATABASE}
		_db_helper postgresql:import ${MYSQL_OFBIZ_DATABASE}olap
		_db_helper postgresql:import ${MYSQL_OFBIZ_DATABASE}tenant
		_db_helper mysql:import ${MYSQL_WORDPRESS_DATABASE}
		;;

	(nginx)
		sed -i \
			-e "s,\@OFBIZ_HTTP_HTTPS_PORT@,${OFBIZ_PORT},g" \
			-e "s,\@WORDPRESS_ROOT@,${WORDPRESS_ROOT},g" \
			-e "s,\@JS_APP_ROOT@,${JS_APP_ROOT},g" \
			-e "s,\@JS_APP_PREFIX@,${JS_APP_PREFIX},g" \
			-e "s,\@NGINX_OFBIZ_REGEX@,${NGINX_OFBIZ_REGEX},g" \
			-e "s,\@NGINX_SSI@,${NGINX_SSI},g" \
			/srv/ofbiz-localdev-base/config/nginx.conf

		openssl req -new -nodes -x509 -subj "/C=US/ST=Texas/L=Dallas/CN=${CLIENT_DEV_SITENAME}" -days 3650 -keyout "/srv/ofbiz-localdev-base/config/ssl.key" -out "/srv/ofbiz-localdev-base/config/ssl.crt" -extensions v3_ca
		;;

	(local-user)
		local_uid="$1"
		local_gid="$2"
		_create_local_user
		;;

	(wordpress-tables)
		/etc/init.d/mysql start
		cd "${WORDPRESS_ROOT}"
		sudo -u www-data /srv/ofbiz-localdev-base/bin/wp-cli --allow-root core install --url="${CLIENT_DEV_SITENAME}" --title="${CLIENT_DEV_SITENAME_TITLE}" --admin_user="${CLIENT_DEV_USER}" --admin_password="${CLIENT_DEV_PASSWORD}" --admin_email="${CLIENT_DEV_EMAIL}"
		sudo -u www-data /srv/ofbiz-localdev-base/bin/wp-cli option update permalink_structure '/%postname%/'
		sudo -u www-data /srv/ofbiz-localdev-base/bin/wp-cli plugin activate content-backend ofbiz-backend
		;;

	(ofbiz-*)
		set -x
		/etc/init.d/postgresql start
		/etc/init.d/mysql start
		cat > /tmp/empty-seed.xml << _EOF_
<?xml version="1.0" encoding="UTF-8"?>
<entity-engine-xml>
</entity-engine-xml>
_EOF_
		/etc/init.d/ofbiz-init "$@"
		rm /tmp/empty-seed.xml
		;;

	(snapshot)
		trap '' EXIT
		local_uid="$1"
		local_gid="$2"
		_create_local_user
		exec bash
		;;
esac



