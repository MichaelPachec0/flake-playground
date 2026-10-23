# Write path, network-facing half: one SSH upload user per repo whose only
# possible action is the forced cache-receive script. Layered so that each
# layer alone already blocks the obvious abuse.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nix-cache-host;
  dropRoot = "/srv/cache-drop";
  user = repo: "cache-drop-${repo}";
  uids = lib.mapAttrsToList (_: r: r.uid) cfg.repos;

  receive = repo: r:
    pkgs.writeShellApplication {
      name = "cache-receive-${repo}";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        DROP_DIR=${lib.escapeShellArg "${dropRoot}/${repo}"}
        MAX_BYTES=${toString r.maxBundleBytes}
        ${builtins.readFile cfg.package.receiveScript}
      '';
    };

  # New files in tmp/ and incoming/ get rw for nix-cache from the default
  # ACL; the directories themselves are 1730 nix-cache:cache-drop-<repo>, so
  # the upload user can create and rename entries but never list them. Its
  # own files carry no permissions for it (user::---): cache-receive writes
  # through the fd it opened at creation, so it can neither read back nor
  # reopen and overwrite a pending bundle by its guessable <epoch>-<pid> name.
  acl = "default:user::---,default:user:nix-cache:rw-,default:group::---,default:mask::rw-,default:other::---";
  dirRules = repo: [
    "d ${dropRoot}/${repo} 0755 root root -"
    "d ${dropRoot}/${repo}/tmp 1730 nix-cache ${user repo} -"
    "d ${dropRoot}/${repo}/incoming 1730 nix-cache ${user repo} -"
    "d ${dropRoot}/${repo}/failed 0700 nix-cache nix-cache -"
    "A+ ${dropRoot}/${repo}/tmp - - - - ${acl}"
    "A+ ${dropRoot}/${repo}/incoming - - - - ${acl}"
  ];
in {
  config = lib.mkIf (cfg.enable && cfg.repos != {}) {
    assertions = [
      {
        assertion = config.networking.firewall.enable || config.networking.nftables.enable;
        message = "services.nix-cache-host: the upload users' egress block needs networking.firewall or networking.nftables";
      }
    ];

    users.users = lib.mapAttrs' (repo: r:
      lib.nameValuePair (user repo) {
        isSystemUser = true;
        uid = r.uid;
        group = user repo;
        home = "/var/empty";
        # sshd runs a forced command through the login shell ($SHELL -c), so
        # this must be a real shell; nologin would refuse every upload.
        shell = pkgs.bashInteractive;
        hashedPassword = "!";
        openssh.authorizedKeys.keys =
          map (k: ''restrict,command="${lib.getExe (receive repo r)}",expiry-time="${k.expires}" ${k.key}'')
          r.uploadKeys;
      })
    cfg.repos;

    users.groups = lib.mapAttrs' (repo: r: lib.nameValuePair (user repo) {gid = r.uid;}) cfg.repos;

    services.openssh.enable = true;
    # Match blocks run to the next Match, so close with `Match all`: anything
    # appended after this module would otherwise only apply to upload users.
    services.openssh.extraConfig = lib.mkAfter (lib.concatStrings (lib.mapAttrsToList (repo: r: ''
        Match User ${user repo}
          ForceCommand ${lib.getExe (receive repo r)}
          AuthenticationMethods publickey
          DisableForwarding yes
          PermitTTY no
          PermitTunnel no
          PermitUserRC no
          MaxSessions 1
          ClientAliveInterval 30
          ClientAliveCountMax 4
          ChannelTimeout session=15m
      '')
      cfg.repos)
    + "Match all\n");

    security.pam.loginLimits = lib.concatLists (lib.mapAttrsToList (repo: r: [
        {
          domain = user repo;
          type = "hard";
          item = "fsize";
          value = toString (r.maxBundleBytes / 1024 + 1);
        }
        {
          domain = user repo;
          type = "hard";
          item = "nproc";
          value = "32";
        }
        {
          domain = user repo;
          type = "hard";
          item = "nofile";
          value = "64";
        }
      ])
      cfg.repos);

    systemd.slices = lib.mapAttrs' (_: r:
      lib.nameValuePair "user-${toString r.uid}" {
        overrideStrategy = "asDropin";
        sliceConfig = {
          TasksMax = 32;
          MemoryMax = "256M";
          CPUQuota = "100%";
          IOWeight = 10;
        };
      })
    cfg.repos;

    systemd.tmpfiles.rules = ["d ${dropRoot} 0755 root root -"] ++ lib.concatLists (lib.mapAttrsToList (repo: _: dirRules repo) cfg.repos);

    # Egress block by UID. The SSH session itself is unaffected: sockets
    # accepted by sshd belong to root, not to the upload user.
    networking.nftables.tables = lib.mkIf config.networking.nftables.enable {
      nix-cache-egress = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy accept;
            meta skuid { ${lib.concatMapStringsSep ", " toString uids} } counter drop
          }
        '';
      };
    };
    networking.firewall.extraCommands = lib.mkIf (!config.networking.nftables.enable) ''
      ip46tables -N nix-cache-egress 2>/dev/null || true
      ip46tables -F nix-cache-egress
      ${lib.concatMapStrings (uid: "ip46tables -A nix-cache-egress -m owner --uid-owner ${toString uid} -j DROP\n") uids}
      ip46tables -C OUTPUT -j nix-cache-egress 2>/dev/null || ip46tables -I OUTPUT -j nix-cache-egress
    '';
    networking.firewall.extraStopCommands = lib.mkIf (!config.networking.nftables.enable) ''
      ip46tables -D OUTPUT -j nix-cache-egress 2>/dev/null || true
      ip46tables -F nix-cache-egress 2>/dev/null || true
      ip46tables -X nix-cache-egress 2>/dev/null || true
    '';
  };
}
