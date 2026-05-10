{pkgs, ...}: {
  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernelModules = [
    "br_netfilter" # allow iptables to filter bridged traffic
    "nf_conntrack" # connection tracking
    "overlay" # container overlay filesystem
    "bpf" # Cilium BPF datapath
  ];

  boot.kernelParams = [
    "cgroup_memory_noswap=1" # cgroup v1 compat (harmless on v2)
    "log_buf_len=10M" # larger kernel log buffer for diagnostics
    "net.core.bpf_jit_enable=1" # enable BPF JIT (Cilium)
    "net.core.bpf_jit_harden=1" # JIT hardening
  ];

  # Kubernetes node tuning: memory, disk I/O, networking, file handles, conntrack
  boot.kernel.sysctl = {
    # Memory & reclaim
    "vm.swappiness" = 10; # prefer RAM over swap for containers
    "vm.overcommit_memory" = 1; # allow overcommit for bursty workloads
    "vm.overcommit_ratio" = 100; # percentage of RAM + swap allowed
    "vm.panic_on_oom" = 0; # let OOM killer handle memory exhaustion
    "vm.dirty_ratio" = 40; # % of RAM dirty before forced writeback
    "vm.dirty_background_ratio" = 10; # % of RAM dirty before background flush
    "vm.dirty_expire_centisecs" = 3000; # keep dirty data in memory up to 30s (smooth I/O)
    "vm.dirty_writeback_centisecs" = 1500; # flush daemon interval (15s, reduces small writes)
    "vm.min_free_kbytes" = 262144; # reserve 256 MB for critical allocations
    "vm.zone_reclaim_mode" = 0; # do not reclaim local pages aggressively
    "vm.max_map_count" = 262144; # enough memory mappings for many containers

    # Connection tracking
    "net.netfilter.nf_conntrack_max" = 1048576; # large table for many connections
    "net.netfilter.nf_conntrack_tcp_timeout_established" = 86400; # keep established for 24h
    "net.netfilter.nf_conntrack_tcp_timeout_close_wait" = 3600; # keep close_wait for 1h

    # Core socket buffers
    "net.core.rmem_max" = 16777216; # 16 MB receive
    "net.core.wmem_max" = 16777216; # 16 MB send
    "net.core.rmem_default" = 262144; # 256 KB default receive
    "net.core.wmem_default" = 262144; # 256 KB default send
    "net.core.netdev_max_backlog" = 65536; # input queue for kernel rx processing
    "net.core.somaxconn" = 32768; # max pending connections per socket
    "net.core.default_qdisc" = "fq"; # Fair Queue qdisc required for BBR pacing / Cilium bandwidth manager

    # TCP settings
    "net.ipv4.tcp_rmem" = "4096 87380 16777216"; # min, default, max receive buffers
    "net.ipv4.tcp_wmem" = "4096 65536 16777216"; # min, default, max send buffers
    "net.ipv4.tcp_congestion_control" = "bbr"; # BBR congestion control
    "net.ipv4.tcp_notsent_lowat" = 16384; # reduce latency for unsent data
    "net.ipv4.tcp_fin_timeout" = 30; # shorten FIN timeout
    "net.ipv4.tcp_keepalive_time" = 1200; # 20 min keepalive
    "net.ipv4.tcp_keepalive_intvl" = 30; # retry interval
    "net.ipv4.tcp_keepalive_probes" = 5; # retry count
    "net.ipv4.ip_local_port_range" = "1024 65535"; # available local ports

    # TCP extensions for cluster networking
    "net.ipv4.tcp_max_syn_backlog" = 32768; # match somaxconn
    "net.ipv4.tcp_slow_start_after_idle" = 0; # don't reset cwnd after idle (keep-alive friendly)
    "net.ipv4.tcp_mtu_probing" = 1; # PMTU discovery (helps with Geneve+WireGuard)
    "net.ipv4.tcp_tw_reuse" = 1; # reuse TIME_WAIT sockets (reduces port exhaustion)
    "net.ipv4.tcp_retries2" = 7; # abandon dead connections after ~100s (Longhorn iSCSI)

    # Bridge netfilter (Kubernetes policy enforcement)
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.bridge.bridge-nf-call-arptables" = 1;

    # Forwarding (node acts as router)
    "net.ipv4.conf.all.forwarding" = 1;
    "net.ipv6.conf.all.forwarding" = 1;

    # File handle and inotify limits (container engines, Longhorn)
    "fs.file-max" = 2097152;
    "fs.nr_open" = 2097152;
    "fs.inotify.max_user_watches" = 524288;
    "fs.inotify.max_user_instances" = 8192;
    "fs.inotify.max_queued_events" = 65536;
    "fs.epoll.max_user_watches" = 524288;

    # PID limits for large number of containers
    "kernel.pid_max" = 4194304;
    "kernel.threads-max" = 4194304;
    "kernel.kptr_restrict" = 1; # security: restrict kernel pointer visibility
    "kernel.numa_balancing" = 0; # disable on VMs (NUMA topology is virtual)
  };

  # k3s service needs high file descriptor limit
  systemd.services.k3s.serviceConfig = {
    LimitNOFILE = 1048576;
  };

  # PAM limits for all users
  security.pam.loginLimits = [
    {
      domain = "*";
      type = "soft";
      item = "nofile";
      value = "1048576";
    }
    {
      domain = "*";
      type = "hard";
      item = "nofile";
      value = "1048576";
    }
  ];

  hardware.ksm.enable = true; # Kernel Same-Page Merging for memory dedup (Proxmox)

  # Small swap file to avoid immediate OOM kills; swappiness=10 makes it a last resort
  swapDevices = [
    {
      device = "/var/swap";
      size = 2048;
    }
  ];
}
