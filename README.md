# EgyWeb

Static websites deployed with Cloudflare Pages from this repository.

| Site | Folder | Domain |
| --- | --- | --- |
| zeiny.de | `sites/zeiny.de/` (not created yet) | zeiny.de |
| Electro Motion | `sites/electmotion/` | electmotion |

## Cloudflare Pages setup

Each domain is its own Pages project connected to this repository:

1. **Workers & Pages → Create → Pages → Connect to Git** → `melzeny/EgyWeb`.
2. Project name: `electmotion`, production branch: `main`.
3. Build settings: framework preset **None**, build command *(empty)*, build output directory `sites/electmotion`.
4. **Build watch paths** (Settings → Builds): include `sites/electmotion/*` so changes to other sites don't redeploy it.
5. **Custom domains** → add the Electro Motion domain.

Point the existing zeiny.de project at `sites/zeiny.de` the same way.

Pushes to other branches (for example `agents/electmotion`) get preview URLs automatically.

## Electro Motion site

Plain HTML, CSS and JavaScript with no build step. Open `sites/electmotion/index.html` in a browser, or run:

```sh
python3 -m http.server -d sites/electmotion 8080
```

## Agent tooling

`agents/mcp-server/` is a dependency-free MCP server (Python 3.9+). It provides a shared task backlog, a site validator and the brand guide for Claude agents working on the site. `agents/run-agents.sh` runs those agents in a loop on the `agents/electmotion` branch.
