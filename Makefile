# layoutd — instant keyboard layout switching via Cmd+Space

BINARY   = layoutd
SOURCE   = Sources/layoutd.swift
PREFIX  ?= $(HOME)/Library/Application Support/layoutd
PLIST    = $(HOME)/Library/LaunchAgents/dev.layoutd.plist
LABEL    = dev.layoutd
LOG      = $(HOME)/Library/Logs/layoutd.log

# Layouts (Input Source IDs; list available: make list)
FIRST  ?= com.apple.keylayout.US
SECOND ?= com.apple.keylayout.Russian

# Signing certificate (Apple Development). If empty — adhoc.
# Signing with a real certificate keeps the Accessibility permission stable
# across rebuilds (adhoc binds TCC by cdhash and breaks on every rebuild).
SIGN_ID ?= 631671BFA9B4AA67648CA0B727AAC8F7A2D45384

.PHONY: all build install uninstall start stop restart status log list accessibility clean

all: build

build:
	@mkdir -p build
	swiftc -O -o build/$(BINARY) $(SOURCE)
	@if [ -n "$(SIGN_ID)" ] && security find-identity -v -p codesigning | grep -q "$(SIGN_ID)"; then \
		codesign --force --sign "$(SIGN_ID)" --identifier $(LABEL) --timestamp=none build/$(BINARY); \
		echo "signed: Apple Development $(SIGN_ID)"; \
	else \
		codesign --force --sign - --identifier $(LABEL) --timestamp=none build/$(BINARY); \
		echo "signed: adhoc (certificate not found — the Accessibility permission will break on rebuilds)"; \
	fi

install: build
	@mkdir -p "$(PREFIX)"
	cp build/$(BINARY) "$(PREFIX)/$(BINARY)"
	cp $(SOURCE) "$(PREFIX)/$(BINARY).swift"
	@sed -e "s|@PREFIX@|$(PREFIX)|g" -e "s|@LABEL@|$(LABEL)|g" -e "s|@LOG@|$(LOG)|g" \
		-e "s|@FIRST@|$(FIRST)|g" -e "s|@SECOND@|$(SECOND)|g" \
		layoutd.plist.template > $(PLIST)
	launchctl bootstrap gui/$$(id -u) $(PLIST) 2>/dev/null || launchctl kickstart -k gui/$$(id -u)/$(LABEL)
	@echo ""
	@echo "=== Installed ==="
	@echo "Binary:       $(PREFIX)/$(BINARY)"
	@echo "LaunchAgent:  $(PLIST) (Label: $(LABEL))"
	@echo "Log:          $(LOG)"
	@echo ""
	@echo "If switching does not work — grant the Accessibility permission:"
	@echo "  make accessibility   # opens the required Settings pane"
	@echo "  → «+» → ⌘⇧G → $(PREFIX)/$(BINARY)"
	@echo "  (KeepAlive restarts the agent automatically within ~10 sec)"

uninstall:
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST)
	rm -rf "$(PREFIX)"
	@echo "Removed: agent, $(PREFIX)"
	@echo "The Accessibility permission can be revoked in System Settings → Privacy & Security"

start:
	launchctl bootstrap gui/$$(id -u) $(PLIST) 2>/dev/null || launchctl kickstart -k gui/$$(id -u)/$(LABEL)

stop:
	launchctl bootout gui/$$(id -u)/$(LABEL)

restart:
	launchctl kickstart -k gui/$$(id -u)/$(LABEL)

status:
	@launchctl print gui/$$(id -u)/$(LABEL) 2>/dev/null | grep -E "^\t(state|pid)" | head -2 \
		|| echo "not running"
	@echo "--- recent events ---"
	@tail -5 $(LOG) 2>/dev/null || echo "log is empty"

log:
	tail -f $(LOG)

list: build
	build/$(BINARY) --list

accessibility:
	open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

clean:
	rm -rf build
