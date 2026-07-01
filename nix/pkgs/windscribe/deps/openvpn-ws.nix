{ pkgs }:
pkgs.openvpn.overrideAttrs (old: {
  version = "2.7.4";

  # GitHub source is autotools-from-git (no pre-generated ./configure).
  # The patch also modifies Makefile.am, so autoreconf must regenerate it.
  src = pkgs.fetchFromGitHub {
    owner = "OpenVPN";
    repo = "openvpn";
    rev = "8e9e91f4caff9a80961f32a1f9eda7e5a489176e";
    hash = "sha256-KYj3TazH6lWUvjI8SCCNSjXv0z12qeNXt4KhqJSYPPU=";
  };

  patches = (old.patches or []) ++ [ ../patches/openvpn-anti-censorship.patch ];

  # autoreconfHook regenerates ./configure from configure.ac + Makefile.am
  # after the patch modifies Makefile.am to add anti_censorship.c/.h.
  # python3Packages.docutils provides rst2man so that man pages can be
  # generated (doc/Makefile.am always installs them on non-Windows targets
  # regardless of HAVE_PYDOCUTILS; without it, make install fails).
  nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
    pkgs.autoreconfHook
    pkgs.python3Packages.docutils
  ];
})
