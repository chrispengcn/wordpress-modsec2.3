FROM wordpress:6.9-apache

RUN DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends libapache2-mod-security2 >/dev/null 2>&1 && \
    apt-get clean >/dev/null 2>&1 && \
    rm -rf /var/lib/apt/lists/* && \
    a2enmod security2 >/dev/null 2>&1 && \
    mv /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf && \
    sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/modsecurity/modsecurity.conf && \
    sed -i 's/SecResponseBodyAccess On/SecResponseBodyAccess Off/' /etc/modsecurity/modsecurity.conf && \
    echo "Include /etc/modsecurity-crs/crs-setup.conf" >> /etc/apache2/conf-enabled/security2.conf 


VOLUME ["/etc/modsecurity-crs", "/etc/modsecurity", "/var/www/html"]

CMD ["apache2-foreground"]

