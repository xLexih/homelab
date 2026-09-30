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
  images = map pkgs.dockerTools.pullImage [
    {
      imageName = "coredns/coredns";
      imageDigest = "sha256:7efd3c635b03efd68c4e8398fc45f0d993d0e9ab016f72c1cefb0fd6d01aa286";
      hash = "sha256-sTDGI3KRCsB8Q8G5QHfDc2nDsg8FYNJ4fIxuGhsRUFU=";
      finalImageTag = "1.14.7";
    }
    {
      imageName = "quay.io/metallb/controller";
      imageDigest = "sha256:f51ab515de9ccd20dc3dccb093e48df8adddac019326c456f449e55ba91b6420";
      hash = "sha256-xMUYC0LdL0WR3lJHAfRcd70v4AXr3xW3IJaaYm1P9fo=";
      finalImageTag = "v0.16.1";
    }
    {
      imageName = "quay.io/metallb/speaker";
      imageDigest = "sha256:16561e96531e1852d5c229ad7fae6e994dcfa983ff7f4de6b6208b34a4e2ddbc";
      hash = "sha256-8Zt86xIoSeF3TkftWQjKioIDQOB7KTArbzDTU40gxG0=";
      finalImageTag = "v0.16.1";
    }
  ];

  web = pkgs.dockerTools.buildImage {
    name = "web";
    tag = "test";
    copyToRoot = [pkgs.busybox];
    extraCommands = "mkdir srv && echo hello > srv/index.html";
    config.Cmd = ["httpd" "-f" "-p" "8080" "-h" "/srv"];
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
        selector.matchLabels = labels;
        template = {
          metadata = {inherit labels;};
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
        then 1280
        else 1024;
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
          environment.systemPackages = [cli pkgs.curl];
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
          s2.succeed("k3s kubectl label namespace web default-deny=off")
          s2.wait_until_fails("k3s kubectl -n web get networkpolicy default-deny", timeout=60)

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
