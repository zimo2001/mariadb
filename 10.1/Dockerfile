# vim:set ft=dockerfile:
FROM phusion/baseimage:latest

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mysql && useradd -r -g mysql mysql

# upgrading and installing xinetd for clustercheck
RUN apt-get update && apt-get upgrade -y -o Dpkg::Options::="--force-confold" && apt-get install -y software-properties-common xinetd

# MariaDB key for apt
RUN apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xcbcb082a1bb943db

# adding the MariaDB source to apt
RUN add-apt-repository 'deb [arch=amd64,i386] http://mirror.netcologne.de/mariadb/repo/10.1/ubuntu trusty main'

# add repository pinning to make sure dependencies from this MariaDB repo are preferred over Debian dependencies
# libmariadbclient18 : Depends: libmysqlclient18 (= 5.5.42+maria-1~wheezy) but 5.5.43-0+deb7u1 is to be installed
RUN { \
	echo 'Package: *'; \
	echo 'Pin: release o=MariaDB'; \
	echo 'Pin-Priority: 999'; \
} > /etc/apt/preferences.d/mariadb


# install percona-repo & sst_xtrabackup-v2 deps
COPY percona-release_0.1-3.trusty_all.deb /tmp/percona-release_0.1-3.trusty_all.deb
RUN dpkg -i /tmp/percona-release_0.1-3.trusty_all.deb \
	&& apt-get update \
	&& apt-get install -y percona-toolkit percona-xtrabackup socat pv qpress



ENV MARIADB_MAJOR 10.1
ENV MARIADB_VERSION 10.1.11+maria-1~trusty

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN { \
	echo mariadb-server-$MARIADB_MAJOR mysql-server/root_password password 'irrelevant'; \
	echo mariadb-server-$MARIADB_MAJOR mysql-server/root_password_again password 'irrelevant'; \
	} | debconf-set-selections \
	&& apt-get update \
	&& apt-get install -y mariadb-server=$MARIADB_VERSION \
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


# generate server-id from epoch time.
COPY set_server-id.sh /tmp/set_server-id.sh
RUN chmod +x /tmp/set_server-id.sh
RUN /tmp/set_server-id.sh


# docker-entrypoint,xinetd in phusion's "my_init" style
RUN mkdir -p /etc/my_init.d
COPY docker-entrypoint.sh /etc/my_init.d/50_mysqld_MariaDB.sh
RUN chmod +x /etc/my_init.d/50_mysqld_MariaDB.sh
COPY xinetd.sh /etc/my_init.d/30_xinetd.sh
RUN chmod +x /etc/my_init.d/30_xinetd.sh


EXPOSE 3306 4444 4567 4568 9200
CMD ["/sbin/my_init"]


# Clean up APT when done.
RUN apt-get clean && rm -rf /var/lib/apt/lists/*


