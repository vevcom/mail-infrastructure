FROM alpine
ENV DOCKERIZE_VERSION v0.6.1

RUN apk add --no-cache --upgrade bash postfix postfix-pgsql openssl logrotate cyrus-sasl cyrus-sasl-login \
    postsrsd opendkim opendkim-utils

RUN wget https://github.com/jwilder/dockerize/releases/download/$DOCKERIZE_VERSION/dockerize-alpine-linux-amd64-$DOCKERIZE_VERSION.tar.gz \
    && tar -C /usr/local/bin -xzvf dockerize-alpine-linux-amd64-$DOCKERIZE_VERSION.tar.gz \
    && rm dockerize-alpine-linux-amd64-$DOCKERIZE_VERSION.tar.gz

# Self-signed cert for opportunistic STARTTLS on the public MX side. It is
# never validated by connecting clients (smtpd_tls_security_level=may), it
# just encrypts the hop, so a cert generated once at build time is enough.
RUN openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -subj "/CN=mail" -keyout /etc/postfix/tls.key -out /etc/postfix/tls.crt

# Cyrus SASL backend for smtpd_sasl_auth_enable (the webserver's submission
# to this container - see main.cf.tmpl). One fixed credential pair,
# written to sasldb2 at container startup from env vars (see
# entrypoint.sh), never baked into the image.
RUN mkdir -p /etc/sasl2 \
    && printf 'pwcheck_method: auxprop\nauxprop_plugin: sasldb\nsasldb_path: /etc/sasldb2\nmech_list: PLAIN LOGIN\n' > /etc/sasl2/smtpd.conf

COPY main.cf.tmpl pgsql-aliases.cf.tmpl /etc/postfix/
COPY postsrsd.conf.tmpl /etc/postsrsd/
COPY opendkim.conf /etc/opendkim/
COPY logrotate.conf /etc/logrotate.d/postfix
COPY entrypoint.sh /entrypoint.sh

# Volume mount points for DELIVERY_MODE=direct: the SRS secret and the DKIM
# keys must survive redeploys (see entrypoint.sh).
RUN mkdir -p /etc/postsrsd/data /etc/opendkim/keys

# maillog_file needs this directory to already exist.
RUN mkdir -p /var/log/postfix

# maillog_file has no built-in rotation, so the volume it lives on would
# otherwise grow forever. Rotate it ourselves, daily, via cron.
RUN echo "0 0 * * * logrotate /etc/logrotate.d/postfix" >> /etc/crontabs/root

EXPOSE 25

CMD ["/entrypoint.sh"]
