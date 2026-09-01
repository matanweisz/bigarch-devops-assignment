.PHONY: up verify provision destroy

# Boots builder, controller and compute in that order. The builder halts itself.
up:
	vagrant up

verify:
	scripts/verify.sh

# For iterating on Salt states. Synced folders are rsync, which only syncs on
# up/reload, so the states have to be pushed before a highstate can see them.
# The controller runs only its "highstate" shell provisioner here: re-running its
# salt provisioner would reinstall the master for nothing. Compute has a single
# provisioner and it already ends in a highstate.
provision:
	vagrant rsync controller
	vagrant rsync compute
	vagrant provision controller --provision-with highstate
	vagrant provision compute

destroy:
	vagrant destroy -f
