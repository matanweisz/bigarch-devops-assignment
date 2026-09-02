base:
  '*':
    - common
  # Secrets go only to the nodes whose states consume them, and the builder
  # needs neither. Compute needs the munge key, and the DB password rides along
  # because both live in one generated file.
  'role:controller':
    - match: grain
    - secrets
  'role:compute':
    - match: grain
    - secrets
