SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help check-host normal-image compact-iso wifi-iso all test test-static test-qemu clean

help:
	@printf '%s\n' \
	  'MicroUbuntu reproducible image builder' \
	  '' \
	  '  make test          Run non-destructive source/unit tests' \
	  '  make check-host    Verify privileged Linux build capabilities' \
	  '  make normal-image  Build the persistent amd64 raw image' \
	  '  make compact-iso   Build the compact network bootstrap ISO' \
	  '  make wifi-iso      Build the Wi-Fi ISO (includes the raw image)' \
	  '  make all           Build and test every deliverable' \
	  '  make test-qemu     Boot already-built deliverables in QEMU' \
	  '' \
	  'Image-building targets require root and the packages listed in README.md.'

check-host:
	sudo -E ./scripts/check-build-host.sh

normal-image:
	sudo -E ./scripts/build-normal-image.sh

compact-iso: normal-image
	sudo -E ./scripts/build-iso.sh compact

wifi-iso: normal-image
	sudo -E ./scripts/build-iso.sh wifi

all:
	sudo -E ./scripts/build-all.sh

test: test-static

test-static:
	./tests/run-static-tests.sh

# QEMU is deliberately separate so source tests remain usable on any machine.
test-qemu:
	sudo -E ./tests/test-qemu.sh

clean:
	sudo rm -rf build
