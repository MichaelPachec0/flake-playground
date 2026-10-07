# NixOS module for Windscribe Desktop VPN.
# flake-playground convention: `import ./windscribe inputs` -> a NixOS module.
# The package defaults to this flake's own `packages.<system>.windscribe`.
inputs: { config, lib, pkgs, ... }:
let
  cfg = config.services.windscribe;
  nftCfg = config.networking.nftables;
  # networking.nftables.flushRuleset = true makes every nftables (re)load run
  # `flush ruleset`, which deletes the helper's `inet windscribe` table (kill
  # switch, DNS-leak and WireGuard chains). Nothing in Windscribe re-creates it on
  # its own, so this unsupported setup gets a best-effort re-apply hook below.
  nftFlushes = nftCfg.enable && nftCfg.flushRuleset;

  # Re-push the Windscribe firewall through each logged-in user's running app
  # (windscribe-cli talks to the GUI over $XDG_RUNTIME_DIR/windscribe-localipc.sock,
  # which is owner-only, so the CLI must run as that user). Status strings below
  # are the app's English output (src/windscribe-cli/strings.cpp in the Windscribe
  # source). The app translates them into its UI language, so for any other
  # language the status is unrecognised and the user is skipped with a log line.
  # Users are handled concurrently and every CLI call is capped, so one hung or
  # hostile session cannot delay another user's restore. Always exits 0: a
  # failure would fail the nftables reload or leave this unit failed.
  nftReapply = pkgs.writeShellApplication {
    name = "windscribe-nft-reapply";
    runtimeInputs = with pkgs; [ coreutils getent gnugrep gnused nftables procps util-linux ];
    text = ''
      cli=${lib.escapeShellArg "${cfg.package}/bin/windscribe-cli"}
      users=(${lib.escapeShellArgs cfg.addUsersToGroup})

      # sd-daemon level prefixes: the journal records these as warning / info.
      warn() { echo "<4>windscribe-nft-reapply: $*" >&2; }
      info() { echo "<6>windscribe-nft-reapply: $*" >&2; }

      # CLI output is user-influenced. journald applies the <N> priority prefix
      # per line, so fold it onto one line (and drop control characters) before
      # it is logged, or a crafted line could be recorded at a forged priority.
      oneline() { printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '[:cntrl:]'; }

      # The helper keeps chains in inet windscribe while anything is active.
      # FirewallController::disable() and DnsLeakProtect::disable() leave an
      # empty table behind, so an empty table counts as flushed as well.
      table_ok() {
        local t
        t=$(nft list table inet windscribe 2>/dev/null) || return 1
        grep -Eq '^[[:space:]]*chain ' <<<"$t"
      }

      if table_ok; then
        exit 0
      fi
      info "table inet windscribe is absent or empty; checking running Windscribe sessions"

      # Run windscribe-cli as $user with a hard cap of $1 seconds (SIGKILL 5 s
      # after SIGTERM). Uses reapply_user's locals user/uid/home.
      as_user() {
        local secs=$1
        shift
        timeout -k 5 "$secs" runuser -u "$user" -- \
          env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" "$cli" "$@"
      }

      # Run a CLI command, log its (sanitized) output, return its exit code.
      cli_run() {
        local secs=$1 out rc=0
        shift
        out=$(as_user "$secs" "$@" 2>&1) || rc=$?
        if [[ $rc -eq 0 ]]; then
          info "$user: windscribe-cli $*: $(oneline "$out")"
        else
          warn "$user: windscribe-cli $* failed (rc=$rc): $(oneline "$out")"
        fi
        return "$rc"
      }

      reapply_user() {
        local user=$1 uid=$2 home=$3 status fw rc=0
        status=$(as_user 10 status 2>&1) || rc=$?
        if [[ $rc -ne 0 ]]; then
          warn "$user: windscribe-cli status failed (rc=$rc): $(oneline "$status")"
          return 1
        fi
        fw=$(sed -n 's/^Firewall state: //p' <<<"$status" | head -n 1)
        case "$fw" in
          "Always On" | On | Off) ;;
          *)
            warn "$user: unrecognised windscribe-cli status output (app language not English?); not touching this session"
            return 1
            ;;
        esac

        # "*" prefix = tunnel test still pending; Connecting is re-driven the same way.
        if grep -Eq '^[*]?Connect state: (Connected|Connecting)' <<<"$status"; then
          warn "$user: connected or connecting; reconnecting to re-apply the Windscribe firewall"
          cli_run 120 disconnect || true
          cli_run 120 connect || return 1
        elif [[ $fw == "Always On" ]]; then
          warn "$user: disconnected with firewall Always On, which refuses 'firewall off'; restart the Windscribe app to restore the kill switch"
          return 1
        elif [[ $fw == On ]]; then
          warn "$user: disconnected with firewall on; toggling it off and on to re-apply"
          cli_run 30 firewall off || true
          cli_run 30 firewall on || return 1
        else
          info "$user: disconnected with firewall off; nothing to re-apply"
        fi
      }

      for user in "''${users[@]}"; do
        if ! uid=$(id -u "$user" 2>/dev/null); then
          info "$user: no such user; skipping"
          continue
        fi
        if [[ ! -S /run/user/$uid/windscribe-localipc.sock ]]; then
          continue
        fi
        # Without a running app, windscribe-cli would try to launch the GUI itself.
        if ! pgrep -u "$uid" Windscribe >/dev/null; then
          info "$user: stale IPC socket, no Windscribe app running; skipping"
          continue
        fi
        if ! home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6) || [[ -z $home ]]; then
          warn "$user: cannot resolve home directory (NSS lookup failed); skipping"
          continue
        fi
        { reapply_user "$user" "$uid" "$home" || warn "$user: re-apply did not complete"; } &
      done
      wait

      if table_ok; then
        info "table inet windscribe is populated again"
      else
        warn "table inet windscribe is still absent or empty; no Windscribe kill switch is active (expected only if every session has its firewall off)"
      fi
      exit 0
    '';
  };
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

    warnings = lib.optional nftFlushes ''
      services.windscribe: networking.nftables.flushRuleset = true is
      experimental and not supported by Windscribe or this repo. Every nftables
      reload deletes the Windscribe kill-switch table (inet windscribe). A
      best-effort reconnect hook (windscribe-nft-reapply.service) is enabled; it
      leaves a seconds-long, partly fail-open gap. Supported setup:
      networking.nftables.flushRuleset = false with rules in
      networking.nftables.tables.
    '';

    # Re-apply hook for the flushing setup. A separate unit rather than an
    # ExecReload override on nixpkgs' nftables.service: ReloadPropagatedFrom
    # turns every nftables reload into a reload of this unit (run after it via
    # `after`), and PartOf makes an nftables stop/restart stop/restart this unit,
    # so ExecStart covers the restart path.
    systemd.services.windscribe-nft-reapply = lib.mkIf nftFlushes {
      description = "Re-apply the Windscribe firewall after an nftables ruleset flush";
      after = [ "nftables.service" ];
      partOf = [ "nftables.service" ];
      # multi-user.target: switch-to-configuration starts new units through the
      # active targets, so this is what activates the unit on first deploy.
      # nftables.service: an explicit `systemctl start nftables` (after a stop,
      # which PartOf propagated here) brings this unit back too.
      wantedBy = [ "multi-user.target" "nftables.service" ];
      unitConfig.ReloadPropagatedFrom = [ "nftables.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # "-": a non-zero exit must not leave the unit failed, since propagated
        # reloads are no-ops on an inactive unit. The script exits 0 anyway.
        ExecStart = "-${lib.getExe nftReapply}";
        ExecReload = lib.getExe nftReapply;
        # No start (or reload) timeout: a start timeout would leave the unit failed.
        # Every CLI call in the script is capped (timeout -k 5; at most about 265 s
        # per user) and users run concurrently, so the script itself is bounded.
        # Stopping (PartOf: an nftables restart) stays bounded so a stuck child is
        # escalated to SIGKILL.
        TimeoutStartSec = "infinity";
        TimeoutStopSec = 30;
      };
    };
  };
}
