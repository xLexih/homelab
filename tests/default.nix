# End-to-end test: boots tests/cluster.nix from the real node modules and
# drives it with the generated CLI from a separate deployer VM.
# Run alone with: nix build .#checks.x86_64-linux.vm -L
{
  inputs,
  lib,
  pkgs,
  clusterLib,
}: let
  cluster = clusterLib.checked "vmtest" ./cluster.nix;
  secrets = ./secrets;
  # Test-only key; it protects nothing but these fixtures.
  adminKey = ./insecure-admin-key;
  cli = pkgs.callPackage ../lib/cli.nix {
    inherit cluster secrets;
    secretsDir = "tests/secrets";
  };

  hostKey = name:
    pkgs.runCommand "${name}-ssh-host-key" {nativeBuildInputs = [pkgs.age];} ''
      age -d -i ${adminKey} ${secrets}/hosts/${name}/ssh-key.age > $out
    '';

  # Chart images; the VMs have no internet. Update together with the charts.
  # Images are imported by tag, so the test turns off Cilium's digest pins.
  images = map pkgs.dockerTools.pullImage [
    {
      imageName = "coredns/coredns";
      imageDigest = "sha256:0a9d8c8ddf34347eb59aad9a8784f0710de88d6d112726d11d271f9bc6daca26";
      hash = "sha256-VgorHUi+sJG1zMN+pLjedYbG3owsv3J7IZSM4ggr1X8=";
      finalImageTag = "1.15.0";
    }
    {
      imageName = "quay.io/cilium/cilium";
      imageDigest = "sha256:20fe92e4c86641233a450098c158d2d29085f3419931ab6bf681d2485dedf16e";
      hash = "sha256-M06MP/wfhwGKQ8jT4yRtcOOc8zogFPs5S9tXR25qbiw=";
      finalImageTag = "v1.20.4";
    }
    {
      imageName = "quay.io/cilium/operator-generic";
      imageDigest = "sha256:7a7a3489dc66ad67e420d285c8a8d2e169b0957ad15e120f593d27081bf38d82";
      hash = "sha256-bgn2f6qNHAtH0g3Cfq1Wvz+ZZAlgx9TwbMTQBDu/YjA=";
      finalImageTag = "v1.20.4";
    }
  ];

  # /cgi-bin/ip answers "<client address> <pod name>"
  web = pkgs.dockerTools.buildImage {
    name = "web";
    tag = "test";
    copyToRoot = [pkgs.busybox];
    extraCommands = ''
      mkdir -p srv/cgi-bin
      echo hello > srv/index.html
      cat > srv/cgi-bin/ip <<'EOF'
      #!/bin/sh
      printf 'Content-Type: text/plain\r\n\r\n%s %s\n' "$REMOTE_ADDR" "$(hostname)"
      EOF
      chmod +x srv/cgi-bin/ip
    '';
    config.Cmd = ["httpd" "-f" "-p" "0.0.0.0:8080" "-h" "/srv"];
  };

  json = name: items:
    (pkgs.formats.json {}).generate name {
      apiVersion = "v1";
      kind = "List";
      inherit items;
    };
  labels.app = "web";
  webApp = json "web.json" [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = "web";
    }
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        name = "web";
        namespace = "web";
      };
      spec = {
        # on two nodes, so some requests cross from the announcing node
        replicas = 2;
        selector.matchLabels = labels;
        template = {
          metadata = {inherit labels;};
          spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = [
            {
              topologyKey = "kubernetes.io/hostname";
              labelSelector.matchLabels = labels;
            }
          ];
          spec.containers = [
            {
              name = "web";
              image = "web:test";
              imagePullPolicy = "Never";
              # the kubelet's probe has to get through the default-deny policy
              readinessProbe.httpGet = {
                path = "/";
                port = 8080;
              };
            }
          ];
        };
      };
    }
    {
      apiVersion = "v1";
      kind = "Service";
      metadata = {
        name = "web";
        namespace = "web";
      };
      spec = {
        type = "LoadBalancer";
        selector = labels;
        ports = [
          {
            port = 80;
            targetPort = 8080;
          }
        ];
      };
    }
  ];
  allowWeb = json "allow-web.json" [
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "NetworkPolicy";
      metadata = {
        name = "allow-web";
        namespace = "web";
      };
      spec = {
        podSelector.matchLabels = labels;
        ingress = [{ports = [{port = 8080;}];}];
      };
    }
  ];

  # the etcd member list k3s hands to joining servers
  etcdMembers = "curl -sSfk -u server:$(cat /run/agenix/k3s-token) https://10.100.0.2:6443/db/info";

  testNode = node: {config, ...}: {
    imports = clusterLib.nodeModules cluster secrets node;
    virtualisation = {
      memorySize =
        if lib.elem "server" node.roles
        then 1536
        else 1280;
      diskSize = 4096;
      cores = 2;
    };
    disko.enableConfig = false;
    # `install` puts the host key in place before the first boot.
    environment.etc."ssh/ssh_host_ed25519_key" = {
      source = hostKey node.name;
      mode = "0600";
    };
    age.identityPaths = lib.mkForce ["${hostKey node.name}"];
    services.k3s.images = [config.services.k3s.package.airgap-images] ++ images;
    services.k3s.autoDeployCharts.cilium = lib.mkIf (lib.elem "server" node.roles) {
      extraFieldDefinitions.spec.set = {
        "image.useDigest" = "false";
        "operator.image.useDigest" = "false";
      };
    };
    environment.systemPackages = [pkgs.curl];
    # the test framework's console password; the backdoor shell does not need it
    users.users.root.hashedPasswordFile = lib.mkForce null;
  };
in
  pkgs.testers.runNixOSTest {
    name = "cluster";
    node.specialArgs = {inherit inputs;};

    nodes =
      lib.mapAttrs (_: testNode) cluster.nodes
      // {
        deployer = {
          virtualisation.memorySize = 512;
          networking.interfaces.eth1.ipv4.addresses = [
            {
              address = "10.0.0.250";
              prefixLength = 24;
            }
          ];
          environment.systemPackages = [cli pkgs.curl pkgs.frr];
          # the cluster's BGP peer; learns routes without installing them,
          # so curl below still goes through the ARP announcement
          services.frr = {
            bgpd = {
              enable = true;
              extraOptions = ["--no_kernel"];
            };
            config = ''
              router bgp 65000
                bgp router-id 10.0.0.250
                no bgp ebgp-requires-policy
                neighbor cluster peer-group
                neighbor cluster remote-as 65100
                bgp listen range 10.0.0.0/24 peer-group cluster
            '';
          };
          networking.firewall.allowedTCPPorts = [179];
        };
      };

    testScript = ''
      import json

      def ready(machine, node):
          machine.wait_until_succeeds(f"k3s kubectl get node {node} | grep -w Ready", timeout=600)

      s1.start()
      ready(s1, "s1")
      s2.start()
      s3.start()
      ready(s1, "s2")
      ready(s1, "s3")

      with subtest("a node joins while the init server is down"):
          s1.crash()
          a1.start()
          ready(s2, "a1")

      deployer.start()
      deployer.succeed("install -Dm600 ${adminKey} /root/.ssh/id_ed25519")
      deployer.wait_until_succeeds("ping -c1 -W1 10.0.0.2", timeout=60)

      with subtest("the CLI reaches nodes through their pinned host keys"):
          assert deployer.succeed("vmtest ssh s2 hostname").strip() == "s2"
          deployer.succeed("vmtest kubeconfig")
          deployer.succeed("grep -q 'server: https://127.0.0.1:6443' /root/.kube/vmtest.yaml")
          deployer.succeed("vmtest image ${web} s2 s3 a1")
          deployer.wait_until_succeeds("vmtest status | grep -E '^cilium +installed$'", timeout=300)

      with subtest("a new namespace is closed until a policy opens it"):
          s2.succeed("k3s kubectl apply -f ${webApp}")
          s2.wait_until_succeeds("k3s kubectl -n web get networkpolicy default-deny", timeout=60)
          s2.wait_until_succeeds("k3s kubectl -n web rollout status deploy/web --timeout=10s", timeout=300)
          s2.wait_until_succeeds(
              "k3s kubectl -n web get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -x 10.0.0.200",
              timeout=300,
          )
          s2.wait_until_succeeds("k3s kubectl -n web exec deploy/web -- nslookup kubernetes.default.svc.cluster.local", timeout=180)
          deployer.fail("curl -sf --max-time 5 http://10.0.0.200/")
          s2.succeed("k3s kubectl apply -f ${allowWeb}")
          deployer.wait_until_succeeds("curl -sf --max-time 5 http://10.0.0.200/ | grep -x hello", timeout=60)

      with subtest("pods see the client's address through the LoadBalancer"):
          backends = set()
          for _ in range(20):
              client, pod = deployer.succeed("curl -sf --max-time 5 http://10.0.0.200/cgi-bin/ip").split()
              assert client == "10.0.0.250", f"{pod} saw {client}"
              backends.add(pod)
          # one backend is not on the announcing node: that request took DSR
          assert len(backends) == 2, backends

      with subtest("BGP advertises the address to the router"):
          deployer.wait_until_succeeds("vtysh -c 'show ip bgp' | grep -F 10.0.0.200/32", timeout=180)

      with subtest("without default-deny, pods see each other's addresses and NodePorts stay on the mesh"):
          s2.succeed("k3s kubectl label namespace web default-deny=off")
          s2.wait_until_fails("k3s kubectl -n web get networkpolicy default-deny", timeout=60)
          (a, a_ip), (_, b_ip) = [
              (p["metadata"]["name"], p["status"]["podIP"])
              for p in json.loads(s2.succeed("k3s kubectl -n web get pods -l app=web -o json"))["items"]
          ]
          seen = s2.wait_until_succeeds(f"k3s kubectl -n web exec {a} -- wget -qO- http://{b_ip}:8080/cgi-bin/ip", timeout=60).split()[0]
          assert seen == a_ip, f"saw {seen} instead of {a_ip}"
          port = s2.succeed("k3s kubectl -n web get svc web -o jsonpath='{.spec.ports[0].nodePort}'").strip()
          s3.wait_until_succeeds(f"curl -sf --max-time 5 http://10.100.0.2:{port}/ | grep -x hello", timeout=60)
          deployer.fail(f"curl -sf --max-time 5 http://10.0.0.2:{port}/")

      with subtest("remove drains and deletes a live agent"):
          deployer.succeed("vmtest remove a1")
          a1.fail("systemctl is-active k3s")
          s2.fail("k3s kubectl get node a1")
          s2.wait_until_succeeds("k3s kubectl -n web rollout status deploy/web --timeout=10s", timeout=300)

      def etcd_members():
          return len(json.loads(s2.succeed("${etcdMembers}"))["members"])

      with subtest("remove deletes a dead server and its etcd member"):
          assert etcd_members() == 3
          deployer.succeed("vmtest remove s1")
          s2.fail("k3s kubectl get node s1")
          retry(lambda _: etcd_members() == 2, timeout_seconds=120)
    '';
  }
