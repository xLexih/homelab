{
  lib,
  clusterConfig,
  helpers,
  nodeConfig,
  ...
}: let
  isInit = nodeConfig.init;
  isMaster = helpers.hasRole "master" nodeConfig;
  apiPort = toString clusterConfig.network.apiServerPort;
in
  # Non-init masters use this HAProxy to reach the API server.
  # k3s is configured to point to localhost:6443, which is then load-balanced
  # across all masters over the WireGuard overlay for API server HA.
  lib.mkIf (!isInit && isMaster) {
    services.haproxy.enable = true;
    services.haproxy.config = ''
      global
        maxconn 2000                # protect LB from connection exhaustion

      defaults
        mode tcp
        option tcp-check
        timeout connect 5s
        timeout client 50s          # longer timeout for slow etcd responses
        timeout server 50s          # matching server-side timeout
        timeout check 5s            # explicit check timeout, avoids accidental breakage
        timeout tunnel 10m          # keep kubectl exec/logs/port-forward alive
        default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256

      frontend k3s-api
        bind 127.0.0.1:${apiPort}
        default_backend k3s-masters

      backend k3s-masters
        balance roundrobin
        ${lib.concatStringsSep "\n  " (map (ip: "server ${ip} ${ip}:${apiPort} check") helpers.masterWgIPs)}
    '';

    systemd.services.haproxy = {
      after = ["wireguard-wg0.service"];
      requires = ["wireguard-wg0.service"];
      before = ["k3s.service"];
      wantedBy = ["multi-user.target"];
    };
  }
