FROM wakaba/docker-perl-app-base

RUN apt-get update && \
    DEBIAN_FRONTEND="noninteractive" apt-get -y install mysql-server libmysqlclient-dev && \
    rm -rf /var/lib/apt/lists/*

RUN mv /app /app.orig && \
    git clone https://github.com/wakaba/accounts /app && \
    mv /app.orig/* /app/ && \
    cd /app && make deps PMBP_OPTIONS=--execute-system-package-installer && \
    echo '#!/bin/bash' > /server && \
    echo 'cd /app && ./plackup bin/server.psgi -p 8080 -s Twiggy::Prefork --max-workers 5' >> /server && \
    chmod u+x /server && \
    rm -fr /app/deps /app.orig

## License: Public Domain.