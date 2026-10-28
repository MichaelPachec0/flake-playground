# systemd sandbox shared by the nix-cache service units (importer, pruner).
# They reach the nix-daemon over its unix socket and need no network at all;
# alerts leave through the spool delivered by nix-cache-alert.service.
{
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;
  PrivateDevices = true;
  PrivateNetwork = true;
  RestrictAddressFamilies = ["AF_UNIX"];
  NoNewPrivileges = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectControlGroups = true;
  RestrictNamespaces = true;
  LockPersonality = true;
  SystemCallFilter = ["@system-service"];
  SystemCallArchitectures = "native";
  UMask = "0077";
  Environment = [
    "HOME=/var/lib/nix-cache"
    "XDG_CACHE_HOME=/var/lib/nix-cache/cache"
  ];
}
