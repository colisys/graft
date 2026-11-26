SHELL := /bin/bash

CONFIG ?= release
UNIVERSAL ?= 1
INSTALL_DIR ?= $(HOME)/Applications
PURGE ?= 0

.PHONY: all build test app install uninstall run clean

all: test app

build:
	swift build -c $(CONFIG)

test:
	swift test

app:
	GRAFT_UNIVERSAL=$(UNIVERSAL) ./scripts/build-app.sh $(CONFIG)

install: app
	INSTALL_DIR="$(INSTALL_DIR)" ./scripts/install.sh

uninstall:
	INSTALL_DIR="$(INSTALL_DIR)" PURGE=$(PURGE) ./scripts/uninstall.sh

run: app
	open "dist/Graft.app"

clean:
	swift package clean
	rm -rf dist
