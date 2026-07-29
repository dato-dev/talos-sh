# talos.sh

A single Bash script to bootstrap a [Talos Linux](https://www.talos.dev/) cluster and to add nodes to a running one, without the footguns.

No dependencies beyond `talosctl` and Bash. Runs on the stock macOS Bash 3.2.

## Why

Adding a node to a live Talos cluster is easy to get wrong, and every wrong way is destructive:

- **`talosctl gen config` generates a fresh set of secrets.** Applying such a config to a new node produces a PKI incompatible with the running cluster — the node never joins.
- **`talosctl bootstrap` on an already-initialized cluster destroys etcd.** It must run exactly once, on one node, ever.
- **A config snapshotted from a live node carries that node's own network settings.** If the source node has a static address, every new node gets *its* IP. Three machines answering on one address is a bad afternoon.
- **`talosctl upgrade` does not rewrite `machine.install.image`.** After a few upgrades the field lags behind reality, and a new node installs an old version into a newer cluster.
- **Regenerating a config from scratch loses customizations.** If your cluster runs Cilium with `cni: none` and `proxy.disabled: true`, a freshly generated config puts flannel and kube-proxy back and breaks the network.

`talos.sh` splits the two workflows into separate commands so they cannot be confused, derives configs from the live cluster instead of regenerating them, and refuses to run when the preconditions are not met.

## Requirements

- `talosctl` in `PATH`, ideally matching your cluster's minor version
- Bash 3.2 or newer
- Target nodes booted from a Talos ISO and reachable in maintenance mode
- For `join`: a working `talosconfig` with access to the cluster

Node provisioning is out of scope — bring your own VMs, whether from Terraform, Proxmox, bare metal, or anywhere else.

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/<you>/talos-sh/main/talos.sh && chmod +x talos.sh
```

## Usage

Every option has a short and a long form, and `--opt=value` works too.

```
talos.sh bootstrap --controlplane <ips> [--workers <ips>] [options]
talos.sh join --endpoint <ip> [--controlplane <ips>] [--workers <ips>] [options]
```

### bootstrap — a new cluster

```bash
./talos.sh bootstrap --controlplane 10.0.0.10 --workers 10.0.0.11,10.0.0.12
```

1. Verifies every target node is in maintenance mode. If any node is already configured, it stops — this is what keeps you from bootstrapping over a live cluster.
2. Refuses to overwrite an existing `controlplane.yaml` unless `--force` is given.
3. Generates the cluster config with `talosctl gen config`.
4. Applies the control-plane config to each control-plane node.
5. Waits for the first node's API, then runs `talosctl bootstrap` **once**, on that node only.
6. Waits for each control-plane node to become an etcd member.
7. Applies the worker config and waits for the workers to join.
8. Fetches `kubeconfig`.

| Option | Description |
| --- | --- |
| `-c`, `--controlplane <ips>` | Control-plane IPs, comma-separated (required) |
| `-w`, `--workers <ips>` | Worker IPs, comma-separated |
| `-n`, `--cluster-name <name>` | Cluster name |
| `-i`, `--install-image <image>` | Installer image |
| `-k`, `--kubernetes-version <ver>` | Kubernetes version |
| `-d`, `--output-dir <dir>` | Where to write the generated configs |
| `-f`, `--force` | Overwrite an existing output directory |

### join — add nodes to a running cluster

```bash
./talos.sh join --endpoint 10.0.0.10 --controlplane 10.0.0.13,10.0.0.14
```

`--endpoint` is any node already in the cluster. `join` never generates secrets and never calls `bootstrap`.

For each role it finds a live node of **that same role** and takes its machine config. A worker config cannot be derived from a control-plane one: the `machine.type` differs, and so does the set of sections.

Then, before applying anything:

- **Strips the source node's static network config**, so new nodes come up on DHCP instead of claiming the source node's address. Disable with `--keep-network` if you know why you want that.
- **Bumps the tag in `install.image`** to the version actually running on the source node. Override the whole reference with `--install-image`.
- **Applies your own patch**, if `--patch` is given.
- **Validates** the result with `talosctl validate` before it touches a node.
- **Refuses to apply** to a node that does not answer on the maintenance API.

Control-plane nodes are added **strictly one at a time**, waiting for each to appear in `etcd members`. This matters: going from one member to two raises the quorum to two, so a new node that fails to come up takes write availability down with it. Workers have no such constraint and are applied together.

Both roles can be passed in one call — control-plane first, then workers:

```bash
./talos.sh join --endpoint 10.0.0.10 --controlplane 10.0.0.13 --workers 10.0.0.15
```

| Option | Description |
| --- | --- |
| `-e`, `--endpoint <ip>` | IP of a node already in the cluster (required) |
| `-c`, `--controlplane <ips>` | New control-plane IPs, comma-separated |
| `-w`, `--workers <ips>` | New worker IPs, comma-separated |
| `-i`, `--install-image <image>` | Installer image override |
| `-p`, `--patch <file>` | Extra config patch for the new nodes |
| `-K`, `--keep-network` | Keep the source node's static network config |
| `-t`, `--talosconfig <file>` | Path to talosconfig (default: `$TALOSCONFIG`) |

### Common options

| Option | Description |
| --- | --- |
| `-T`, `--timeout <sec>` | Timeout for each wait, in seconds (default: 900) |
| `-h`, `--help` | Help |

There are no fixed `sleep` calls. The script polls actual state — node API availability, etcd membership, cluster membership — with a timeout.

## Static addresses

Control-plane nodes generally want fixed addresses: `cluster.controlPlane.endpoint` and `apiServer.certSANs` are pinned to IPs, and a DHCP lease that moves will break them.

Pass a patch with `--patch`, in either JSON-patch or strategic-merge form:

```yaml
machine:
  network:
    interfaces:
      - interface: eth0
        addresses:
          - 10.0.0.13/24
        routes:
          - network: 0.0.0.0/0
            gateway: 10.0.0.1
        dhcp: false
```

Such a patch names one address, so apply it to one node per invocation.

## Air-gapped or blocked registries

If your nodes cannot pull from `factory.talos.dev`, mirror the installer and point `join` at the mirror. Verify the mirror is the same image first:

```bash
crane digest factory.talos.dev/nocloud-installer/<schematic-id>:v1.13.7
crane digest docker.io/<you>/talos-installer:v1.13.7
```

```bash
./talos.sh join --endpoint 10.0.0.10 --workers 10.0.0.15 \
    --install-image docker.io/<you>/talos-installer:v1.13.7
```

## Limitations

- **`join --workers` needs at least one existing worker** to copy a config from. On a control-plane-only cluster, add the first worker by hand or generate a worker config from the cluster secrets.
- **Nodes must already be in maintenance mode.** A node that has installed a bad config is not reachable that way any more — wipe its disk and boot from the ISO again.
- **No VIP management.** If you want a shared control-plane endpoint, configure `machine.network.interfaces[].vip` yourself, via `--patch` or afterwards.
- **New node addresses are not discovered.** Pass them in; find them via your hypervisor's guest agent or your DHCP server.
- **Single-address patches.** `--patch` applies the same patch to every node in the call, so per-node settings mean one call per node.

## Status

Developed and used against Talos v1.13.x with `talosctl` v1.13.x. The `join` path — both control-plane and worker — is exercised in practice. On the `bootstrap` side the guards that protect the destructive operations are covered by tests, but a full end-to-end bootstrap will depend on your environment; try it on a throwaway cluster first.

Issues and PRs welcome.

## License

MIT, unless you replace this section with something else before publishing.
