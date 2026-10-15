SHELL := /bin/bash

.PHONY: help install-deps net networks gen build up down reset ps logs health healthcheck smoke dns dns-down

# KAGE-MAN.DOJO — a self-contained Metasploit practice range.
# All targets operate on this repository; no environment variables required.
#
# Examples:
#   make install-deps            # once per host: docker + seccomp + compose + make
#   sudo make net                # static NICs + promisc + macvlan networks
#   make gen                     # regenerate <app>__<cve>/docker-compose.yml
#   make up                      # start every lab
#   make up LAB=activemq         # start only matching lab(s)
#   make health                  # container/network/mount check
#   make smoke                   # endpoint probes from the segments

help:
	@echo "KAGE-MAN.DOJO — make targets"
	@echo "  make install-deps       docker + seccomp + compose + make (once per host)"
	@echo "  sudo make net           static IPs + promisc + macvlan networks"
	@echo "  make gen                regenerate lab composes from labs.manifest"
	@echo "  make build|up|down      compose lifecycle (LAB=<filter> to narrow)"
	@echo "  make reset              stop labs AND delete their volumes"
	@echo "  make ps | make logs     running labs / recent logs"
	@echo "  make dns | make dns-down WAN resolver (fake internet names, 10.0.8.53)"
	@echo "  make health             container + network + mount healthcheck"
	@echo "  make smoke              endpoint probes from inside the segments"
	@echo
	@echo "  Example: make up LAB=activemq   |   make down   |   make smoke struts2"

install-deps:
	sudo ./scripts/install-deps.sh

net networks:
	sudo ./scripts/network-setup.sh

gen:
	./scripts/gen-labs.sh

build:
	./scripts/labs.sh build $(LAB)

up:
	./scripts/labs.sh up $(LAB)

down:
	./scripts/labs.sh down $(LAB)

reset:
	./scripts/labs.sh reset $(LAB)

ps:
	./scripts/labs.sh ps

logs:
	./scripts/labs.sh logs $(LAB)

health healthcheck:
	./scripts/healthcheck.sh $(LAB)

smoke:
	./scripts/smoke-test.sh $(LAB)

dns:
	./scripts/labs.sh up dns

dns-down:
	./scripts/labs.sh down dns
