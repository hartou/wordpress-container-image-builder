FROM wordpress:php7.4-apache
# COPY php.ini /usr/local/etc/php/conf.d/wp-php.ini
COPY wp-config.php /var/www/html/wp-config.php
WORKDIR /var/www/html