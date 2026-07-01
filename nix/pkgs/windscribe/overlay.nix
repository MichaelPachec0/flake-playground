final: prev:
{
  # OpenSSL 4.0.1 + Windscribe super-large TLS padding (anti-censorship). ECH is native
  # in 4.0.x (no flag). Built static so its symbols stay private when linked into wsnet,
  # avoiding any clash with nixpkgs qt6's openssl_3.
  #
  # Note: nixpkgs pins openssl_4_0 at 4.0.1 (the vcpkg registry targets 4.0.0; the
  # tls-padding patch was written for that commit but applies cleanly to 4.0.1 as well).
  # Using the nixpkgs-provided derivation avoids a separate source hash.
  opensslEch = (prev.openssl_4_0.override { static = true; }).overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./patches/openssl-tls-padding.patch ];
  });

  # curl 8.19.0 + 2 Windscribe patches (super-large TLS padding, legacy EC point formats)
  # + ECH enabled, built against opensslEch (OpenSSL 4.0.1 static, ECH-capable).
  # Pinned to 8.19.0 because the WS patches were written for that release.
  curlEch = ((prev.curl.override {
    openssl = final.opensslEch;
    http3Support = false; # drop ngtcp2/nghttp3 -> removes transitive openssl_3 via those
    scpSupport = false;   # drop libssh2        -> removes transitive openssl_3 via libssh2
  }).overrideAttrs (old: {
    version = "8.19.0";
    src = final.fetchurl {
      url = "https://curl.se/download/curl-8.19.0.tar.xz";
      hash = "sha256-TrQUiXkNGeGQ16x+GOgoV83Wivj05mspLO1WLTM/Ed8=";
    };
    # Drop nixpkgs patches (written for 8.20.0; do not apply to 8.19.0).
    # Only carry the two Windscribe-specific patches.
    patches = [
      ./patches/curl-super-large-padding.patch
      ./patches/curl-export-legacy-ec.patch
    ];
    configureFlags = (old.configureFlags or []) ++ [ "--enable-ech" ];
    doInstallCheck = true;
    installCheckPhase = ''
      echo "[curlEch] verifying ECH capability..."
      if ! $bin/bin/curl -V | grep -qw ECH; then
        echo "ERROR: curlEch built WITHOUT ECH support — anti-censorship feature regressed" >&2
        exit 1
      fi
      echo "[curlEch] ECH present: OK"
    '';
  }));

  # spdlog 1.17.0 — force static archive with explicit SPDLOG_FMT_EXTERNAL=ON.
  # The vcpkg registry pins 1.14.1; we use 1.17.0 from nixpkgs (version delta is a
  # Task-10 compile-verify item).
  spdlogWs = (prev.spdlog.override { staticBuild = true; }).overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DSPDLOG_FMT_EXTERNAL=ON" ];
  });

  # nixpkgs c-ares (1.34.6) already includes the CVE-2025-62408 fix (fixed in >= 1.34.6);
  # no patch needed. Passthrough alias kept for stable Task-10 interface.
  caresWs = prev.c-ares;
}
