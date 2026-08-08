Name: tessera-studio
Version: 0.1.0
Release: 1%{?dist}
Summary: Tessera Studio — Fedora GTK4 port
License: LicenseRef-TESSERA
BuildRequires: cmake, pkgconfig(gtk4), pkgconfig(libadwaita-1), pkgconfig(gtksourceview-5), pkgconfig(libsecret-1)
%description
Full parity Linux desktop port of TesseraStudio (docs/linux-gtk4-port-spec.md) — GTK4 + Adwaita, libsecret, LUKS, EDS/CalDAV, libetpan.
%install
%cmake -S . -B build
%cmake_build
%cmake_install
%files
%{_bindir}/tessera-studio-linux
%{_datadir}/glib-2.0/schemas/org.tessera.TesseraStudio.gschema.xml
