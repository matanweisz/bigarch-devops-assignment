# Controller only: the Phase 5 loop. Every five minutes root's crontab submits
# a short Slurm job that reports simulated CPU/GPU/Mem load to the metrics
# gateway, feeding the "Live Slurm Job Load" dashboard.
#
# Submitted here because sbatch and slurmctld live on the controller. slurmd
# always executes it on the compute node, which is the only reading of "running
# a Slurm job on the Controller node" consistent with the Phase 1 role split
# (controller has no slurmd).

{% set cron = salt['pillar.get']('slurm:cron') %}

include:
  - slurm.common

{{ cron.install_dir }}:
  file.directory:
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - cmd: slurm-packages

{{ cron.install_dir }}/simulate_metrics.sbatch:
  file.managed:
    - source: salt://slurm/files/simulate_metrics.sbatch.j2
    - template: jinja
    - user: root
    - group: root
    # Readable is all sbatch needs on the submission host: it ships the script's
    # contents to slurmd, which writes its own executable copy on the execution
    # node.
    - mode: '0644'
    - require:
      - file: {{ cron.install_dir }}

{{ cron.install_dir }}/submit_job.sh:
  file.managed:
    - source: salt://slurm/files/submit_job.sh.j2
    - template: jinja
    - user: root
    - group: root
    # cron execs this path directly (no shell wrapping the crontab command),
    # so it has to be executable, unlike the sbatch script above.
    - mode: '0755'
    - require:
      - file: {{ cron.install_dir }}

# identifier pins this to one crontab line across highstates. Without it Salt
# matches an existing entry by its exact command text, so a pillar-driven
# schedule change would add a second line instead of replacing the first.
slurm-metrics-cron:
  cron.present:
    - name: {{ cron.install_dir }}/submit_job.sh
    - identifier: slurm-metrics-cron
    - user: root
    - minute: '{{ cron.minute }}'
    - hour: '*'
    - daymonth: '*'
    - month: '*'
    - dayweek: '*'
    - require:
      - file: {{ cron.install_dir }}/submit_job.sh
      - file: {{ cron.install_dir }}/simulate_metrics.sbatch
      - cmd: slurm-packages
