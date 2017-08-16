# -*- coding: utf-8 -*-
# vim: ft=sls

{% from "letsencrypt/map.jinja" import letsencrypt with context %}


/usr/local/bin/check_letsencrypt_cert.sh:
  file.managed:
    - mode: 755
    - contents: |
        #!/bin/bash

        CERT_NAME=$1

        for DOMAIN in "$@"
        do
            openssl x509 -in /etc/letsencrypt/live/${CERT_NAME}/cert.pem -noout -text | grep DNS:${DOMAIN} > /dev/null || exit 1
        done
        [ -n "$CMD" ] && [  "$CMD" == "exists" ] && exit 0 #check only for existence
        CERT=$(date -d "$(openssl x509 -in /etc/letsencrypt/live/${CERT_NAME}/cert.pem -enddate -noout | cut -d'=' -f2)" "+%s")
        CURRENT=$(date "+%s")
        REMAINING=$((($CERT - $CURRENT) / 60 / 60 / 24))
        [ "$REMAINING" -gt "30" ] || exit 1
        echo Domains $@ are in cert and cert is valid for $REMAINING days

/usr/local/bin/renew_letsencrypt_cert.sh:
  file.managed:
    - template: jinja
    - source: salt://letsencrypt/files/renew_letsencrypt_cert.sh.jinja
    - mode: 755
    - require:
      - file: /usr/local/bin/check_letsencrypt_cert.sh

{%
  for setname, domainlist in salt['pillar.get'](
    'letsencrypt:domainsets'
  ).iteritems()
%}

create-initial-cert-{{ setname }}:
  cmd.run:
    - unless: CMD=exists /usr/local/bin/check_letsencrypt_cert.sh {{ domainlist|join(' ') }}
    - name: {{
          letsencrypt.cli_install_dir
        }}/certbot-auto -d {{ domainlist|join(' -d ') }} certonly
    - cwd: {{ letsencrypt.cli_install_dir }}
    - require:
      - file: letsencrypt-config
      - file: /usr/local/bin/check_letsencrypt_cert.sh

# domainlist[0] represents the "CommonName", and the rest
# represent SubjectAlternativeNames
letsencrypt-crontab-{{ setname }}:
  cron.present:
    - name: /usr/local/bin/renew_letsencrypt_cert.sh {{ domainlist|join(' ') }}
    - month: '*'
    - minute: random
    - hour: random
    - dayweek: '*/3'
    - identifier: letsencrypt-{{ setname }}
    - require:
      - cmd: create-initial-cert-{{ setname }}
      - file: /usr/local/bin/renew_letsencrypt_cert.sh

create-fullchain-privkey-pem-for-{{ setname }}:
  cmd.run:
    - name: |
        cat /etc/letsencrypt/live/{{ domainlist[0] }}/fullchain.pem \
            /etc/letsencrypt/live/{{ domainlist[0] }}/privkey.pem \
            > /etc/letsencrypt/live/{{ domainlist[0] }}/fullchain-privkey.pem && \
        chmod 600 /etc/letsencrypt/live/{{ domainlist[0] }}/fullchain-privkey.pem
    - creates: /etc/letsencrypt/live/{{ domainlist[0] }}/fullchain-privkey.pem
    - require:
      - cmd: create-initial-cert-{{ setname }}

link-by-setname-{{ setname }}:
  cmd.run:
    - name: |
        mkdir -p /etc/letsencrypt/setnames/{{ setname }} && \
        chmod 0700 /etc/letsencrypt/setnames/{{ setname }} && \
        ln -sf /etc/letsencrypt/live/{{ domainlist[0] }}/* /etc/letsencrypt/setnames/{{ setname }}/
    - creates: /etc/letsencrypt/setnames/{{ setname }}/fullchain-privkey.pem 
    - require:
      - cmd: create-fullchain-privkey-pem-for-{{ setname }}

{% endfor %}
