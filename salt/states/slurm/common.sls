# Everything the controller and the compute node share: the slurm account, name
# resolution between the two, the DEB install, and slurm.conf. Slurm requires
# slurm.conf to be identical on every node of a cluster, so one template renders
# it for both roles and both roles get it from here.

{% set net = salt['pillar.get']('net') %}
{% set version = salt['pillar.get']('slurm:version') %}
{% set slurm_uid = salt['pillar.get']('slurm:uid') %}
# Indexed rather than pillar.get: a role with no package list has to fail the
# render loudly instead of assembling an apt command with no packages in it.
{% set packages = pillar['slurm']['packages'][grains['role']] %}

include:
  - munge

slurm-group:
  group.present:
    - name: slurm
    - gid: {{ slurm_uid }}
    - system: True

# Before the DEBs, always. SchedMD's debian/ ships no maintainer scripts, so
# nothing in the packages creates this account, and the directories they unpack
# carry ownership numerically. Claiming the id from pillar first is what makes
# them resolve to the same slurm user on both nodes. The account names are fixed
# by the packaging and by slurm.conf's SlurmUser, so only the ids need pillar.
slurm-user:
  user.present:
    - name: slurm
    - uid: {{ slurm_uid }}
    - gid: {{ slurm_uid }}
    - home: /var/lib/slurm
    - shell: /usr/sbin/nologin
    - system: True
    - createhome: False
    - require:
      - group: slurm-group

# Vagrant points each node's own name at 127.0.1.1, useless to the other side of
# the cluster. slurm.conf pins the addresses too, so these entries exist to make
# sinfo, srun and scontrol output resolvable by hand.
#
# clean drops the name from every other line it appears on, the only way the
# node's own name stops resolving to loopback. Without it Salt keeps the Vagrant
# line and warns about the duplicate on every highstate.
controller-host-entry:
  host.present:
    - name: {{ net['controller_host'] }}
    - ip: {{ net['controller_ip'] }}
    - clean: True

compute-host-entry:
  host.present:
    - name: {{ net['compute_host'] }}
    - ip: {{ net['compute_ip'] }}
    - clean: True

# apt-get, never dpkg -i: apt resolves dependencies between the built packages,
# and Slurm 26.05 demoted munge to a weak dependency that dpkg would skip. The
# apt-get update in front is for the box's empty list cache.
#
# The guard compares the installed version against pillar rather than just
# asking whether the package is there, so bumping slurm:version reinstalls
# instead of keeping the old build.
slurm-packages:
  cmd.run:
    - name: >-
        apt-get update && apt-get install -y
        {%- for p in packages %} {{ salt['pillar.get']('artifacts:root') }}/debs/{{ p }}_*.deb{% endfor %}
    - env:
        - DEBIAN_FRONTEND: noninteractive
    - unless:
{%- for p in packages %}
      - dpkg-query -W -f='${Version}' {{ p }} 2>/dev/null | grep -q '^{{ version }}-'
{%- endfor %}
    - require:
      - user: slurm-user
      - sls: munge

/etc/slurm:
  file.directory:
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - cmd: slurm-packages

# slurmctld and slurmdbd run as SlurmUser and write here. slurmd runs as root
# and does not care who owns the directory.
#
# After the packages, not before: dpkg unpacks this directory root-owned, so
# chowning it first would be undone by the install.
/var/log/slurm:
  file.directory:
    - user: slurm
    - group: slurm
    - mode: '0755'
    - require:
      - user: slurm-user
      - cmd: slurm-packages

/etc/slurm/slurm.conf:
  file.managed:
    - source: salt://slurm/files/slurm.conf.j2
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: /etc/slurm

# Only the compute node's task plugin reads this, but shipping it from the
# shared state keeps /etc/slurm identical everywhere.
/etc/slurm/cgroup.conf:
  file.managed:
    - source: salt://slurm/files/cgroup.conf
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: /etc/slurm
