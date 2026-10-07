# NixOS module for Windscribe Desktop VPN.
# flake-playground convention: `import ./windscribe inputs` -> a NixOS module.
# The package defaults to this flake's own `packages.<system>.windscribe`.
inputs: { config, lib, pkgs, ... }:
let
  cfg = config.services.windscribe;
  windscribeDesktopItem = pkgs.makeDesktopItem {
    name = "windscribe";
    desktopName = "Windscribe";
    exec = "Windscribe";
    comment = "Windscribe VPN";
    categories = [ "Network" ];
  };
in
{
  options.services.windscribe = {
    enable = lib.mkEnableOption "Windscribe Desktop VPN (helper service + GUI/CLI)";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.windscribe;
      defaultText = lib.literalExpression "self.packages.\${system}.windscribe";
      description = "The hardened Windscribe package providing the GUI, CLI, and helper.";
    };

    addUsersToGroup = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        Login users to add to the `windscribe` group. Membership is required to
        reach the helper's Unix socket (`/var/run/windscribe/helper.sock`, mode
        0770 root:windscribe). Users must log out and back in after activation
        for the new group membership to take effect.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The helper drops privilege to this user for the ctrld/wstunnel children, and
    # guards its socket with this group. Both must exist or the helper exits at startup.
    users.groups.windscribe.members = cfg.addUsersToGroup;
    users.users.windscribe = {
      isSystemUser = true;
      group = "windscribe";
      shell = "${pkgs.shadow}/bin/nologin";
      description = "Windscribe VPN helper drop-privilege user";
    };

    systemd.services.windscribe-helper = {
      description = "Windscribe helper service";
      before = [ "network-pre.target" ];
      # Both units sit before network-pre.target with no order between them. With
      # networking.nftables.flushRuleset = true, a `flush ruleset` that ran after
      # the helper loaded its boot rules into inet windscribe would silently drop
      # the boot kill switch. No-op when nftables is not enabled.
      after = [ "nftables.service" ];
      wants = [ "network-pre.target" ];
      wantedBy = [ "multi-user.target" ];
      # NixOS `path` replaces (not extends) the unit PATH; the service does NOT
      # inherit /run/current-system/sw/bin. Every tool the helper and its DNS-script /
      # `env` shell-outs invoke must be listed explicitly or executeCommand() exits 127.
      # coreutils/gnugrep/gnused/gawk/e2fsprogs/openresolv are the DNS-script / `env`
      # shell-out deps (dirname/cat/tr/sort, grep, sed, awk, chattr, resolvconf).
      path = with pkgs; [
        coreutils
        gnugrep
        gnused
        gawk
        e2fsprogs
        openresolv
        iproute2
        # The helper's firewall is nftables-only. iptables stays solely for
        # purgeLegacyIptables(), which removes legacy windscribe_* iptables chains
        # left by older installs (skipped when the binary is absent).
        iptables
        kmod
        procps
        systemd
        wireguard-tools
        util-linux
        iputils
        ethtool
        iw
        networkmanager
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/windscribe-helper";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # The helper self-creates /var/run/windscribe and /var/lib/windscribe (as root) and
    # chowns them to the group. It does NOT create the log/config dirs, so provision them.
    systemd.tmpfiles.rules = [
      "d /var/log/windscribe 0755 root windscribe - -"
      "d /etc/windscribe 0755 root windscribe - -"
    ];

    environment.systemPackages = [ cfg.package windscribeDesktopItem ];

    # WireGuard uses the kernel module (the helper calls `modprobe wireguard`).
    boot.kernelModules = [ "wireguard" ];
  };
}
