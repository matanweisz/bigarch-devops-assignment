# Controller only: the accounting database slurmdbd writes to.
#
# Salt's mysql_* states are not usable here. They need a Python MySQL driver
# importable by Salt's own bundled interpreter, which cannot see apt-installed
# modules. Idempotent SQL over the unix socket has no such dependency.

{% set db = salt['pillar.get']('slurm:db') %}

mariadb-server:
  pkg.installed:
    - name: mariadb-server
    # Same reasoning as the munge package: on a re-provision nothing has
    # refreshed the apt index. A refresh reports no state changes, so it costs
    # the idempotency proof nothing.
    - refresh: True

# Slurm's accounting schema is index-heavy and its purge queries hold locks for
# a long time on a small VM. Both values come from the SchedMD accounting guide,
# sized down for a 3GB node.
/etc/mysql/mariadb.conf.d/60-slurm.cnf:
  file.managed:
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by Salt: salt/states/mariadb/init.sls
        [mysqld]
        innodb_buffer_pool_size={{ db['innodb_buffer_pool_size'] }}
        innodb_lock_wait_timeout=900
    - require:
      - pkg: mariadb-server

mariadb:
  service.running:
    - enable: True
    - require:
      - pkg: mariadb-server
    - watch:
      - file: /etc/mysql/mariadb.conf.d/60-slurm.cnf

# Root-only because it carries the slurmdbd password from pillar. show_changes
# keeps that password out of the highstate output on the first run.
/root/slurm-db.sql:
  file.managed:
    - user: root
    - group: root
    - mode: '0600'
    - show_changes: False
    - contents: |
        CREATE DATABASE IF NOT EXISTS `{{ db['name'] }}`;
        CREATE USER IF NOT EXISTS '{{ db['user'] }}'@'localhost' IDENTIFIED BY '{{ db['password'] }}';
        ALTER USER '{{ db['user'] }}'@'localhost' IDENTIFIED BY '{{ db['password'] }}';
        GRANT ALL ON `{{ db['name'] }}`.* TO '{{ db['user'] }}'@'localhost';

# The mysql client authenticates as root over the unix socket, so no credential
# reaches a command line or a process listing.
#
# Two guards, and the state runs unless both pass: the account has to exist, and
# the SQL has to match what pillar renders today. The second is what makes a
# rotated password reach the server, since CREATE USER IF NOT EXISTS alone would
# keep the old one.
slurm-db-provisioned:
  cmd.run:
    - name: mysql < /root/slurm-db.sql && sha256sum /root/slurm-db.sql > /root/.slurm-db.applied
    - unless:
      - sha256sum -c --status /root/.slurm-db.applied
      - mysql -N -B -e "SELECT 1 FROM mysql.user WHERE User='{{ db['user'] }}' AND Host='localhost'" | grep -q 1
    - require:
      - service: mariadb
      - file: /root/slurm-db.sql
