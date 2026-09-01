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

# Before the DEBs, always. The packages create the account themselves if it is
# missing, each node picking its own free id, and the state directories they lay
# down would then be owned by different users on the two nodes.
#
# The account names are fixed by the Debian packaging and by slurm.conf's
# SlurmUser; only the numeric ids have to agree across nodes, which is what
# pillar carries.
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

# Vagrant points each node's own name at 127.0.1.1, which is useless to the other
# side of the cluster. slurm.conf pins the addresses explicitly as well; these
# entries are what make sinfo, srun and scontrol output resolvable by hand.
controller-host-entry:
  host.present:
    - name: {{ net['controller_host'] }}
    - ip: {{ net['controller_ip'] }}

compute-host-entry:
  host.present:
    - name: {{ net['compute_host'] }}
    - ip: {{ net['compute_ip'] }}

# apt-get, never dpkg -i: apt resolves the dependencies between the built
# packages, and Slurm 26.05 demoted munge to a weak dependency that dpkg would
# skip. The apt-get update in front is for the box's empty list cache and only
# runs on the same occasions the install does.
#
# The guard compares the installed version against pillar rather than just
# asking whether the package is there, so bumping slurm:version reinstalls
# instead of silently keeping the old build.
slurm-packages:
  cmd.run:
    - name: >-
        apt-get update && apt-get install -y
        {%- for p in packages %} /vagrant/artifacts/debs/{{ p }}_*.deb{% endfor %}
    - env:
        - DEBIAN_FRONTEND: noninteractive
    - unless:
{%- for p in packages %}
      - dpkg-query -W -f='${Version}' {{ p }} 2>/dev/null | grep -q '^{{ version }}'
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

# slurmctld and slurmdbd run as SlurmUser and write here; slurmd runs as root
# and does not care who owns the directory.
/var/log/slurm:
  file.directory:
    - user: slurm
    - group: slurm
    - mode: '0755'
    - require:
      - user: slurm-user

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
# shared state keeps /etc/slurm identical everywhere, which is one less thing to
# rule out when a job lands wrong.
/etc/slurm/cgroup.conf:
  file.managed:
    - source: salt://slurm/files/cgroup.conf
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: /etc/slurm
