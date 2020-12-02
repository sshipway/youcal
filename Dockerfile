FROM nimmis/alpine-micro

MAINTAINER sshipway <steve.shipway@smxemail.com>

RUN apk update && apk upgrade
RUN apk add apache2 libxml2-dev apache2-utils perl
RUN apk add perl-timedate perl-cgi perl-lwp-protocol-https perl-json
RUN rm -rf /var/cache/apk/*
COPY root/. /
COPY youcal.pl /var/www/localhost/cgi-bin/youcal
COPY youcal.conf /etc

VOLUME /etc/youcal
EXPOSE 80

