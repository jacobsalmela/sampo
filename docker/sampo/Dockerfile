# Copyright (C) Jacob Salmela, 2020 <me@jacobsalmela.com>
# This file is part of sampo
FROM bash:4.4
LABEL Jacob Salmela <me@jacobsalmela.com>

RUN apk add --no-cache file netcat-openbsd socat

EXPOSE 1042

# Install the API shell script
ADD sampo.sh /sampo.sh

# Make it executable
RUN chmod 755 /sampo.sh

# Run the sampo.sh script, and listen on the exposed port from above using socat
# netcat is also included in case you want that (and is also useful for port checking between containers/pods)
# You can also run sampo directly in bash using a loop:
#    while true; do { echo -e 'HTTP/1.1 200 OK\r\n'; bash ./sampo.sh; } | nc -l 1042; done
#

#         TCP-LISTEN:PORT:    socat will listen locally on the specified port
#         reuseaddr,fork      When accepting a connection, socat will fork to handle it. This means that it can handle parallel connections, and won't die after the first connection
#
CMD socat -d -d TCP-LISTEN:1042,reuseaddr,fork,pf=ip4 \
          system:/sampo.sh 2>> /var/log/sampo.log
