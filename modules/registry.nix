# The cluster's image registry; settings and defaults are the `registry`
# option (lib/options.nix). Pods name images <host>/<name>; nodes can't resolve
# that, so k3s.nix mirrors it to the LoadBalancer address, which only the
# nodes may reach. Nothing on the LAN can push: pushes go through the API
# server with `kubectl port-forward`, where docker trusts 127.0.0.1 over HTTP.
{
  lib,
  pkgs,
  cluster,
  node,
  ...
}: let
  reg = cluster.registry;
  name = reg.namespace; # also the Service, Deployment, volume and app label
  port = toString reg.port;
in
  lib.mkIf (reg != null && lib.elem "server" node.roles) {
    # k3s retries a manifest until it applies (the policy needs Cilium's CRDs)
    services.k3s.manifests.registry.source = pkgs.writeText "registry.yaml" ''
      apiVersion: v1
      kind: Namespace
      metadata: {name: ${name}, labels: {pod-security.kubernetes.io/enforce: restricted}}
      ---
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata: {name: ${name}, namespace: ${name}}
      spec: {accessModes: [ReadWriteOnce], storageClassName: longhorn, resources: {requests: {storage: "${reg.size}"}}}
      ---
      apiVersion: apps/v1
      kind: Deployment
      metadata: {name: ${name}, namespace: ${name}}
      spec:
        strategy: {type: Recreate} # one volume, one writer
        selector: {matchLabels: {app: ${name}}}
        template:
          metadata: {labels: {app: ${name}}}
          spec:
            securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: {type: RuntimeDefault}}
            containers:
              - name: registry
                image: "${reg.image}"
                env: [{name: REGISTRY_LOG_LEVEL, value: info}, {name: REGISTRY_HTTP_ADDR, value: ":${port}"}]
                ports: [{name: registry, containerPort: ${port}}]
                readinessProbe: {httpGet: {path: /v2/, port: registry}}
                resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 512Mi}}
                securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
                volumeMounts: [{name: data, mountPath: /var/lib/registry}]
            volumes: [{name: data, persistentVolumeClaim: {claimName: ${name}}}]
      ---
      apiVersion: v1
      kind: Service
      metadata: {name: ${name}, namespace: ${name}, annotations: {lbipam.cilium.io/ips: "${reg.address}"}}
      spec: {type: LoadBalancer, selector: {app: ${name}}, ports: [{name: registry, port: ${port}, targetPort: registry}]}
      ---
      # on top of the namespace's default-deny: the nodes' containerd only
      apiVersion: cilium.io/v2
      kind: CiliumNetworkPolicy
      metadata: {name: ${name}-nodes, namespace: ${name}}
      spec:
        endpointSelector: {matchLabels: {app: ${name}}}
        ingress: [{fromEntities: [host, remote-node], toPorts: [{ports: [{port: "${port}", protocol: TCP}]}]}]
    '';
  }
