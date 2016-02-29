#!/bin/bash


# This will use current epoch time for server-id. 
# NOTE: running hosts' time needs to be synced!
# server-id parameter is in the size of 2^32, which will accept epoch time as parameter
# until somewhere around 2105... :)

sed -i -e "s/^server\-id\s*\=\s.*$/server-id = $(date '+%s')/" /etc/mysql/my.cnf
