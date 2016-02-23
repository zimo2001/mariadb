# vim:set ft=dockerfile:
FROM debian:jessie

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mysql && useradd -r -g mysql mysql

# net-tools for ifconfig, vim, xinetd for clustercheck
RUN apt-get update && apt-get install -y net-tools vim xinetd && rm -rf /var/lib/apt/lists/*

RUN apt-key adv --keyserver ha.pool.sks-keyservers.net --recv-keys 199369E5404BD5FC7D2FE43BCBCB082A1BB943DB

ENV MARIADB_MAJOR 10.1
ENV MARIADB_VERSION 10.1.11+maria-1~jessie

RUN echo "deb http://ftp.osuosl.org/pub/mariadb/repo/$MARIADB_MAJOR/debian jessie main" > /etc/apt/sources.list.d/mariadb.list \
	&& { \
		echo 'Package: *'; \
		echo 'Pin: release o=MariaDB'; \
		echo 'Pin-Priority: 999'; \
	} > /etc/apt/preferences.d/mariadb
# add repository pinning to make sure dependencies from this MariaDB repo are preferred over Debian dependencies
#  libmariadbclient18 : Depends: libmysqlclient18 (= 5.5.42+maria-1~wheezy) but 5.5.43-0+deb7u1 is to be installed

# install percona-repo & sst_xtrabackup_v2 deps
COPY percona-release_0.1-3.jessie_all.deb /tmp/percona-release_0.1-3.jessie_all.deb
RUN dpkg -i /tmp/percona-release_0.1-3.jessie_all.deb \
	&& apt-get update \
	&& apt-get install -y percona-toolkit percona-xtrabackup socat pv qpress


# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN { \
		echo mariadb-server-$MARIADB_MAJOR mysql-server/root_password password 'irrelevant'; \
		echo mariadb-server-$MARIADB_MAJOR mysql-server/root_password_again password 'irrelevant'; \
	} | debconf-set-selections \
	&& apt-get update \
	&& apt-get install -y \
		mariadb-server=$MARIADB_VERSION \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -rf /var/lib/mysql \
	&& mkdir /var/lib/mysql

# comment out a few problematic configuration values
# don't reverse lookup hostnames, they are usually another container
#RUN sed -Ei 's/^(bind-address|log)/#&/' /etc/mysql/my.cnf \
#	&& echo 'skip-host-cache\nskip-name-resolve' | awk '{ print } $1 == "[mysqld]" && c == 0 { c = 1; system("cat") }' /etc/mysql/my.cnf > /tmp/my.cnf \
#	&& mv /tmp/my.cnf /etc/mysql/my.cnf

VOLUME /var/lib/mysql


COPY kubectl /kubectl
COPY etcdctl /etcdctl
RUN chmod +x /kubectl
RUN chmod +x /etcdctl

# my.cnf files

COPY my.cnf /etc/mysql/my.cnf
COPY cluster.cnf /tmp/cluster.cnf


# copy clustercheck and setup xinetd
COPY clustercheck /usr/bin/clustercheck
RUN chmod +x /usr/bin/clustercheck
COPY mysqlchk /etc/xinetd.d/mysqlchk
RUN chmod +x /etc/xinetd.d/mysqlchk
RUN echo "mysqlchk    9200/tcp    # MySQL check" >> /etc/services


# need random.sh because otherwise, ENV $RANDOM is not set - this is randomized server-id...
COPY random.sh /tmp/random.sh
RUN /tmp/random.sh


COPY docker-entrypoint.sh /

ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 3306 4444 4567 4568 9200
CMD ["mysqld"]
