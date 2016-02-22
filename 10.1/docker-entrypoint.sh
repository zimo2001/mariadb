#!/bin/bash
set -e

if [ "${1:0:1}" = '-' ]; then
    set -- mysqld "$@"
fi

if [ "$1" = 'mysqld' ]; then
    tempSqlFile='/tmp/mysql-first-time.sql'

    # read DATADIR from the MySQL config
    DATADIR="$("$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"

    if [ ! -d "$DATADIR/mysql" ]; then
        if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ]; then
            echo >&2 'error: database is uninitialized and MYSQL_ROOT_PASSWORD not set'
            echo >&2 '  Did you forget to add -e MYSQL_ROOT_PASSWORD=... ?'
            exit 1
        fi

        echo 'Running mysql_install_db ...'
                mysql_install_db --datadir="$DATADIR"
                echo 'Finished mysql_install_db'


        # These statements _must_ be on individual lines, and _must_ end with
        # semicolons (no line breaks or comments are permitted).
        # TODO proper SQL escaping on ALL the things D:

        cat > "$tempSqlFile" <<-EOSQL
DELETE FROM mysql.user ;
CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
GRANT PROCESS ON *.* TO 'clustercheckuser'@'localhost' IDENTIFIED BY 'clustercheckpassword!';
DROP DATABASE IF EXISTS test ;
EOSQL

        if [ "$MYSQL_DATABASE" ]; then
            echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> "$tempSqlFile"
        fi

        if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
            echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" >> "$tempSqlFile"

            if [ "$MYSQL_DATABASE" ]; then
                echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" >> "$tempSqlFile"
            fi
        fi
    fi



    if [ -n "$GALERA_CLUSTER" -a "$GALERA_CLUSTER" = true ]; then
        cp /tmp/cluster.cnf /etc/mysql/conf.d/cluster.cnf

	sed -i -e "s|^#wsrep_on.*$|wsrep_on = ON|" /etc/mysql/conf.d/cluster.cnf

        WSREP_SST_USER=${WSREP_SST_USER:-"sst"}
        if [ -z "$WSREP_SST_PASSWORD" ]; then
            echo >&2 'error: database is uninitialized and WSREP_SST_PASSWORD not set'
            echo >&2 '  Did you forget to add -e WSREP_SST_PASSWORD=xxx ?'
            exit 1
        fi

        sed -i -e "s|wsrep_sst_auth \= \"sstuser:changethis\"|wsrep_sst_auth = ${WSREP_SST_USER}:${WSREP_SST_PASSWORD}|" /etc/mysql/conf.d/cluster.cnf

	if [ -n "$CLUSTER_NAME" ]; then
           sed -i -e "s|^wsrep_cluster_name \= .*$|wsrep_cluster_name = ${CLUSTER_NAME}|" /etc/mysql/conf.d/cluster.cnf
        fi

	if [ -n "$NODE_NAME" ]; then
           sed -i -e "s|^#wsrep_node_name \= .*$|wsrep_node_name = ${NODE_NAME}|" /etc/mysql/conf.d/cluster.cnf
        else
	   sed -i -e "s|^#wsrep_node_name \= .*$|wsrep_node_name = $(hostname)|" /etc/mysql/conf.d/cluster.cnf
        fi
	
        WSREP_NODE_ADDRESS=`ip addr show | grep -E '^[ ]*inet' | grep -m1 global | awk '{ print $2 }' | sed -e 's/\/.*//'`
        if [ -n "$WSREP_NODE_ADDRESS" ]; then
            sed -i -e "s|^#wsrep_node_address \= .*$|wsrep_node_address = ${WSREP_NODE_ADDRESS}|" /etc/mysql/conf.d/cluster.cnf
            if [ -n "$WSREP_CLUSTER_ADDRESS"  -a "$WSREP_CLUSTER_ADDRESS" != "gcomm://" ]; then
                WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS},${WSREP_NODE_ADDRESS}"
            fi
        fi

        # CoreOS, using fleet
        if [ -n "$FLEETCTL_ENDPOINT" -a -e './etcdctl' -a -z "$WSREP_CLUSTER_ADDRESS" ]; then
            WSREP_CLUSTER_ADDRESS=""

            if [ -n "$BOOTSTRAP_NODE" -a "$(hostname)" == "$BOOTSTRAP_NODE" ]; then
               WSREP_CLUSTER_ADDRESS='gcomm://'
            else
               # wait for all the expected nodes to be registered in etcd	    
               if [ -n $MIN_NODES ]; then
                  while [ $MIN_NODES -le $(./etcdctl --peers=${FLEETCTL_ENDPOINT} ls /galera | wc -l) ]; do
                     sleep 45
                  done
               fi

               for key in $(./etcdctl --peers=${FLEETCTL_ENDPOINT} ls /galera/|| true); do
                   NODE=$(./etcdctl --peers=${FLEETCTL_ENDPOINT} get ${key} || true)

                   if [ "$WSREP_CLUSTER_ADDRESS" != '' ]; then
                      WSREP_CLUSTER_ADDRESS=$WSREP_CLUSTER_ADDRESS,${NODE}
                   else
                       WSREP_CLUSTER_ADDRESS=${NODE}
                   fi
               done

               WSREP_CLUSTER_ADDRESS=gcomm://${WSREP_CLUSTER_ADDRESS}
           fi
        fi



        # Kubernetes
        # if kubernetes, take advantage of the metadata, unless of course already set
        if [ -n "$KUBERNETES_RO_SERVICE_HOST" -a -e './kubectl' -a -z "$WSREP_CLUSTER_ADDRESS" ]; then
            WSREP_CLUSTER_ADDRESS=gcomm://
            for node in 1 2 3; do
                WSREP_NODE=`./kubectl --server=${KUBERNETES_RO_SERVICE_HOST}:${KUBERNETES_RO_SERVICE_PORT} get pods| grep "^pxc-node${node}" | tr -d '\n' | awk '{ print $2 }'`
                if [ ! -z $WSREP_NODE ]; then
                    if [ $node -gt 1 -a $node != "" ]; then
                        WSREP_NODE=",${WSREP_NODE}"
                    fi
                    WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS}${WSREP_NODE}"
                fi
            done
        fi

        if [ -n "$WSREP_CLUSTER_ADDRESS" -a "$WSREP_CLUSTER_ADDRESS" != "gcomm://" ]; then
            sed -i -e "s|wsrep_cluster_address \= gcomm://|wsrep_cluster_address = ${WSREP_CLUSTER_ADDRESS}|" /etc/mysql/conf.d/cluster.cnf
        fi

        echo "CREATE USER '${WSREP_SST_USER}'@'localhost' IDENTIFIED BY '${WSREP_SST_PASSWORD}';" >> "$tempSqlFile"
        echo "GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${WSREP_SST_USER}'@'localhost';" >> "$tempSqlFile"

        # enabling clustercheck via xinetd
        /etc/init.d/xinetd restart
    fi

    echo 'FLUSH PRIVILEGES ;' >> "$tempSqlFile"
    set -- "$@" --init-file="$tempSqlFile"
    chown -R mysql:mysql "$DATADIR"
fi

exec "$@"

