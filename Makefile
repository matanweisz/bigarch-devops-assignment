.PHONY: up verify test provision destroy help

# Boots builder, controller and compute in that order. The builder halts itself.
up:
	vagrant up

verify:
	scripts/verify.sh

# Host-side unit tests for the metrics gateway. No VM needed.
test:
	cd gateway && python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt pytest && .venv/bin/pytest -q

# For iterating on Salt states. Rsync folders only sync on up and reload, so
# states have to be pushed before a highstate can see them. The controller runs
# only its "highstate" shell provisioner, because re-running its salt
# provisioner would reinstall the master for nothing.
provision:
	vagrant rsync controller
	vagrant rsync compute
	vagrant provision controller --provision-with highstate
	vagrant provision compute

destroy:
	vagrant destroy -f

help:
	@echo "up         boot the whole lab, the builder halts itself when done"
	@echo "verify     host-side smoke test of the running lab"
	@echo "test       gateway unit tests in a local venv, no VM needed"
	@echo "provision  rsync states to the guests and re-run both highstates"
	@echo "destroy    tear the whole lab down"
