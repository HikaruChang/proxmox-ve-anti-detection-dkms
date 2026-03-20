PACKAGE_NAME = pve-qemu-anti-detection
VERSION = 1.0.0

.PHONY: all build clean install deb

all:
	@echo "Nothing to build. Use 'make deb' to build the .deb package."

build:
	@echo "Nothing to build."

deb:
	dpkg-buildpackage -us -uc -b

clean:
	rm -f ../$(PACKAGE_NAME)_*.deb
	rm -f ../$(PACKAGE_NAME)_*.buildinfo
	rm -f ../$(PACKAGE_NAME)_*.changes

install:
	# Install patch files
	install -d $(DESTDIR)/usr/src/pve-qemu-anti-detection/patches
	install -m 644 patches/001-anti-detection.patch $(DESTDIR)/usr/src/pve-qemu-anti-detection/patches/

	# Install main script
	install -d $(DESTDIR)/usr/bin
	install -m 755 scripts/pve-qemu-anti-detection $(DESTDIR)/usr/bin/

	# Install configuration
	install -d $(DESTDIR)/etc
	install -m 644 conf/pve-qemu-anti-detection.conf $(DESTDIR)/etc/

	# Install APT hook
	install -d $(DESTDIR)/etc/apt/apt.conf.d
	install -m 644 hooks/99-pve-qemu-anti-detection $(DESTDIR)/etc/apt/apt.conf.d/

	# Install systemd service
	install -d $(DESTDIR)/lib/systemd/system
	install -m 644 systemd/pve-qemu-anti-detection-rebuild.service $(DESTDIR)/lib/systemd/system/
