#!/bin/bash
# Starts postfix in one of two delivery modes (see README "Delivery modes"):
#   relay  - forward everything through EMAIL_RELAY_HOST (NTNU's mailgw).
#   direct - deliver straight to recipients' MX servers. Also starts postsrsd
#            (SRS, so forwarded mail passes SPF) and opendkim (DKIM-signs
#            mail from our own domain).
set -euo pipefail

fail() { echo "entrypoint: $*" >&2; exit 1; }

[ -n "${WEBSITE_DOMAIN:-}" ] || fail "WEBSITE_DOMAIN must be set (e.g. omega.ntnu.no)"
case "${DELIVERY_MODE:-}" in
    relay)
        [ -n "${EMAIL_RELAY_HOST:-}" ] || fail "DELIVERY_MODE=relay needs EMAIL_RELAY_HOST (e.g. mailgw.ntnu.no)"
        ;;
    direct)
        DKIM_SELECTOR="${DKIM_SELECTOR:-mail}"
        ;;
    *)
        fail "DELIVERY_MODE must be 'relay' or 'direct', got '${DELIVERY_MODE:-}'"
        ;;
esac

# The mail host: EMAIL_HOSTNAME if set (the same name as the website's
# EMAIL_HOSTNAME, e.g. sanctus.omega.ntnu.no), otherwise mail.<domain> - see
# DNS.md for the matching A/PTR records. Exported so the templates below can
# use it.
export EMAIL_HOSTNAME="${EMAIL_HOSTNAME:-mail.$WEBSITE_DOMAIN}"

# sasldb2 defaults to root:root 600 - smtpd runs as the postfix user, so it
# needs read access. The realm (-u) must match myhostname, since that's
# the default realm Cyrus SASL checks against when smtpd_sasl_local_domain
# is unset.
echo "$SUBMISSION_PASSWORD" | saslpasswd2 -p -c -f /etc/sasldb2 -u "$EMAIL_HOSTNAME" "$SUBMISSION_USERNAME"
chmod 644 /etc/sasldb2

# maillog_file only takes one destination, and postfix-exporter needs the
# file - so mirror it to stdout with tail, so it also shows up in Dokploy's
# log view / docker logs. -F survives logrotate's copytruncate, -n 0 skips
# replaying what's already in the volume from before a restart.
tail -n 0 -F /var/log/postfix/maillog &
crond

dockerize \
    -template /etc/postfix/main.cf.tmpl:/etc/postfix/main.cf \
    -template /etc/postfix/pgsql-aliases.cf.tmpl:/etc/postfix/pgsql-aliases.cf \
    -template /etc/postsrsd/postsrsd.conf.tmpl:/etc/postsrsd/postsrsd.conf \
    true

if [ "$DELIVERY_MODE" = direct ]; then
    # opendkim only logs to syslog - run a minimal one that writes to stdout.
    syslogd -n -O - &

    # SRS secret signs the rewritten sender addresses, so bounces to them
    # keep working only while it stays the same - hence the volume.
    secret=/etc/postsrsd/data/postsrsd.secret
    if [ ! -s "$secret" ]; then
        head -c 32 /dev/urandom | base64 > "$secret"
    fi
    chmod 600 "$secret"
    postsrsd -C /etc/postsrsd/postsrsd.conf &

    # One key per domain, kept on the dkim-keys volume: the public half is
    # published in DNS, so it must survive redeploys, and switching
    # WEBSITE_DOMAIN must never sign with another domain's key.
    keydir="/etc/opendkim/keys/$WEBSITE_DOMAIN"
    if [ ! -s "$keydir/$DKIM_SELECTOR.private" ]; then
        mkdir -p "$keydir"
        opendkim-genkey -b 2048 -d "$WEBSITE_DOMAIN" -s "$DKIM_SELECTOR" -D "$keydir"
    fi
    chown -R opendkim:opendkim "$keydir"
    chmod 600 "$keydir/$DKIM_SELECTOR.private"

    # Sign mail From <domain> and mail.<domain> (bounces) with d=<domain>.
    printf '%s._domainkey.%s %s:%s:%s\n' \
        "$DKIM_SELECTOR" "$WEBSITE_DOMAIN" "$WEBSITE_DOMAIN" "$DKIM_SELECTOR" "$keydir/$DKIM_SELECTOR.private" \
        > /etc/opendkim/KeyTable
    printf '*@%s %s._domainkey.%s\n*@%s %s._domainkey.%s\n' \
        "$WEBSITE_DOMAIN" "$DKIM_SELECTOR" "$WEBSITE_DOMAIN" \
        "$EMAIL_HOSTNAME" "$DKIM_SELECTOR" "$WEBSITE_DOMAIN" \
        > /etc/opendkim/SigningTable
    mkdir -p /run/opendkim && chown opendkim:opendkim /run/opendkim
    opendkim -x /etc/opendkim/opendkim.conf

    # The record to publish (see DNS.md), flattened to one line for DNS
    # admin UIs. opendkim-genkey's .txt holds it split into quoted chunks.
    dkim_value=$(tr -d '\n' < "$keydir/$DKIM_SELECTOR.txt" \
        | sed -E 's/^[^(]*\(//; s/\).*$//; s/"[[:space:]]*"//g; s/"//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
    echo "entrypoint: DKIM DNS record (TXT) - publish this, see DNS.md:"
    echo "entrypoint:   name:  $DKIM_SELECTOR._domainkey.$WEBSITE_DOMAIN"
    echo "entrypoint:   value: $dkim_value"
fi

exec postfix start-fg
