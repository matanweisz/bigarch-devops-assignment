# -*- mode: ruby -*-
# vi: set ft=ruby :

require "yaml"

# Salt pillar is the source of truth for every value a guest reads. The
# Vagrantfile parses that same file instead of restating the addresses, so the
# host-side network config cannot drift from what the states configure in-guest.
# This parse is why common.sls must stay plain YAML: no Jinja, ever.
PILLAR = YAML.load_file(File.expand_path("salt/pillar/common.sls", __dir__))

# RAM and CPU are host-side sizing that no state reads, so they live here. The
# builder's address does too: it is ephemeral and nothing in-guest addresses it,
# which is why pillar carries only the controller and compute addresses.
NODES = {
  "builder"    => { ip: "192.168.56.5",                 cpus: 6, memory: 4096 },
  "controller" => { ip: PILLAR["net"]["controller_ip"], cpus: 2, memory: 3072 },
  "compute"    => { ip: PILLAR["net"]["compute_ip"],    cpus: 4, memory: 6144 },
}.freeze

BOX = "bento/ubuntu-24.04".freeze
# Pinned: an unpinned box makes "works on my machine" unfalsifiable, and this
# version is the one the whole build was verified against on arm64 and amd64.
BOX_VERSION = "202510.26.0".freeze

# Salt 3008 LTS. The salt provisioner appends install_type and install_args to
# the salt-bootstrap command line verbatim, which is exactly where that project
# expects its positional `stable <major>` selector.
SALT_INSTALL_TYPE = "stable".freeze
SALT_INSTALL_ARGS = "3008".freeze
# Vagrant defaults salt-call to --log-level=debug, which buries every state
# result under loader chatter.
SALT_LOG_LEVEL = "info".freeze

BUILD_STAMP = File.expand_path("artifacts/BUILD_STAMP", __dir__).freeze

# Checkout noise no guest needs. Excluding it keeps every up/rsync cheap; the
# builder additionally excludes artifacts/ because it produces them.
RSYNC_EXCLUDE = [
  ".git/", ".superpowers/", ".claude/", "study/",
  "gateway/.venv/", "__pycache__/", ".pytest_cache/",
].freeze

# Settings identical on every node: address, the one-way repo share, and the two
# provider sizings. Synced folders are rsync everywhere on purpose - see
# CLAUDE.md decision 4 for why NFS is off the table on macOS.
def base_config(vm, name, excludes)
  node = NODES.fetch(name)
  vm.hostname = name
  vm.network "private_network", ip: node[:ip]
  vm.synced_folder ".", "/vagrant", type: "rsync", rsync__exclude: excludes

  vm.provider "virtualbox" do |vb|
    vb.cpus = node[:cpus]
    vb.memory = node[:memory]
  end

  vm.provider "vmware_desktop" do |v|
    v.vmx["numvcpus"] = node[:cpus].to_s
    v.vmx["memsize"] = node[:memory].to_s
  end
end

# Controller and compute install the DEBs and container images the builder
# produced. Without them provisioning dies deep inside a Salt state with an
# unhelpful message, so fail before the box even boots and name the fix.
#
# Both :up and :provision: `vagrant up` on a never-created machine is the path
# users actually take, and whether it fires the nested :provision trigger is
# version-dependent. Gating :up too makes the check fire before the box import.
def require_artifacts(node)
  node.trigger.before [:up, :provision] do |t|
    t.name = "require builder artifacts"
    t.ruby do |_env, _machine|
      next if File.exist?(BUILD_STAMP)

      # abort, not raise: nothing has happened yet that needs unwinding, and a
      # bare raise here makes Vagrant print a Ruby backtrace over the message.
      abort "artifacts/BUILD_STAMP is missing: the builder has not produced " \
            "the Slurm DEBs and container images yet. Run `vagrant up builder` first."
    end
  end
end

Vagrant.configure("2") do |config|
  config.vm.box = BOX
  config.vm.box_version = BOX_VERSION

  # Pillar carries the slurmdbd password and the munge key. Generated once on the
  # host so every node gets identical values; the script is a no-op if they exist.
  config.trigger.before :up do |t|
    t.name = "generate pillar secrets"
    t.run = { path: "scripts/gen-secrets.sh" }
  end

  # Definition order is boot order, and it is also the dependency order: the
  # builder must produce artifacts before the other two can be provisioned.
  config.vm.define "builder" do |builder|
    base_config(builder.vm, "builder", RSYNC_EXCLUDE + ["artifacts/"])

    # Masterless: the builder is thrown away, so standing up key exchange with
    # the controller's master would buy nothing. It applies the same podman sls
    # the controller does, which is the point of the no-duplication criterion.
    builder.vm.provision :salt do |salt|
      salt.masterless = true
      salt.minion_id = "builder"
      salt.minion_config = "salt/minion.builder.conf"
      salt.run_highstate = true
      salt.verbose = true
      salt.log_level = SALT_LOG_LEVEL
      salt.install_type = SALT_INSTALL_TYPE
      salt.install_args = SALT_INSTALL_ARGS
      # The masterless path already passes --retcode-passthrough, so a failed
      # state fails the provisioner. This only makes the output readable.
      salt.salt_call_args = ["--state-output=mixed"]
    end

    # Scoped to this define so it never fires for controller or compute.
    builder.trigger.after :up do |t|
      t.name = "pull artifacts from builder and power it off"
      t.run = { path: "scripts/pull-artifacts.sh" }
    end
  end

  config.vm.define "controller" do |controller|
    base_config(controller.vm, "controller", RSYNC_EXCLUDE)
    require_artifacts(controller)

    # The .conf suffixes on the config files matter: the salt provisioner treats
    # bare salt/master and salt/minion as optimistic defaults and would upload
    # them to nodes that must not have them.
    #
    # install_master with run_highstate is refused by Vagrant unless minion keys
    # are pre-seeded, and its master-mode highstate does not propagate state
    # failures anyway. Hence run_highstate false plus the shell step below.
    # See CLAUDE.md decision 2.
    controller.vm.provision :salt do |salt|
      salt.install_master = true
      salt.master_config = "salt/master.conf"
      salt.minion_config = "salt/minion.controller.conf"
      salt.minion_id = "controller"
      salt.run_highstate = false
      salt.verbose = true
      salt.log_level = SALT_LOG_LEVEL
      salt.install_type = SALT_INSTALL_TYPE
      salt.install_args = SALT_INSTALL_ARGS
    end

    controller.vm.provision :shell,
      name: "highstate",
      inline: "salt-call state.highstate --retcode-passthrough --state-output=mixed"
  end

  config.vm.define "compute" do |compute|
    base_config(compute.vm, "compute", RSYNC_EXCLUDE)
    require_artifacts(compute)

    compute.vm.provision :salt do |salt|
      salt.minion_config = "salt/minion.compute.conf"
      salt.minion_id = "compute"
      salt.run_highstate = true
      salt.verbose = true
      salt.log_level = SALT_LOG_LEVEL
      salt.install_type = SALT_INSTALL_TYPE
      salt.install_args = SALT_INSTALL_ARGS
    end
  end
end
