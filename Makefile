# project: fuji-sync
# code generator: ChatGPT
# author: kodweis@gmail.com
PREFIX ?= $(HOME)/.local
BINDIR = $(PREFIX)/bin
UNITDIR = $(PREFIX)/share/systemd/user
CONFDIR = $(PREFIX)/etc/fuji-auto-sync

install:
	@echo "📦 Installing Fuji Auto-Sync (gphotofs edition)..."
	mkdir -p $(BINDIR) $(UNITDIR) $(CONFDIR)
	install -m 755 fuji_watcher.sh $(BINDIR)/
	install -m 644 fuji-sync.service $(UNITDIR)/
	# Reference config (overwrite)
	install -m 644 fuji-sync.conf.ref $(CONFDIR)/
	# Ensure editable exists and contains all keys
	install -m 755 scripts/merge_conf.sh $(CONFDIR)/merge_conf.sh
	$(CONFDIR)/merge_conf.sh $(CONFDIR)/fuji-sync.conf.ref $(CONFDIR)/fuji-sync.conf
	# Version (reference)
	install -m 644 VERSION $(CONFDIR)/
	@systemctl --user daemon-reload
	@systemctl --user enable fuji-sync.service
	@systemctl --user restart fuji-sync.service
	@echo "✅ Installed and service restarted."
	@echo "👉 Editable config:   $(CONFDIR)/fuji-sync.conf"
	@echo "👉 Reference config:  $(CONFDIR)/fuji-sync.conf.ref"
	@echo "👉 Check logs:        journalctl --user -u fuji-sync.service -f"

uninstall:
	@echo "🗑 Removing Fuji Auto-Sync (keeping your editable config)..."
	systemctl --user stop fuji-sync.service || true
	systemctl --user disable fuji-sync.service || true
	rm -f $(BINDIR)/fuji_watcher.sh
	rm -f $(UNITDIR)/fuji-sync.service
	rm -f $(CONFDIR)/fuji-sync.conf.ref
	rm -f $(CONFDIR)/merge_conf.sh
	rm -f $(CONFDIR)/VERSION
	@systemctl --user daemon-reload
	@echo "✅ Uninstalled. Kept: $(CONFDIR)/fuji-sync.conf"
