# VM test for the self-hosted binary cache (services.nix-cache-host).
# Nodes: selene (the cache host), ci (bundles, signs and uploads exactly like
# the GitHub push job), consumer (substitutes with a read token).
#   nix build .#checks.x86_64-linux.nix-cache-vm -L
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.nix-cache;
  sshKeys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;

  # Test-only keys and tokens, never used for a real cache. The repo key pair
  # is shared with the nix-cache unit tests and the module eval checks.
  repoSecret = "vmtest-repo-1:2wdF90NG+3puU8r9BYw+NfAcq9P7SWmZYimsNE7UtcM8o5SsQTTr8uDTBsO4auMduF6R9+TWRGUE9phcMD+Fzg==";
  repoPublic = "vmtest-repo-1:PKOUrEE06/Lg0wbDuGrjHbhekffk1kRlBPaYXDA/hc4=";
  wrongSecret = "vmtest-wrong-1:1xFY9lhfADfc/NSHxGrqe2Un25GwSycxI9adnA9Q6rHEZtQKS9P0NTD1E/+lZzfXxnZaFxeBVpiifZ7KEuJQuA==";
  tokens = {
    consumer1 = "q-yPCWrYknxVswqi5Lu33h83B4da9eWq2QfAq33hjb8";
    consumer2 = "qlOfQORjdVrkcM42jta15h4_f9XpBnjw2zao0r-iXv4";
    ci1 = "uq2AclOw9dlrTKL_4Jgx7eiGQHkyE3GPrv2nIe-AY5o";
  };
  host = "cache.example.test";

  # The module only accepts secret paths outside the store, so the htpasswd
  # file and the TLS key are written to /run at boot. The key comes from the
  # store only because this is a test; real hosts use a sops secret.
  tls = pkgs.runCommand "nix-cache-vm-tls" {nativeBuildInputs = [pkgs.openssl];} ''
    mkdir $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj /CN=${host} -addext subjectAltName=DNS:${host} \
      -keyout $out/key.pem -out $out/cert.pem
  '';
  secretsDir = "/run/nix-cache-vm";

  payloadA = pkgs.runCommand "payload-a" {outputs = ["out" "dev"];} ''
    mkdir -p $out/share $dev/include
    echo a > $out/share/a
    echo a > $dev/include/a.h
  '';
  # C references A, so A is an external reference of the second bundle.
  payloadC = pkgs.runCommand "payload-c" {} ''
    mkdir -p $out/share
    echo ${payloadA} > $out/share/ref
  '';
  payloadU = pkgs.writeTextDir "share/unsigned" "u";
  payloadW = pkgs.writeTextDir "share/wrong-key" "w";
  payloadX = pkgs.writeTextDir "share/tampered" "x";
  payloadR = pkgs.writeTextDir "share/forged-repo" "r";
  # Enough independent paths that one substitution makes more requests than
  # the anonymous rate limit's burst (20) allows.
  payloadsM = map (i: pkgs.writeTextDir "share/many-${toString i}" "m${toString i}") (lib.range 1 16);
  # Guard subtests (pushed last): N is a root that is never bundled nor on
  # selene; E is imported, then used to feed the dry-run estimator on the
  # consumer; B is rejected by the budget and by the free-space floor.
  payloadN = pkgs.writeTextDir "share/never-shipped" "n";
  payloadE = pkgs.writeTextDir "share/estimate" "e";
  payloadB = pkgs.writeTextDir "share/over-budget" "b";
  # The package's modules (an application, so not on any env's path), to call nixcli directly.
  pkgSitePackages = "${pkg}/${pkgs.python3.sitePackages}";
  rootsJson = name: paths: pkgs.writeText "roots-${name}.json" (builtins.toJSON (map toString paths));

  hostsFor = nodes: "${nodes.selene.networking.primaryIPAddress} ${host}";
in
  pkgs.testers.runNixOSTest {
    name = "nix-cache";

    nodes.selene = {config, ...}: {
      imports = [self.nixosModules.nix-cache-host];
      services.nix-cache-host = {
        enable = true;
        package = pkg;
        hostName = host;
        htpasswdFile = "${secretsDir}/htpasswd";
        nginx.sslCertificate = "${tls}/cert.pem";
        nginx.sslCertificateKey = "${secretsDir}/key.pem";
        # The VM's writable store is far smaller than the 10 GiB default floor.
        retention.importMinFree = 64 * 1024 * 1024;
        repos.vmtest = {
          uid = 2001;
          signingPublicKeys = [repoPublic];
          # Every set the test pushes to; "other" is pushed to prove rejection.
          sets = ["gate" "many" "forged"];
          uploadKeys = [
            {
              key = sshKeys.snakeOilPublicKey;
              expires = "20991231";
            }
          ];
          maxBundleBytes = 1024 * 1024;
          maxUnpackedBytes = 4 * 1024 * 1024;
        };
      };
      # Stand-in for the sops secrets: write the htpasswd (one line per token
      # generation) and the TLS key before nginx checks its config.
      systemd.services.nix-cache-vm-secrets = {
        wantedBy = ["nginx.service"];
        before = ["nginx.service"];
        path = [pkg pkgs.coreutils];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 0750 -o root -g nginx ${secretsDir}
          umask 077
          {
            printf %s ${tokens.consumer1} | nix-cache-htpasswd-entry consumer-g1
            printf %s ${tokens.consumer2} | nix-cache-htpasswd-entry consumer-g2
            printf %s ${tokens.ci1} | nix-cache-htpasswd-entry ci-vmtest-g1
          } > ${secretsDir}/htpasswd
          install -m 0640 -o root -g nginx ${tls}/key.pem ${secretsDir}/key.pem
          chown root:nginx ${secretsDir}/htpasswd
          chmod 0640 ${secretsDir}/htpasswd
        '';
      };
      services.fail2ban.enable = true;
      # Mirror selene: nix-daemon access is default-deny (nix-config sets
      # allowed-users), so the module's extra-allowed-users must be enough.
      nix.settings.allowed-users = ["root"];
      nix.settings.substituters = lib.mkForce [];
      environment.systemPackages = [pkgs.curl pkgs.jq];
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
      # The hourly pruner must not run behind the test's back.
      systemd.timers.cache-pruner.wantedBy = lib.mkForce [];
    };

    nodes.ci = {nodes, ...}: {
      environment.systemPackages = [pkg pkgs.zstd pkgs.jq pkgs.gnutar pkgs.curl pkgs.python3];
      nix.settings.experimental-features = ["nix-command"];
      nix.settings.substituters = lib.mkForce [];
      virtualisation.additionalPaths = [payloadA payloadA.dev payloadC payloadU payloadW payloadX payloadR payloadN payloadE payloadB] ++ payloadsM;
      networking.extraHosts = hostsFor nodes;
      security.pki.certificateFiles = ["${tls}/cert.pem"];
      networking.firewall.allowedTCPPorts = [8080];
      environment.etc = {
        "nix-cache-vm/repo.sk".text = repoSecret;
        "nix-cache-vm/wrong.sk".text = wrongSecret;
        "nix-cache-vm/upload_key" = {
          source = sshKeys.snakeOilPrivateKey;
          mode = "0600";
        };
        "nix-cache-vm/netrc" = {
          text = "machine ${host}\nlogin ci-vmtest-g1\npassword ${tokens.ci1}\n";
          mode = "0600";
        };
        "nix-cache-vm/roots-a.json".source = rootsJson "a" [payloadA payloadA.dev];
        "nix-cache-vm/roots-c.json".source = rootsJson "c" [payloadC];
        "nix-cache-vm/roots-m.json".source = rootsJson "m" payloadsM;
        "nix-cache-vm/roots-u.json".source = rootsJson "u" [payloadU];
        "nix-cache-vm/roots-w.json".source = rootsJson "w" [payloadW];
        "nix-cache-vm/roots-x.json".source = rootsJson "x" [payloadX];
        "nix-cache-vm/roots-r.json".source = rootsJson "r" [payloadR];
        "nix-cache-vm/roots-n.json".source = rootsJson "n" [payloadN];
        "nix-cache-vm/roots-e.json".source = rootsJson "e" [payloadE];
        "nix-cache-vm/roots-b.json".source = rootsJson "b" [payloadB];
      };
    };

    nodes.consumer = {nodes, ...}: {
      nix.settings = {
        substituters = lib.mkForce ["https://${host}"];
        trusted-public-keys = lib.mkForce [repoPublic];
        netrc-file = "/etc/nix-cache-vm/netrc";
        experimental-features = ["nix-command"];
        connect-timeout = 5;
      };
      networking.extraHosts = hostsFor nodes;
      security.pki.certificateFiles = ["${tls}/cert.pem"];
      environment.systemPackages = [pkgs.curl pkgs.python3];
      environment.etc."nix-cache-vm/netrc" = {
        text = "machine ${host}\nlogin consumer-g1\npassword ${tokens.consumer1}\n";
        mode = "0600";
      };
      # Right user, wrong token: the host is "on a retired generation".
      environment.etc."nix-cache-vm/bad-netrc" = {
        text = "machine ${host}\nlogin consumer-g1\npassword ${tokens.consumer2}\n";
        mode = "0600";
      };
    };

    testScript = {nodes, ...}: let
      seleneIP = nodes.selene.networking.primaryIPAddress;
      consumerIP = nodes.consumer.networking.primaryIPAddress;
      ciIP = nodes.ci.networking.primaryIPAddress;
    in ''
      import json

      URL = "https://${host}"
      SSH = "ssh -i /etc/nix-cache-vm/upload_key -o StrictHostKeyChecking=no -o BatchMode=yes cache-drop-vmtest@selene"
      PINS = "/nix/var/nix/gcroots/cache/pins/vmtest"
      DROP = "/srv/cache-drop/vmtest"
      ACCESS_LOG = "/var/log/nginx/nix-cache.access.log"
      HTPASSWD = "${secretsDir}/htpasswd"
      MANY = "${lib.concatStringsSep " " (map toString payloadsM)}".split()


      def code(node, args):
          return node.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {args}").strip()


      def valid(node, path):
          return node.execute(f"nix-store --check-validity {path}")[0] == 0


      def bundle(name, set_="gate", key="/etc/nix-cache-vm/repo.sk", tamper=None, edit_manifest=None, strip=False):
          out = f"/tmp/bundle-{name}"
          ci.succeed(f"rm -rf {out}")
          ci.succeed(
              f"nix-cache-bundle --roots-json /etc/nix-cache-vm/roots-{name}.json --set {set_}"
              f" --arch x86_64-linux --out {out} --no-upstream --own-cache {URL}"
              f" --netrc /etc/nix-cache-vm/netrc --run-id vm --commit 0"
          )
          if key and int(ci.succeed(f"jq '.paths | length' {out}/manifest.json")) > 0:
              ci.succeed(f"jq -r '.paths[]' {out}/manifest.json | nix store sign --store file://{out} --key-file {key} --stdin")
          if tamper:
              ci.succeed(f"sed -i '{tamper}' {out}/*.narinfo")
          if strip:
              # Manifest and nix-cache-info only: no narinfos, no NARs.
              ci.succeed(f"find {out} -mindepth 1 ! -name manifest.json ! -name nix-cache-info -delete")
              ci.succeed(f"jq '.paths = []' {out}/manifest.json > {out}/m && mv {out}/m {out}/manifest.json")
          if edit_manifest:
              ci.succeed(f"jq '{edit_manifest}' {out}/manifest.json > {out}/m && mv {out}/m {out}/manifest.json")
          return out


      def push(out):
          # The same pipeline as the push workflow (nix-cache-push-bundle).
          return ci.succeed(f"nix-cache-push-bundle {out} {SSH}")


      def wait_imported():
          selene.wait_until_succeeds(f"test -z \"$(ls -A {DROP}/incoming)\"", timeout=120)
          # A running oneshot is "activating" (is-active exits non-zero), so
          # wait for the unit to be fully inactive, not merely "not active".
          selene.wait_until_succeeds(
              "test \"$(systemctl show -p ActiveState --value cache-importer-vmtest.service)\" = inactive",
              timeout=120,
          )


      def reasons():
          return set(selene.succeed(f"find {DROP}/failed -name '*.reason' -printf '%f\\n'").split())


      def pruner(args):
          # Transient units get only systemd's own bin/ on PATH on NixOS;
          # cache-pruner runs `nix`, so hand it the system profile.
          return selene.succeed(
              "systemd-run --wait --collect --pipe -p User=nix-cache -p SupplementaryGroups=nginx"
              " -p Environment=HOME=/var/lib/nix-cache -p Environment=PATH=/run/current-system/sw/bin"
              f" /run/current-system/sw/bin/cache-pruner --config /etc/nix-cache/config.json {args}"
          )


      def importer_by_hand(config):
          # The importer unit's own command line, run once on a config of our
          # choosing (the path unit must be stopped by the caller).
          return selene.succeed(
              "systemd-run --wait --collect --pipe -p User=nix-cache"
              " -p Environment=HOME=/var/lib/nix-cache -p Environment=PATH=/run/current-system/sw/bin"
              f" /run/current-system/sw/bin/cache-importer --config {config} --repo vmtest 2>&1"
          )


      def pin_count():
          return int(selene.succeed("find /nix/var/nix/gcroots/cache/pins -type l | wc -l"))


      def banned(ip):
          return selene.execute(f"fail2ban-client status nix-cache-guess | grep -wF '{ip}' >/dev/null")[0] == 0


      start_all()
      selene.wait_for_unit("nginx.service")
      selene.wait_for_unit("harmonia.socket")  # socket-activated
      selene.wait_for_unit("sshd.service")
      selene.wait_for_unit("fail2ban.service")
      selene.wait_for_open_port(443)
      ci.wait_for_unit("multi-user.target")
      consumer.wait_for_unit("multi-user.target")

      with subtest("nginx: auth, generations, allowlist, default server"):
          assert code(consumer, f"{URL}/nix-cache-info") == "401"
          assert code(consumer, f"-u consumer-g1:${tokens.consumer1} {URL}/nix-cache-info") == "200"
          assert code(consumer, f"-u consumer-g2:${tokens.consumer2} {URL}/nix-cache-info") == "200"
          assert code(consumer, f"-u consumer-g1:${tokens.consumer2} {URL}/nix-cache-info") == "401"
          assert code(consumer, f"-u consumer-g1:${tokens.consumer1} {URL}/serve/x") == "404"
          assert code(consumer, f"-u consumer-g1:${tokens.consumer1} {URL}/log/x") == "404"
          assert code(consumer, "http://${host}/nix-cache-info") == "301"
          consumer.fail("curl -sS -k --resolve other.example.test:443:${seleneIP} https://other.example.test/")
          consumer.fail("curl -sS -H 'Host: other.example.test' http://${host}/")

      with subtest("upload user: forced command, no PTY, caps, no listing, no daemon, no egress"):
          # The driver runs commands with pipefail, so take ssh's own status.
          # The requested command is ignored: the forced receive script runs.
          status, out = ci.execute(f"{SSH} 'cat /etc/shadow' </dev/null 2>&1")
          assert status == 4 and "empty upload, refused" in out, (status, out)
          # With -tt a refused PTY is fatal for the client (exit 255).
          status, out = ci.execute(f"{SSH} -tt </dev/null 2>&1")
          assert status != 0 and "PTY allocation request failed" in out, (status, out)
          status, out = ci.execute(f"head -c 2000000 /dev/zero | {SSH} 2>&1")
          assert status == 3 and "exceeds" in out, (status, out)
          selene.succeed(f"test -z \"$(ls -A {DROP}/tmp)\"")
          selene.fail(f"runuser -u cache-drop-vmtest -- ls {DROP}/incoming")
          selene.fail("runuser -u cache-drop-vmtest -- nix-store -q --hash /run/current-system")
          ci.succeed("systemd-run --unit web /run/current-system/sw/bin/python3 -m http.server 8080 --directory /tmp")
          ci.wait_for_open_port(8080)
          selene.succeed("curl -fsS -m 5 http://ci:8080/ >/dev/null")
          selene.fail("runuser -u cache-drop-vmtest -- curl -fsS -m 5 http://ci:8080/")

      with subtest("upload user cannot read back its own pending bundle"):
          # Hold the importer so the upload stays in incoming/; the default
          # ACL (user::---) leaves the owner no access to its own file.
          selene.succeed("systemctl stop cache-importer-vmtest.path")
          assert ci.succeed(f"printf pending | {SSH}").strip() == "ok"
          name = selene.succeed(f"ls {DROP}/incoming").strip()
          assert name.endswith(".tar.zst"), name
          selene.succeed(f"runuser -u nix-cache -- cat {DROP}/incoming/{name} | grep -x pending >/dev/null")
          selene.fail(f"runuser -u cache-drop-vmtest -- cat {DROP}/incoming/{name}")
          selene.fail(f"runuser -u cache-drop-vmtest -- sh -c 'echo x >> {DROP}/incoming/{name}'")
          selene.succeed(f"rm {DROP}/incoming/{name}")
          selene.succeed("systemctl start cache-importer-vmtest.path")

      with subtest("happy path: bundle, sign, push, import, pin, substitute"):
          assert push(bundle("a")).strip() == "ok"
          wait_imported()
          selene.succeed(f"test -L {PINS}/gate/x86_64-linux/latest")
          assert valid(selene, "${payloadA}") and valid(selene, "${payloadA.dev}")
          # Bundle 2: C references A, which is already on the cache and so is
          # left out of the bundle (own-cache check; the bundler seeds A's
          # narinfo for nix copy and deletes it again) and found valid on import.
          manifest = json.loads(ci.succeed(f"cat {bundle('c')}/manifest.json"))
          assert manifest["paths"] == ["${payloadC}"], manifest
          push("/tmp/bundle-c")
          wait_imported()
          assert not valid(consumer, "${payloadC}")
          consumer.succeed("nix-store --realise ${payloadC}")
          assert valid(consumer, "${payloadC}") and valid(consumer, "${payloadA}")

      with subtest("substituting many paths sends the token up front: no 401 round trip, no 429"):
          # limit_req only throttles requests WITHOUT an Authorization header,
          # so this holds only if Nix sends the netrc credentials preemptively.
          push(bundle("m", set_="many"))
          wait_imported()
          assert all(valid(selene, p) for p in MANY)
          offset = int(selene.succeed(f"stat -c %s {ACCESS_LOG}"))
          consumer.succeed("nix-store --realise " + " ".join(MANY))
          assert all(valid(consumer, p) for p in MANY)
          lines = selene.succeed(f"tail -c +{offset + 1} {ACCESS_LOG}").splitlines()
          entries = [json.loads(line) for line in lines if line.strip()]
          print(f"{len(entries)} requests, statuses {sorted({e['s'] for e in entries})}")
          # More requests than the anonymous burst, or the check proves nothing.
          assert len(entries) > 21, entries
          assert not [e for e in entries if e["s"] == 429], entries
          assert all(e["u"] == "consumer-g1" and e["s"] == 200 for e in entries), entries

      with subtest("rejections leave pins intact"):
          before = selene.succeed(f"readlink {PINS}/gate/x86_64-linux/latest")
          push(bundle("u", key=None))
          # Signed, but by a key that is not the repo's (real ed25519 signatures).
          push(bundle("w", key="/etc/nix-cache-vm/wrong.sk"))
          # A wrong-key signature relabelled with the repo key's name: only the
          # daemon-side crypto check (nix store verify) can catch it.
          push(bundle("x", key="/etc/nix-cache-vm/wrong.sk", tamper="s/^Sig: vmtest-wrong-1:/Sig: vmtest-repo-1:/"))
          # A path-less bundle (A is already cached) needs no signature, so
          # only the repo's set allowlist stops it from opening a namespace.
          other = bundle("a", set_="other")
          assert ci.succeed(f"jq '.paths | length' {other}/manifest.json").strip() == "0"
          push(other)
          wait_imported()
          assert len(reasons()) == 4, reasons()
          selene.succeed(f"grep -l 'carry no signature' {DROP}/failed/*.reason | wc -l | grep -qx 2")
          selene.succeed(f"grep -q 'signature or content check failed' {DROP}/failed/*.reason")
          selene.succeed(f"grep -q \"set 'other' is not allowed for vmtest\" {DROP}/failed/*.reason")
          selene.fail(f"test -e {PINS}/other")
          assert selene.succeed(f"readlink {PINS}/gate/x86_64-linux/latest") == before
          for p in ["${payloadU}", "${payloadW}", "${payloadX}"]:
              assert not valid(selene, p)
          selene.wait_until_succeeds("journalctl -t nix-cache-alert | grep >/dev/null 'rejected bundle from vmtest'")

      with subtest("a truncated upload is rejected into failed/"):
          before_reasons = reasons()
          before = selene.succeed(f"readlink {PINS}/gate/x86_64-linux/latest")
          ci.succeed("nix-cache-push-bundle /tmp/bundle-a cat > /tmp/full.tar.zst")
          size = int(ci.succeed("stat -c %s /tmp/full.tar.zst"))
          assert ci.succeed(f"head -c {size // 2} /tmp/full.tar.zst | {SSH}").strip() == "ok"
          wait_imported()
          new = reasons() - before_reasons
          assert len(new) == 1, new
          (reason,) = new
          print(selene.succeed(f"cat {DROP}/failed/{reason}"))
          selene.succeed(f"test -f {DROP}/failed/{reason.removesuffix('.reason')}")
          assert selene.succeed(f"readlink {PINS}/gate/x86_64-linux/latest") == before

      with subtest("bursts of uploads and alerts do not trip systemd start limits"):
          # Deterministic part: the finite, generous limit is what the units got.
          for unit in ["cache-importer-vmtest.service", "nix-cache-alert.service"]:
              shown = selene.succeed(f"systemctl show -p StartLimitBurst -p StartLimitIntervalUSec {unit}").split()
              assert sorted(shown) == ["StartLimitBurst=100", "StartLimitIntervalUSec=1min"], (unit, shown)
          # Smoke part (timing-dependent, so not proof on its own):
          # Seven quick rejected uploads: seven importer runs and seven alert
          # deliveries within a few seconds (the default limit is 5 per 10 s).
          before_reasons = reasons()
          delivered = "journalctl -t nix-cache-alert -o cat | grep -c '^nix-cache: rejected bundle from vmtest$'"
          alerts_before = int(selene.succeed(delivered))
          for i in range(7):
              assert ci.succeed(f"printf junk-{i} | {SSH}").strip() == "ok"
              wait_imported()
          assert len(reasons() - before_reasons) == 7
          selene.succeed("systemctl is-active cache-importer-vmtest.path nix-cache-alert.path")
          selene.wait_until_succeeds(f"test \"$({delivered})\" -eq {alerts_before + 7}", timeout=60)
          selene.succeed("systemctl is-active nix-cache-alert.path")

      with subtest("a repo field in the manifest is ignored"):
          push(bundle("r", set_="forged", edit_manifest='. + {repo: "other"}'))
          wait_imported()
          selene.succeed(f"test -L {PINS}/forged/x86_64-linux/latest")
          selene.fail("test -e /nix/var/nix/gcroots/cache/pins/other")

      with subtest("401 from the cache is skipped, not fatal"):
          consumer.succeed("nix copy --to file:///var/local-cache ${payloadC}")
          consumer.succeed("nix-store --delete ${payloadC} ${payloadA}")
          # First contact: without the narinfo cache from earlier subtests, the
          # nix-cache-info and narinfo lookups themselves get the 401.
          consumer.succeed("rm -f /root/.cache/nix/binary-cache-v*.sqlite*")
          offset = int(selene.succeed(f"stat -c %s {ACCESS_LOG}"))
          consumer.succeed(
              "nix-store --realise ${payloadC} --option netrc-file /etc/nix-cache-vm/bad-netrc"
              " --option substituters 'https://${host} file:///var/local-cache?priority=90'"
          )
          assert valid(consumer, "${payloadC}")
          lines = selene.succeed(f"tail -c +{offset + 1} {ACCESS_LOG}").splitlines()
          entries = [json.loads(line) for line in lines if line.strip()]
          print(entries)
          assert entries and all(e["s"] == 401 and e["u"] == "consumer-g1" for e in entries), entries

      with subtest("retired token generation: stale-token alert from the sandboxed pruner"):
          # ci-vmtest-g1 has succeeded before (the bundler's probes), so it has
          # a users row. Retire its generation the way a rotation does: keep the
          # user name, replace the hash with one of a throwaway token.
          assert code(ci, f"-u ci-vmtest-g1:${tokens.ci1} {URL}/nix-cache-info") == "200"
          retired = selene.succeed("nix-cache-htpasswd-entry ci-vmtest-g1 --new").splitlines()[1]
          selene.succeed(
              f"grep -v '^ci-vmtest-g1:' {HTPASSWD} > {HTPASSWD}.new && echo '{retired}' >> {HTPASSWD}.new"
              f" && chown root:nginx {HTPASSWD}.new && chmod 0640 {HTPASSWD}.new && mv {HTPASSWD}.new {HTPASSWD}"
          )
          for _ in range(25):
              assert code(ci, f"-u ci-vmtest-g1:${tokens.ci1} {URL}/nix-cache-info") == "401"
          selene.succeed("grep -q 'user \"ci-vmtest-g1\": password mismatch' /var/log/nginx/nix-cache.error.log")
          # The real, sandboxed unit (PrivateNetwork, ProtectSystem=strict): it
          # reaches the daemon socket and rewrites its keep roots.
          # No pruner has run yet (its timer is off), so keep roots prove this run.
          selene.succeed("test -z \"$(ls -d /nix/var/nix/gcroots/cache/keep.* 2>/dev/null)\"")
          selene.succeed("systemctl start cache-pruner.service")
          keeps = selene.succeed("ls -d /nix/var/nix/gcroots/cache/keep.*").split()
          assert len(keeps) == 1, keeps
          selene.succeed(f"test -d {keeps[0]} && test -n \"$(ls -A {keeps[0]})\"")
          selene.wait_until_succeeds("journalctl -t nix-cache-alert | grep >/dev/null 'stale read token'")
          selene.succeed("journalctl -t nix-cache-alert | grep >/dev/null 'ci-vmtest-g1: 25 rejected requests'")
          selene.wait_until_succeeds(
              "test \"$(systemctl show -p ActiveState --value cache-gc.service)\" = inactive", timeout=120
          )

      with subtest("retention: tiered keep, old pin dropped, GC removes only unrooted paths"):
          future = int(selene.succeed("date +%s")) + 120
          print(pruner(f"--now {future} --protect-hours 0 --budget-bytes 1"))
          # Over budget: only the active namespaces' latest closures survive.
          assert selene.succeed(f"ls {PINS}/gate/x86_64-linux | grep -v latest | wc -l").strip() == "1"
          for ns in ["gate", "many", "forged"]:
              selene.succeed(f"test -d {PINS}/{ns}/x86_64-linux/$(readlink {PINS}/{ns}/x86_64-linux/latest)")
          selene.succeed("systemctl start cache-gc.service")
          assert valid(selene, "${payloadC}") and valid(selene, "${payloadA}")
          assert not valid(selene, "${payloadA.dev}")
          assert all(valid(selene, p) for p in MANY) and valid(selene, "${payloadR}")

      with subtest("expired namespaces lose protection"):
          future = int(selene.succeed("date +%s")) + 120
          print(pruner(f"--now {future} --protect-hours 0 --budget-bytes 1 --active-days 0"))
          selene.fail(f"test -e {PINS}/gate")
          selene.succeed("systemctl start cache-gc.service")
          assert not valid(selene, "${payloadC}")
          selene.wait_until_succeeds("journalctl -t nix-cache-alert | grep >/dev/null 'namespace expired'")

      with subtest("fail2ban bans unknown token users, never a known user with a wrong token"):
          # ci sent 25 password-mismatch requests above. fail2ban reads the
          # error log in order, so once it bans the consumer (later lines) it
          # has seen all of ci's lines too.
          assert not banned("${ciIP}")
          for _ in range(6):
              consumer.execute(f"curl -s -o /dev/null -u nobody-g1:${tokens.consumer1} {URL}/nix-cache-info")
          selene.wait_until_succeeds("fail2ban-client status nix-cache-guess | grep -wF '${consumerIP}' >/dev/null", timeout=60)
          assert not banned("${ciIP}")
          assert code(ci, f"-u consumer-g2:${tokens.consumer2} {URL}/nix-cache-info") == "200"

      # The guard subtests come last: the retention subtests above expired every
      # namespace, and these only need a working push path for ci again.
      with subtest("guards: ci token restored, consumer unbanned (stale-token and fail2ban subtests)"):
          selene.succeed("fail2ban-client set nix-cache-guess unbanip ${consumerIP}")
          assert code(consumer, f"-u consumer-g1:${tokens.consumer1} {URL}/nix-cache-info") == "200"
          selene.succeed(
              f"grep -v '^ci-vmtest-g1:' {HTPASSWD} > {HTPASSWD}.new"
              f" && printf %s ${tokens.ci1} | nix-cache-htpasswd-entry ci-vmtest-g1 >> {HTPASSWD}.new"
              f" && chown root:nginx {HTPASSWD}.new && chmod 0640 {HTPASSWD}.new && mv {HTPASSWD}.new {HTPASSWD}"
          )
          assert code(ci, f"-u ci-vmtest-g1:${tokens.ci1} {URL}/nix-cache-info") == "200"

      with subtest("a root that is neither bundled nor on the host is rejected without a download"):
          before_reasons = reasons()
          pins_before = pin_count()
          push(bundle("n", strip=True))
          wait_imported()
          new = reasons() - before_reasons
          assert len(new) == 1, new
          (reason,) = new
          selene.succeed(f"grep -q 'root(s) are neither in the bundle nor on this host' {DROP}/failed/{reason}")
          selene.succeed(f"grep -q '${payloadN}' {DROP}/failed/{reason}")
          assert pin_count() == pins_before
          assert not valid(selene, "${payloadN}")
          selene.wait_until_succeeds(
              "journalctl -t nix-cache-alert | grep >/dev/null 'neither in the bundle nor on this host'", timeout=60
          )

      with subtest("fetch_estimate parses real nix dry-run output"):
          assert push(bundle("e")).strip() == "ok"
          wait_imported()
          assert valid(selene, "${payloadE}")
          est = "PYTHONPATH=${pkgSitePackages} python3 -c 'import sys; from nix_cache import nixcli; print(nixcli.fetch_estimate(sys.argv[1:]))'"
          assert not valid(consumer, "${payloadE}")
          n = int(consumer.succeed(f"{est} ${payloadE}").strip())
          print(f"estimate for ${payloadE}: {n}")
          # NAR of one 1-byte file: a few hundred bytes. The estimate rounds
          # a "0.x KiB" report up, so it is positive and small.
          assert 0 < n < 64 * 1024, n
          assert int(consumer.succeed(f"{est}").strip()) == 0
          # The estimator is only for invalid paths: a valid one has no
          # "will be fetched" line, and that must fail closed, not read as 0.
          consumer.succeed("nix-store --realise ${payloadE}")
          assert valid(consumer, "${payloadE}")
          status, out = consumer.execute(f"{est} ${payloadE} 2>&1")
          assert status != 0 and "printed no fetch summary" in out, (status, out)

      with subtest("an import over the budget or under the free-space floor is rejected before any copy"):
          selene.succeed("systemctl stop cache-importer-vmtest.path")
          try:
              for key, value, message in [
                  ("budget_bytes", 1, "over the budget of 1"),
                  ("import_min_free_bytes", 1 << 50, f"below the floor of {1 << 50}"),
              ]:
                  alt = f"/tmp/config-{key}.json"
                  selene.succeed(
                      f"jq '.{key} = {value}' /etc/nix-cache/config.json > {alt} && chmod 0644 {alt}"
                  )
                  assert ci.succeed(f"cat {bundle('b')}/manifest.json | jq -r '.paths | length'").strip() == "1"
                  push("/tmp/bundle-b")
                  before_reasons = reasons()
                  pins_before = pin_count()
                  out = importer_by_hand(alt)
                  assert message in out, out
                  new = reasons() - before_reasons
                  assert len(new) == 1, new
                  selene.succeed(f"grep -q '{message}' {DROP}/failed/{next(iter(new))}")
                  assert not valid(selene, "${payloadB}")
                  assert pin_count() == pins_before
                  selene.succeed(f"test -z \"$(ls -A {DROP}/incoming)\"")
          finally:
              selene.succeed("systemctl start cache-importer-vmtest.path")

      with subtest("pruner disk alert fires at disk_alert_percent"):
          # The VM store is a 1 GB overlay that is nearly empty (0.0% used), so
          # put 32 MB on its backing filesystem (3%) to cross a 1% threshold; removed afterwards.
          selene.succeed("jq '.disk_alert_percent = 1' /etc/nix-cache/config.json > /tmp/config-disk.json && chmod 0644 /tmp/config-disk.json")
          delivered = "journalctl -t nix-cache-alert -o cat | grep -c '^nix-cache: disk filling$'"
          assert int(selene.execute(delivered)[1]) == 0
          selene.succeed("fallocate -l 32M /nix/.rw-store/vm-disk-fill")
          try:
              selene.succeed(
                  "systemd-run --wait --collect --pipe -p User=nix-cache -p SupplementaryGroups=nginx"
                  " -p Environment=HOME=/var/lib/nix-cache -p Environment=PATH=/run/current-system/sw/bin"
                  " /run/current-system/sw/bin/cache-pruner --config /tmp/config-disk.json"
              )
              selene.wait_until_succeeds(f"test \"$({delivered})\" -ge 1", timeout=60)
          finally:
              selene.succeed("rm -f /nix/.rw-store/vm-disk-fill")
    '';
  }
