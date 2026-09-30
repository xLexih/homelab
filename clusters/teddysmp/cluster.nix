# Single-node cluster in a Proxmox LXC container, reachable as teddysmp.com.
{
  stateVersion = "26.05";
  vip = "192.168.2.150";

  network = {
    serviceCIDR = "10.44.0.0/16";
    podCIDR = "10.45.0.0/16";
    wgCIDR = "10.101.0.0/24";
  };

  nodes.teddysmp = {
    platform = "lxc";
    roles = ["server"];
    wgIP = "10.101.0.1";
    address = "192.168.2.100/24";
    gateway = "192.168.2.1";
    interface = "eth0";
    endpoint = "teddysmp.com";
  };
}
