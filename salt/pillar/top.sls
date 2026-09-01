base:
  '*':
    - common
  # Secrets go only to the nodes whose states consume them; the builder needs
  # neither the DB password nor the munge key. (Compute needs the munge key;
  # the DB password rides along because both live in one generated file.)
  'role:controller':
    - match: grain
    - secrets
  'role:compute':
    - match: grain
    - secrets
