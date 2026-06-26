# Roxabi deploy Makefile for the roxabi-postiz fork.
#
# Upstream gitroomhq/postiz-app has no Makefile — this file is Roxabi-only
# and only operates on deploy/. Never touches upstream Postiz code.
#
# Usage on M₁ (after clone):
#   make install-quadlet
#   # fill ~/.roxabi/postiz/env/postiz.env
#   make start
#
# Routine operator sync (pull units + refresh pinned image + restart app):
#   make converge
#
# Remote one-liner from devbox:
#   ssh roxabituwer 'cd ~/projects/roxabi-postiz && make converge'

QUADLET_DIR  := $(HOME)/.config/containers/systemd
QUADLET_SRC  := deploy/quadlet
POSTIZ_APP_IMAGE := $(shell grep '^Image=' $(QUADLET_SRC)/postiz-app.container | cut -d= -f2-)

INFRA_SERVICES := postiz-db.service postiz-redis.service \
                  postiz-temporal-db.service postiz-temporal-es.service
TEMPORAL_SERVICES := postiz-temporal.service postiz-temporal-ui.service
APP_SERVICES := postiz-app.service
ALL_SERVICES := $(INFRA_SERVICES) $(TEMPORAL_SERVICES) $(APP_SERVICES)

.PHONY: help install-quadlet uninstall-quadlet pull-app start stop restart status converge

help:
	@echo "Roxabi postiz deploy targets:"
	@echo "  install-quadlet    install/refresh Quadlets + daemon-reload"
	@echo "  uninstall-quadlet  remove Quadlets (data under ~/.roxabi/postiz preserved)"
	@echo "  pull-app           podman pull pinned postiz-app image"
	@echo "  start              start full stack (infra → temporal → app)"
	@echo "  stop               stop full stack"
	@echo "  restart            restart full stack"
	@echo "  status             systemctl status for all postiz units"
	@echo "  converge           git pull + install-quadlet + pull-app + restart app"

install-quadlet:
	@mkdir -p $(QUADLET_DIR)
	@for f in $(QUADLET_SRC)/*.container $(QUADLET_SRC)/*.network; do \
		install -m 644 "$$f" "$(QUADLET_DIR)/$$(basename "$$f")"; \
	done
	@systemctl --user daemon-reload
	@echo "Installed Quadlets from $(QUADLET_SRC)."

uninstall-quadlet:
	@for f in $(QUADLET_SRC)/*.container $(QUADLET_SRC)/*.network; do \
		rm -f "$(QUADLET_DIR)/$$(basename "$$f")"; \
	done
	@systemctl --user daemon-reload
	@echo "Uninstalled. ~/.roxabi/postiz/ data preserved."

pull-app:
	@echo "Pulling $(POSTIZ_APP_IMAGE)..."
	@podman pull $(POSTIZ_APP_IMAGE)

start:
	@systemctl --user start $(INFRA_SERVICES)
	@sleep 15
	@systemctl --user start postiz-temporal.service
	@sleep 30
	@systemctl --user start $(TEMPORAL_SERVICES) $(APP_SERVICES)

stop:
	@systemctl --user stop $(ALL_SERVICES) || true

restart:
	@systemctl --user restart $(ALL_SERVICES)

status:
	@systemctl --user status --no-pager $(ALL_SERVICES) || true

converge:
	@git pull --ff-only origin main
	@$(MAKE) install-quadlet
	@$(MAKE) pull-app
	@systemctl --user restart postiz-app.service
	@systemctl --user is-active --quiet postiz-app.service \
		|| { echo "ERROR: postiz-app failed to reach active state"; exit 1; }
	@echo "Converged on $(POSTIZ_APP_IMAGE)."