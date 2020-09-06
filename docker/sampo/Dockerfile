# Copyright (C) Jacob Salmela, 2020 <me@jacobsalmela.com>
# This file is part of sampo
FROM bash:4.4
MAINTAINER Jacob Salmela <me@jacobsalmela.com>

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
#         protocol  :port,
CMD socat TCP-LISTEN:1042,reuseaddr,pf=ip4,bind=127.0.0.1,fork system:/sampo.sh
