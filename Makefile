DEB_ARCH ?= all
DEB_PACKAGE_VERSION ?=
RELEASE_DIR ?= release
TAG_PREFIX ?= idle-shutdown-v
TAG ?=
TAG_CREATE ?= 1
PACKAGE_VERSION ?= $(shell dpkg-parsechangelog -S Version 2>/dev/null || head -n 1 debian/changelog | cut -d'(' -f2 | cut -d')' -f1)
TAG_VERSION ?= $(shell printf '%s' "$(PACKAGE_VERSION)" | sed -E 's/-[^-]+$$//')
TAG_RESULT_FILE ?=

IDLE_SHUTDOWN_SCRIPT ?= ./idle-shutdown.sh
IDLE_SHUTDOWN_EXPORTER ?= ./export-idle-shutdown-assets.py
IDLE_SHUTDOWN_SMOKE_TEST ?= ./test/idle-shutdown-smoke.sh

STAMP_CREATE_UTC ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
STAMP_IDLE_SHUTDOWN_SHA256 ?= $(shell if [ -f "$(IDLE_SHUTDOWN_SCRIPT)" ]; then sha256sum "$(IDLE_SHUTDOWN_SCRIPT)" | awk '{print $$1}'; else echo unknown; fi)
STAMP_EXPORTER_SHA256 ?= $(shell if [ -f "$(IDLE_SHUTDOWN_EXPORTER)" ]; then sha256sum "$(IDLE_SHUTDOWN_EXPORTER)" | awk '{print $$1}'; else echo unknown; fi)

.PHONY: help check idle-smoke \
	deb-build deb-build-all \
	deb-smoke deb-smoke-all \
	release tag-build tag-show tag-show-raw tag-list

help:
	@echo "Targets:" \
	&& echo "  make check             Run local syntax/smoke checks" \
	&& echo "  make deb-build         Build Debian package for DEB_ARCH ($(DEB_ARCH), expected: all)" \
	&& echo "  make deb-smoke         Build + validate package payload for DEB_ARCH (all)" \
	&& echo "  make release           Resolve tag/version, run check + deb-smoke (all), then tag-build" \
	&& echo "  make tag-build         Create/reuse annotated release tag (auto-increment if needed)" \
	&& echo "  make tag-show          Show parsed tag metadata (default latest)" \
	&& echo "  make tag-show-raw      Show raw annotated tag object" \
	&& echo "  make tag-list          List release tags" \
	&& echo "" \
	&& echo "Variables:" \
	&& echo "  DEB_ARCH=$(DEB_ARCH)" \
	&& echo "  DEB_PACKAGE_VERSION=$(if $(strip $(DEB_PACKAGE_VERSION)),<set>,<empty>)" \
	&& echo "  RELEASE_DIR=$(RELEASE_DIR)" \
	&& echo "  TAG_PREFIX=$(TAG_PREFIX)"

check:
	@python3 -m py_compile "$(IDLE_SHUTDOWN_EXPORTER)"
	@bash -n "$(IDLE_SHUTDOWN_SCRIPT)"
	@bash -n debian/idle-shutdown.postinst
	@bash -n debian/idle-shutdown.prerm
	@bash "$(IDLE_SHUTDOWN_SMOKE_TEST)"

idle-smoke:
	@bash "$(IDLE_SHUTDOWN_SMOKE_TEST)"

deb-build:
	@set -eu; \
	arch="$(strip $(DEB_ARCH))"; \
	override_ver="$(strip $(DEB_PACKAGE_VERSION))"; \
	pkg_ver="$$(dpkg-parsechangelog -S Version 2>/dev/null || head -n 1 debian/changelog | cut -d'(' -f2 | cut -d')' -f1)"; \
	changelog_ver="$$pkg_ver"; \
	changelog_backup="$$(mktemp)"; \
	restore_changelog=0; \
	cp debian/changelog "$$changelog_backup"; \
	trap 'if [ "$$restore_changelog" = "1" ]; then cp "$$changelog_backup" debian/changelog; fi; rm -f -- "$$changelog_backup"' EXIT INT TERM; \
	case "$$arch" in all) : ;; *) echo "[ERROR] Unsupported DEB_ARCH=$$arch (expected: all)"; exit 2 ;; esac; \
	if [ -z "$$pkg_ver" ]; then echo "[ERROR] Could not resolve package version from debian/changelog"; exit 2; fi; \
	if [ -n "$$override_ver" ] && [ "$$override_ver" != "$$pkg_ver" ]; then \
		source_pkg="$$(dpkg-parsechangelog -S Source 2>/dev/null || echo idle-shutdown)"; \
		maintainer="$$(dpkg-parsechangelog -S Maintainer 2>/dev/null || echo 'codex <codex@local>')"; \
		now_rfc2822="$$(LC_ALL=C date -R)"; \
		tmp_changelog="$$(mktemp)"; \
		{ \
			printf '%s (%s) unstable; urgency=medium\n\n' "$$source_pkg" "$$override_ver"; \
			printf '  * Automated release build: sync package version with release tag.\n\n'; \
			printf ' -- %s  %s\n\n' "$$maintainer" "$$now_rfc2822"; \
			cat debian/changelog; \
		} >"$$tmp_changelog"; \
		mv "$$tmp_changelog" debian/changelog; \
		restore_changelog=1; \
		pkg_ver="$$override_ver"; \
		echo "[INFO] Using DEB_PACKAGE_VERSION override: $$pkg_ver"; \
	fi; \
	if [ -n "$$override_ver" ] && [ "$$override_ver" = "$$changelog_ver" ]; then \
		echo "[INFO] DEB_PACKAGE_VERSION already matches changelog: $$pkg_ver"; \
	fi; \
	echo "[INFO] Building Debian package: idle-shutdown ($$arch)"; \
	dpkg-buildpackage -us -uc -A; \
	mkdir -p "$(RELEASE_DIR)"; \
	for ext in deb changes buildinfo; do \
		src="../idle-shutdown_$${pkg_ver}_$${arch}.$$ext"; \
		if [ -f "$$src" ]; then \
			mv -f -- "$$src" "$(RELEASE_DIR)/"; \
		fi; \
	done; \
	if [ ! -f "$(RELEASE_DIR)/idle-shutdown_$${pkg_ver}_$${arch}.deb" ]; then \
		echo "[ERROR] Build did not produce expected package: $(RELEASE_DIR)/idle-shutdown_$${pkg_ver}_$${arch}.deb"; \
		exit 2; \
	fi; \
	echo "[OK] Build complete: $(RELEASE_DIR)/idle-shutdown_$${pkg_ver}_$${arch}.deb"

deb-build-all:
	@$(MAKE) DEB_ARCH=all deb-build

deb-smoke:
	@set -eu; \
	arch="$(strip $(DEB_ARCH))"; \
	case "$$arch" in all) : ;; *) echo "[ERROR] Unsupported DEB_ARCH=$$arch (expected: all)"; exit 2 ;; esac; \
	echo "[INFO] Building package before smoke test ($$arch)"; \
	$(MAKE) DEB_ARCH="$$arch" deb-build; \
	pkg="$$(ls -1t "$(RELEASE_DIR)"/idle-shutdown_*_$${arch}.deb 2>/dev/null | head -n 1 || true)"; \
	if [ -z "$$pkg" ]; then \
		echo "[ERROR] Could not find built package for $$arch."; \
		exit 2; \
	fi; \
	echo "[INFO] Smoke-testing package: $$pkg"; \
	pkg_name="$$(dpkg-deb -f "$$pkg" Package 2>/dev/null || true)"; \
	pkg_arch="$$(dpkg-deb -f "$$pkg" Architecture 2>/dev/null || true)"; \
	if [ "$$pkg_name" != "idle-shutdown" ]; then \
		echo "[ERROR] Unexpected package name: $$pkg_name (expected: idle-shutdown)"; \
		exit 2; \
	fi; \
	if [ "$$pkg_arch" != "$$arch" ]; then \
		echo "[ERROR] Package architecture mismatch: $$pkg_arch (expected: $$arch)"; \
		exit 2; \
	fi; \
	tmp_dir="$$(mktemp -d)"; \
	trap 'rm -rf -- "$$tmp_dir"' EXIT INT TERM; \
	dpkg-deb -x "$$pkg" "$$tmp_dir/rootfs"; \
	dpkg-deb -e "$$pkg" "$$tmp_dir/control"; \
	for rel in \
		etc/default/idle-shutdown \
		etc/profile.d/idle-terminal-activity.sh \
		etc/systemd/system/idle-shutdown.service \
		etc/systemd/system/idle-shutdown.timer \
		etc/systemd/system/idle-rdp-disconnect-watch.service \
		etc/systemd/system/idle-ssh-disconnect-watch.service \
		etc/idle-shutdown-git-rev \
		etc/xdg/autostart/idle-rdp-input-watch.desktop \
		usr/local/sbin/idle-shutdown.sh \
		usr/local/sbin/idle-rdp-input-watch.sh \
		usr/local/sbin/idle-rdp-disconnect-watch.sh \
		usr/local/sbin/idle-ssh-disconnect-watch.sh \
	; do \
		if [ ! -e "$$tmp_dir/rootfs/$$rel" ]; then \
			echo "[ERROR] Missing payload file: $$rel"; \
			exit 2; \
		fi; \
	done; \
	for maint in postinst prerm; do \
		if [ ! -f "$$tmp_dir/control/$$maint" ]; then \
			echo "[ERROR] Missing maintainer script: $$maint"; \
			exit 2; \
		fi; \
		sh -n "$$tmp_dir/control/$$maint"; \
	done; \
	if [ -f "$$tmp_dir/control/postrm" ]; then \
		sh -n "$$tmp_dir/control/postrm"; \
	fi; \
	echo "[OK] Smoke test passed: $$pkg"

deb-smoke-all:
	@$(MAKE) DEB_ARCH=all deb-smoke

release:
	@tag_file="$$(mktemp)"; \
	trap 'rm -f -- "$$tag_file"' EXIT INT TERM; \
	echo "[INFO] Release step 1/4: resolve release tag/version"; \
	$(MAKE) TAG_CREATE=0 TAG_RESULT_FILE="$$tag_file" tag-build >/dev/null; \
	release_tag="$$(cat "$$tag_file" 2>/dev/null || true)"; \
	if [ -z "$$release_tag" ]; then \
		echo "[ERROR] Could not resolve release tag."; \
		exit 2; \
	fi; \
	release_upstream="$${release_tag#$(TAG_PREFIX)}"; \
	if [ -z "$$release_upstream" ] || [ "$$release_upstream" = "$$release_tag" ]; then \
		echo "[ERROR] Resolved tag does not match TAG_PREFIX ($(TAG_PREFIX)): $$release_tag"; \
		exit 2; \
	fi; \
	release_pkg_ver="$$release_upstream-1"; \
	echo "[INFO] Resolved release tag: $$release_tag"; \
	echo "[INFO] Synced Debian package version: $$release_pkg_ver"; \
	echo "[INFO] Release step 2/4: check"; \
	$(MAKE) check; \
	echo "[INFO] Release step 3/4: deb-smoke all"; \
	$(MAKE) DEB_ARCH=all DEB_PACKAGE_VERSION="$$release_pkg_ver" deb-smoke; \
	echo "[INFO] Release step 4/4: tag-build"; \
	$(MAKE) TAG="$$release_tag" PACKAGE_VERSION="$$release_pkg_ver" TAG_VERSION="$$release_upstream" tag-build; \
	echo "[OK] Release completed locally."; \
	echo "[NEXT] Push commit and tags:"; \
	echo "  git push origin main --follow-tags"

tag-build:
	@pkg_ver="$(strip $(PACKAGE_VERSION))"; \
	tag_ver="$(strip $(TAG_VERSION))"; \
	tag_create="$(strip $(TAG_CREATE))"; \
	t="$(strip $(TAG))"; \
	explicit_tag=0; \
	case "$$tag_create" in 1|0) : ;; *) echo "[ERROR] TAG_CREATE must be 0 or 1 (got: $$tag_create)"; exit 2 ;; esac; \
	if [ -n "$$t" ]; then explicit_tag=1; fi; \
	manifest="$$(mktemp)"; \
	msg="$$(mktemp)"; \
	keyfiles="$$(mktemp)"; \
	trap 'rm -f -- "$$manifest" "$$msg" "$$keyfiles"' EXIT INT TERM; \
	git ls-files | awk '/\.(sh|py|awk|ps1)$$/{print}' | LC_ALL=C sort >"$$keyfiles"; \
	if [ ! -s "$$keyfiles" ]; then \
		echo "[ERROR] No key files found (.sh/.py/.awk/.ps1)."; \
		exit 2; \
	fi; \
	{ \
		while IFS= read -r f; do \
			full_commit="$$(git log -n 1 --format=%H -- "$$f" 2>/dev/null || true)"; \
			if [ -z "$$full_commit" ]; then full_commit="UNTRACKED"; fi; \
			printf '%s\t%s\n' "$$full_commit" "$$f"; \
		done <"$$keyfiles"; \
	} | LC_ALL=C sort >"$$manifest"; \
	identifier="$$(sha256sum "$$manifest" | awk '{print $$1}')"; \
	if [ -z "$$pkg_ver" ]; then \
		echo "[ERROR] PACKAGE_VERSION is empty (cannot derive from debian/changelog)."; \
		exit 2; \
	fi; \
	if [ -z "$$tag_ver" ]; then \
		echo "[ERROR] TAG_VERSION is empty (derived from PACKAGE_VERSION=$$pkg_ver)."; \
		exit 2; \
	fi; \
	head_commit="$$(git rev-parse HEAD^{})"; \
	if [ -z "$$t" ]; then \
		t="$(TAG_PREFIX)$$tag_ver"; \
	fi; \
	if [ "$$explicit_tag" -eq 0 ]; then \
		while git rev-parse -q --verify "refs/tags/$$t" >/dev/null 2>&1; do \
			tag_commit="$$(git rev-parse "$$t^{}")"; \
			if [ "$$tag_commit" = "$$head_commit" ]; then \
				break; \
			fi; \
			cur_ver="$${t#$(TAG_PREFIX)}"; \
			case "$$cur_ver" in \
				*.*.*) \
					major="$${cur_ver%%.*}"; \
					rest="$${cur_ver#*.}"; \
					minor="$${rest%%.*}"; \
					patch="$${rest##*.}"; \
					case "$$major.$$minor.$$patch" in \
						*[!0-9.]*|*..*) \
							echo "[ERROR] Cannot auto-increment TAG_VERSION=$$cur_ver; set TAG=... explicitly."; \
							exit 2; \
							;; \
					esac; \
					next_ver="$$major.$$minor.$$((patch + 1))"; \
					;; \
				*.*) \
					major="$${cur_ver%%.*}"; \
					minor="$${cur_ver##*.}"; \
					case "$$major.$$minor" in \
						*[!0-9.]*|*..*) \
							echo "[ERROR] Cannot auto-increment TAG_VERSION=$$cur_ver; set TAG=... explicitly."; \
							exit 2; \
							;; \
					esac; \
					next_ver="$$major.$$((minor + 1)).0"; \
					;; \
				*) \
					case "$$cur_ver" in \
						''|*[!0-9]*) \
							echo "[ERROR] Cannot auto-increment TAG_VERSION=$$cur_ver; set TAG=... explicitly."; \
							exit 2; \
							;; \
					esac; \
					next_ver="$$((cur_ver + 1))"; \
					;; \
			esac; \
			prev_t="$$t"; \
			t="$(TAG_PREFIX)$$next_ver"; \
			echo "[INFO] Tag $$prev_t exists on a different commit; auto-increment to $$t"; \
		done; \
	fi; \
	if git rev-parse -q --verify "refs/tags/$$t" >/dev/null 2>&1; then \
		tag_commit="$$(git rev-parse "$$t^{}")"; \
		if [ "$$tag_commit" = "$$head_commit" ]; then \
			echo "[INFO] Tag already exists on HEAD: $$t"; \
		else \
			echo "[ERROR] Tag exists on a different commit: $$t"; \
			echo "[INFO] tag commit:  $$tag_commit"; \
			echo "[INFO] HEAD commit: $$head_commit"; \
			exit 2; \
		fi; \
	else \
		if [ "$$tag_create" = "0" ]; then \
			echo "[INFO] TAG_CREATE=0: resolved tag (not created): $$t"; \
		else \
		{ \
			echo "idle-shutdown release tag: $$t"; \
			echo ""; \
			echo "Package version: $$pkg_ver"; \
			echo "Debian upstream version: $$tag_ver"; \
			echo "idle-shutdown.sh sha256: $(STAMP_IDLE_SHUTDOWN_SHA256)"; \
			echo "export-idle-shutdown-assets.py sha256: $(STAMP_EXPORTER_SHA256)"; \
			echo "Created at (UTC): $(STAMP_CREATE_UTC)"; \
			echo ""; \
			echo "Key files identifier (sha256 of manifest): $$identifier"; \
			echo ""; \
			echo "Manifest: <last_commit_sha>\t<file>"; \
			cat "$$manifest"; \
		} >"$$msg"; \
		git tag -a "$$t" -F "$$msg"; \
		echo "[INFO] Created annotated tag: $$t"; \
		fi; \
	fi; \
	if [ -n "$(strip $(TAG_RESULT_FILE))" ]; then \
		printf '%s\n' "$$t" >"$(TAG_RESULT_FILE)"; \
	fi; \
	echo "$$t"

tag-show:
	@t="$(TAG)"; \
	if [ -z "$$t" ]; then \
		t="$$(git tag -l "$(TAG_PREFIX)*" | sort -V | tail -n 1)"; \
	fi; \
	if [ -z "$$t" ]; then \
		echo "[ERROR] No tags found (pattern: $(TAG_PREFIX)*)"; \
		exit 1; \
	fi; \
	raw="$$(git cat-file -p "$$t" 2>/dev/null || true)"; \
	if [ -z "$$raw" ]; then \
		echo "[ERROR] tag not found: $$t"; \
		exit 1; \
	fi; \
	obj="$$(printf '%s\n' "$$raw" | awk '/^object /{print $$2; exit}')"; \
	pkg="$$(printf '%s\n' "$$raw" | sed -n 's/^Package version: //p' | head -n 1)"; \
	up="$$(printf '%s\n' "$$raw" | sed -n 's/^Debian upstream version: //p' | head -n 1)"; \
	id="$$(printf '%s\n' "$$raw" | sed -n 's/^Key files identifier (sha256 of manifest): //p' | head -n 1)"; \
	echo "Tag: $$t"; \
	if [ -n "$$obj" ]; then \
		short="$$(git rev-parse --short=12 "$$obj" 2>/dev/null || true)"; \
		when="$$(git show -s --format=%cI "$$obj" 2>/dev/null || true)"; \
		echo "Tagged commit: $$obj ($$short)"; \
		[ -n "$$when" ] && echo "Commit time:   $$when"; \
	fi; \
	[ -n "$$pkg" ] && echo "Package version: $$pkg"; \
	[ -n "$$up" ] && echo "Debian upstream version: $$up"; \
	if [ -n "$$id" ]; then \
		echo "Key files identifier (sha256 of manifest): $$id"; \
		echo ""; \
		echo "Manifest (TSV, tab-separated):"; \
		manifest="$$(printf '%s\n' "$$raw" | awk 'found{print} /^Manifest: /{found=1; next}')"; \
		if command -v column >/dev/null 2>&1; then \
			printf '%s\n' "$$manifest" | column -t -s $$'\t'; \
		else \
			printf '%s\n' "$$manifest"; \
		fi; \
	fi

tag-show-raw:
	@t="$(TAG)"; \
	if [ -z "$$t" ]; then \
		t="$$(git tag -l "$(TAG_PREFIX)*" | sort -V | tail -n 1)"; \
	fi; \
	if [ -z "$$t" ]; then \
		echo "[ERROR] No tags found (pattern: $(TAG_PREFIX)*)"; \
		exit 1; \
	fi; \
	git cat-file -p "$$t"

tag-list:
	@for t in $$(git tag -l "$(TAG_PREFIX)*" | sort -V); do \
		pkg="$$(git cat-file -p "$$t" 2>/dev/null | sed -n 's/^Package version: //p' | head -n 1)"; \
		if [ -z "$$pkg" ]; then pkg="(no package version)"; fi; \
		id="$$(git cat-file -p "$$t" 2>/dev/null | sed -n 's/^Key files identifier (sha256 of manifest): //p' | head -n 1)"; \
		if [ -z "$$id" ]; then id="(no identifier)"; fi; \
		printf '%-28s %-14s %s\n' "$$t" "$$pkg" "$$id"; \
	done
