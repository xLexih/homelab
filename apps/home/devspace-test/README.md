# devspace-test

Test app for DevSpace live-reload development workflow.

## Files

| File             | Description              |
| ---------------- | ------------------------ |
| `devspace.yaml`  | DevSpace config          |
| `Dockerfile`     | Container image          |
| `server.js`      | Express server           |
| `package.json`   | Node dependencies        |

## Notes

- Syncs local files into container, forwards port 3000
- Uses nodemon for hot reload on .js changes

## Deploy

```bash
devspace dev
```
