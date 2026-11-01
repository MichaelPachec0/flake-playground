final: prev:
{
  # OpenSSL 4.1 + Windscribe super-large TLS padding (anti-censorship). ECH is native
  # in 4.x (no flag). Built static so its symbols stay private when linked into wsnet,
  # avoiding any clash with nixpkgs qt6's openssl_3.
  #
  # Note: upstream's vcpkg registry targets 4.0.0, but nixpkgs dropped openssl_4_0, so
  # the tls-padding patch is ported to 4.1: SSL_OP_TLSEXT_PADDING_SUPER moves to bit 42
  # (4.1 took bit 41 for SSL_OP_GREASE), and the hunk gates on SUPER alone because 4.1
  # made SSL_OP_TLSEXT_PADDING a no-op (0x0) and removed tls_construct_ctos_padding.
  # Using the nixpkgs-provided derivation avoids a separate source hash.
  opensslEch = (prev.openssl_4_1.override { static = true; }).overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./patches/openssl-tls-padding.patch ];
    # The patch can compile yet never fire (4.1 turned the flag it used to gate on into
    # 0x0), so assert a padded ClientHello really grows by the 7000+ byte extension.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      $CC ${./tests/clienthello-padding.c} -o clienthello-padding \
        -I$dev/include -L$out/lib -l:libssl.a -l:libcrypto.a -lpthread
      ./clienthello-padding
      runHook postInstallCheck
    '';
  });

  # curl 8.19.0 + 2 Windscribe patches (super-large TLS padding, legacy EC point formats)
  # + ECH enabled, built against opensslEch (OpenSSL 4.1 static, ECH-capable).
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
        echo "ERROR: curlEch built WITHOUT ECH support: anti-censorship feature regressed" >&2
        exit 1
      fi
      echo "[curlEch] ECH present: OK"
    '';
  }));

  # spdlog 1.17.0: force static archive with explicit SPDLOG_FMT_EXTERNAL=ON.
  # The vcpkg registry pins 1.14.1; we use 1.17.0 from nixpkgs (version delta is a
  # Task-10 compile-verify item).
  spdlogWs = (prev.spdlog.override { staticBuild = true; }).overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DSPDLOG_FMT_EXTERNAL=ON" ];
  });

  # nixpkgs c-ares (1.34.6) already includes the CVE-2025-62408 fix (fixed in >= 1.34.6);
  # no patch needed. Passthrough alias kept for stable Task-10 interface.
  caresWs = prev.c-ares;
}
