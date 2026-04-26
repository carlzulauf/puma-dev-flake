# puma-dev-flake

A Nix flake that packages [puma-dev](https://github.com/puma/puma-dev) (a zero-config Rack/Rails development server with automatic `.test` domains and HTTPS) as a NixOS module.

On Linux, puma-dev doesn't handle DNS or port forwarding itself. This flake wires up the full stack:

- **dnsmasq** on port 9253 resolves `*.test` → 127.0.0.1
- **systemd-resolved** forwards `.test` queries to that dnsmasq instance
- **nftables** NAT rules redirect ports 80/443 to puma-dev's unprivileged ports
- **SSL CA** generated at build time and trusted system-wide (curl, Chrome, Firefox)

## NixOS Integration

### 1. Add to your flake inputs

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  puma-dev-flake.url = "github:carlzulauf/puma-dev-flake";
};
```

### 2. Import the module

In your `nixosConfigurations`, add the module and pass inputs through:

```nix
nixosConfigurations.myhostname = nixpkgs.lib.nixosSystem {
  modules = [
    inputs.puma-dev-flake.nixosModules.default
    ./configuration.nix
  ];
};
```

### 3. Enable the service

In your machine's configuration:

```nix
services.puma-dev = {
  enable = true;
  user = "myuser";  # the user whose home directory holds app symlinks
};
```

### Configuration options

| Option | Default | Description |
|--------|---------|-------------|
| `user` | *(required)* | User that runs puma-dev; app symlinks live in their home dir |
| `dir` | `~/.puma-dev` | Directory containing app symlinks (`%h` expands to home) |
| `domains` | `["test"]` | TLDs puma-dev serves |
| `httpPort` | `9280` | Unprivileged HTTP port (port 80 forwards here) |
| `httpsPort` | `9283` | Unprivileged HTTPS port (port 443 forwards here) |
| `idleTimeout` | `"15m"` | How long before an idle app is stopped |

## Setting up an app

### Via symlink

Once puma-dev is running, symlink a Rack/Rails app into `~/.puma-dev`:

```bash
cd ~/.puma-dev
ln -s ~/projects/myapp myapp
```

The app is then available at `https://myapp.test`.

### Via specified port

You can also forward to a rack app or any other app by creating a file containing the port it's serving on. With this method, puma-dev will not be able to start/stop the app for you, but it's easier, potentially more reliable, and more explicit.

```
echo "3333" > ~/.puma-dev/myapp2
```

Whatever application is serving on port 3333 is now available at `https://myapp2.test`.

## Upgrading puma-dev

1. Find the new Linux amd64 release URL at https://github.com/puma/puma-dev/releases
2. Compute the new hash:
   ```bash
   nix-prefetch-url <url>
   # or
   nix store prefetch-file --hash-type sha256 <url>
   ```
3. Update `version` and `sha256` in `flake.nix`
4. Verify: `nix build .#puma-dev`
5. Run `nix flake update` to refresh `flake.lock`
