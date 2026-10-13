# The official mysql:8.4 image ships a minimal client set without mysqlbinlog,
# mysqlcheck or mysqldumpslow, which the backup, recovery and diagnostics
# modules need. This adds them from Oracle's MySQL 8.4 repository at exactly
# the server's version, plus procps (ps/top) for incident work.
# ./lab rebuilds the image whenever this file changes.
FROM mysql:8.4.11

RUN MYSQL_VERSION="$(rpm -q --qf '%{VERSION}' mysql-community-server-minimal)" \
 && printf '%s\n' \
      '[mysql84-community]' \
      'name=MySQL 8.4 Community' \
      'baseurl=https://repo.mysql.com/yum/mysql-8.4-community/el/9/$basearch/' \
      'enabled=1' 'gpgcheck=1' \
      'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mysql' \
      'module_hotfixes=true' > /etc/yum.repos.d/mysql-community.repo \
 && microdnf install -y --setopt=install_weak_deps=0 \
      perl-interpreter perl-Getopt-Long procps-ng cpio \
 && cd /tmp \
 && microdnf download "mysql-community-client-${MYSQL_VERSION}" \
      "mysql-community-client-plugins-${MYSQL_VERSION}" \
      "mysql-community-server-${MYSQL_VERSION}" \
 # The full client package overlaps the image's server-minimal package on a
 # few identical same-version files; --replacefiles lets it install anyway.
 && rpm -i --nodeps --replacefiles mysql-community-client-[0-9]*.rpm \
      mysql-community-client-plugins-*.rpm \
 && rpm2cpio mysql-community-server-[0-9]*.rpm | (cd / && cpio -idm ./usr/bin/mysqldumpslow) \
 && microdnf clean all && rm -f /tmp/*.rpm \
 && mysqlbinlog --version && mysqlcheck --version
