# DevSpace Test

Test deployment for [DevSpace](https://devspace.sh/) - development workflow with hot reload.

## Prerequisites

- [DevSpace installed](https://devspace.sh/docs/getting-started/installation)

## Usage

```bash
# Start development mode (builds image, deploys, syncs files, forwards ports)
devspace dev

# Make changes to server.js - they sync automatically and nodemon restarts

# Open terminal in container
devspace enter

# Purge deployment
devspace purge
```

## What it does

1. Builds `devspace-live-app` image from Dockerfile
2. Deploys to k8s with inline manifest
3. Syncs local files to container (`./:/app`)
4. Forwards port 3000 to localhost
5. Runs with `npm run dev` (nodemon) for hot reload

## Files

| File | Description |
|------|-------------|
| `devspace.yaml` | DevSpace config |
| `Dockerfile` | Container image |
| `server.js` | Express server |
| `package.json` | Node dependencies |
