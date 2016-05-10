#!/bin/sh -ex

printf 'shibd backend will have IPv4 address %s. All containers are in subnet %s.\n' "${SHIBD_BACKEND_IP}" "${SHIBD_BACKEND_IP_CIDR}"

# TODO: minimize boost-dev
apk --no-cache \
  add \
      'apache2-dev' \
      'boost-dev' \
      'build-base' \
      'curl' \
      'curl-dev' \
      'file' \
      'git' \
      'gnupg' \
      'openssl' \
      'openssl-dev' \
      'binutils-gold' \
      'libstdc++' \
      'libgcc'

cd '/srv/build/'

###
##   Download and verify software source code distributions
###

curl --fail --location --show-error --silent --tlsv1.2 \
    --output 'Santuario_KEYS.asc' 'https://www-eu.apache.org/dist/santuario/KEYS' \
    --output 'Shibboleth_KEYS.asc' 'https://shibboleth.net/downloads/PGP_KEYS' \
    --output 'Xerces_KEYS.asc' 'https://www-eu.apache.org/dist/xerces/c/KEYS' \
    --remote-name 'https://shibboleth.net/downloads/c++-opensaml/2.5.5/opensaml-2.5.5.tar.gz' \
    --remote-name 'https://shibboleth.net/downloads/c++-opensaml/2.5.5/opensaml-2.5.5.tar.gz.asc' \
    --remote-name 'https://shibboleth.net/downloads/c++-opensaml/2.5.5/xmltooling-1.5.6.tar.gz' \
    --remote-name 'https://shibboleth.net/downloads/c++-opensaml/2.5.5/xmltooling-1.5.6.tar.gz.asc' \
    --remote-name 'https://shibboleth.net/downloads/log4shib/1.0.9/log4shib-1.0.9.tar.gz' \
    --remote-name 'https://shibboleth.net/downloads/log4shib/1.0.9/log4shib-1.0.9.tar.gz.asc' \
    --remote-name 'https://shibboleth.net/downloads/service-provider/2.5.6/shibboleth-sp-2.5.6.tar.gz' \
    --remote-name 'https://shibboleth.net/downloads/service-provider/2.5.6/shibboleth-sp-2.5.6.tar.gz.asc' \
    --remote-name 'https://www-eu.apache.org/dist/santuario/c-library/xml-security-c-1.7.3.tar.gz' \
    --remote-name 'https://www-eu.apache.org/dist/santuario/c-library/xml-security-c-1.7.3.tar.gz.asc' \
    --remote-name 'https://www-eu.apache.org/dist/xerces/c/3/sources/xerces-c-3.1.3.tar.gz' \
    --remote-name 'https://www-eu.apache.org/dist/xerces/c/3/sources/xerces-c-3.1.3.tar.gz.asc'

gpg --import 'Shibboleth_KEYS.asc' 'Xerces_KEYS.asc' 'Santuario_KEYS.asc'
gpg --trust-model 'always' --verify-files *.asc

###
##   Build
###

find -maxdepth '1' -type 'f' -name '*.tar.gz' -exec tar -xzpf '{}' \;

cd 'log4shib-1.0.9/'

(cd tests/

## Patch created with:
## diff -up original.file new.file > filename.patch
tee 'Clock.hh.patch' <<'EOF'
--- Clock.hh
+++ Clock.hh
@@ -6,6 +6,8 @@
 #ifndef __CLOCK_H
 #define __CLOCK_H

+#include <sys/types.h>
+
 #ifdef LOG4SHIB_HAVE_STDINT_H
 #include <stdint.h>
 #endif // LOG4SHIB_HAVE_STDINT_H
EOF

for i in *.patch; do
   printf '%s\n' "Applying ${i}"
   patch -p0 -i $i || return 1
done)

LD='/usr/bin/ld.gold'; export LD
CFLAGS='-Wl,-fuse-ld=gold'; export CFLAGS
CXXFLAGS="${CFLAGS}"; export CXXFLAGS

./configure \
    --disable-dependency-tracking \
    --disable-doxygen \
    --disable-static \
    --enable-silent-rules \
    --silent
make -j 4 -s V=0 install
cd -

cd 'xerces-c-3.1.3/'
# TODO: --enable-netaccessor-socket required?
./configure \
    --disable-dependency-tracking \
    --enable-netaccessor-libcurl \
    --enable-silent-rules \
    --silent
make -j 4 -s V=0 install
cd -

cd 'xml-security-c-1.7.3/'
# TODO: upstream bug, cannot find header file xercesc/dom/DOM.hpp unless --with-xerces='/usr/local/' is set
./configure \
    --disable-dependency-tracking \
    --disable-static \
    --enable-silent-rules \
    --silent \
    --with-xerces='/usr/local/' \
    --without-xalan
make -j 4 -s V=0 install
cd -

cd 'xmltooling-1.5.6/'
./configure \
    -C \
    --disable-doxygen-doc \
    --disable-dependency-tracking \
    --enable-silent-rules \
    --silent
make -j 4 -s V=0 install
cd -

cd 'opensaml-2.5.5/'
./configure \
    -C \
    --disable-doxygen-doc \
    --disable-dependency-tracking \
    --enable-silent-rules \
    --silent
make -j 4 -s V=0 install
cd -

cd 'shibboleth-sp-2.5.6/'
# TODO: Forcefully disable key pair generation.
# ln -sf '/bin/true' 'configs/keygen.sh'
./configure \
    --disable-adfs \
    --disable-dependency-tracking \
    --disable-doxygen-doc \
    --disable-odbc \
    --enable-silent-rules \
    --enable-apache-24 \
    --silent \
    --with-apxs24='/usr/bin/apxs' \
    --with-xmltooling='/usr/local/'
make -j 4 -s V=0 install
cd -

###
##   Configure Apache httpd
###

sed -i '/^UseCanonicalName Off$/s/ Off/ On/g' '/etc/apache2/httpd.conf'
# TODO: UseCanonicalPhysicalPort On?

cp -f '/usr/local/etc/shibboleth/apache24.config' '/etc/apache2/conf.d/Shibboleth_SP.conf'

###
##   Configure Shibboleth SP
###

git clone 'https://github.com/clarin-eric/SPF-tutorial.git' '/srv/SPF-tutorial/'
cd '/srv/SPF-tutorial/'
cp -f 'basic_SAML_metadata_about_test-sp.clarin.eu.xml' \
    'native.logger' \
    'shibboleth2.xml' \
    'shibd.logger' \
    'SPF_signing_pub.crt' \
    'test-sp.clarin.eu.template.metadata.xml' \
    '/usr/local/etc/shibboleth/'

cd '/usr/local/etc/shibboleth/'
awk -v TCPListener_element="$(printf '    <TCPListener address="%s" port="1600" acl="%s"/>' "${SHIBD_BACKEND_IP}" "${SHIBD_BACKEND_IP_CIDR}")" \
    '/<!-- # tag::TCPListener\[\] -->/ {inblock=1}
    /<!-- # end::TCPListener\[\] -->/ {inblock=0;}
    { if (inblock==1 && (/<!-- \.\.\. -->/)) { print TCPListener_element } else print $0}' 'shibboleth2.xml' > 'shibboleth2.xml.new'
mv -f 'shibboleth2.xml.new' 'shibboleth2.xml'

addgroup -S 'shibd'
adduser -D -H -G 'shibd' -S 'shibd'

ln -fs ~shibd/'shibd_keystore/sp-cert.pem' \
    'sp-cert.pem'
ln -fs ~shibd/'shibd_keystore/sp-key.pem' \
    'sp-key.pem'

# TODO: shibd apparently does not support dropping privileges. Sadly ~shibd/shibd-keystore/ must be writable in order to fix ownership so that shibd can read the private key file, even if run as the shibd user.
chown -Rv 'shibd:shibd' \
    '/usr/local/var/cache/shibboleth' \
    '/usr/local/var/run/shibboleth' \
    ~shibd

###
##   Purge
###

cd /

# TODO: find out when apk fails to remove a package in a list even when it is installed, because of preceding package.

echo 'postgresql' 'openssl-dev' 'build-base' \
    'boost-dev' 'binutils-gold' 'python' 'git' \
    'gnupg' 'file' | \
    xargs -n '1' -- apk --no-cache --purge del --rdepends

rm -rf '/usr/local/include/'
rm -rf '/opt/venvs/'

## Test

shibd -t