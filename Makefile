PREFIX ?= /usr/local
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib
MANDIR ?= $(PREFIX)/share/man

PLATFORMFILE := src/platform/$(shell uname | cut -d _ -f 1 | tr '[:upper:]' '[:lower:]').sh

BASHCOMPDIR ?= $(PREFIX)/share/bash-completion/completions
ZSHCOMPDIR ?= $(PREFIX)/share/zsh/site-functions
FISHCOMPDIR ?= $(PREFIX)/share/fish/vendor_completions.d

ifneq ($(WITH_ALLCOMP),)
WITH_BASHCOMP := $(WITH_ALLCOMP)
WITH_ZSHCOMP := $(WITH_ALLCOMP)
WITH_FISHCOMP := $(WITH_ALLCOMP)
endif
ifeq ($(WITH_BASHCOMP),)
ifneq ($(strip $(wildcard $(BASHCOMPDIR))),)
WITH_BASHCOMP := yes
endif
endif
ifeq ($(WITH_ZSHCOMP),)
ifneq ($(strip $(wildcard $(ZSHCOMPDIR))),)
WITH_ZSHCOMP := yes
endif
endif
ifeq ($(WITH_FISHCOMP),)
ifneq ($(strip $(wildcard $(FISHCOMPDIR))),)
WITH_FISHCOMP := yes
endif
endif

all:
	@echo '`note` is a shell script, so there is nothing to do. Try "make install" instead.'

install-common:
	@install -v -d "$(DESTDIR)$(MANDIR)/man1" && install -m 0644 -v man/note.1 "$(DESTDIR)$(MANDIR)/man1/note.1"
	@[ "$(WITH_BASHCOMP)" = "yes" ] || exit 0; install -v -d "$(DESTDIR)$(BASHCOMPDIR)" && install -m 0644 -v src/completion/note.bash-completion "$(DESTDIR)$(BASHCOMPDIR)/note"
	@[ "$(WITH_ZSHCOMP)" = "yes" ] || exit 0; install -v -d "$(DESTDIR)$(ZSHCOMPDIR)" && install -m 0644 -v src/completion/note.zsh-completion "$(DESTDIR)$(ZSHCOMPDIR)/_note"
	@[ "$(WITH_FISHCOMP)" = "yes" ] || exit 0; install -v -d "$(DESTDIR)$(FISHCOMPDIR)" && install -m 0644 -v src/completion/note.fish-completion "$(DESTDIR)$(FISHCOMPDIR)/note.fish"


ifneq ($(strip $(wildcard $(PLATFORMFILE))),)
install: install-common
	@install -v -d "$(DESTDIR)$(LIBDIR)/note-store" && install -m 0644 -v "$(PLATFORMFILE)" "$(DESTDIR)$(LIBDIR)/note-store/platform.sh"
	@install -v -d "$(DESTDIR)$(LIBDIR)/note-store/extensions"
	@install -v -d "$(DESTDIR)$(BINDIR)/"
	@trap 'rm -f src/.note' EXIT; sed 's:.*PLATFORM_FUNCTION_FILE.*:source "$(LIBDIR)/note-store/platform.sh":;s:^SYSTEM_EXTENSION_DIR=.*:SYSTEM_EXTENSION_DIR="$(LIBDIR)/note-store/extensions":' src/note-store.sh > src/.note && \
	install -v -d "$(DESTDIR)$(BINDIR)/" && install -m 0755 -v src/.note "$(DESTDIR)$(BINDIR)/note"
else
install: install-common
	@install -v -d "$(DESTDIR)$(LIBDIR)/note-store/extensions"
	@trap 'rm -f src/.note' EXIT; sed '/PLATFORM_FUNCTION_FILE/d;s:^SYSTEM_EXTENSION_DIR=.*:SYSTEM_EXTENSION_DIR="$(LIBDIR)/note-store/extensions":' src/note-store.sh > src/.note && \
	install -v -d "$(DESTDIR)$(BINDIR)/" && install -m 0755 -v src/.note "$(DESTDIR)$(BINDIR)/note"
endif

uninstall:
	@rm -vrf \
		"$(DESTDIR)$(BINDIR)/note" \
		"$(DESTDIR)$(LIBDIR)/note-store" \
		"$(DESTDIR)$(MANDIR)/man1/note.1" \
		"$(DESTDIR)$(BASHCOMPDIR)/note" \
		"$(DESTDIR)$(ZSHCOMPDIR)/_note" \
		"$(DESTDIR)$(FISHCOMPDIR)/note.fish"

TESTS = $(sort $(wildcard tests/t[0-9][0-9][0-9][0-9]-*.sh))

test: $(TESTS)

$(TESTS):
	@$@ $(PASS_TEST_OPTS)

clean:
	$(RM) -rf tests/test-results/ tests/trash\ directory.*/ tests/gnupg/random_seed

.PHONY: install uninstall install-common test clean $(TESTS)
