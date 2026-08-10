# sspc — serverless Postgres on your own machine

A working demo of a serverless Postgres platform that runs entirely on
infrastructure you control. One install gives you:

- **Databases on demand** — ask an AI agent (Claude Code or IBM Bob) for a
  Postgres database; get a connection string in seconds.
- **Scale-to-zero** — idle databases release their compute entirely and wake
  in about a second when you reconnect.
- **Instant branches** — full copy-on-write branches of a live database in
  under two seconds; branches carry TTLs and clean up after themselves.
- **A live estate UI** — served by the platform itself at `localhost:30080`:
  watch databases suspend to zero pods, wake, branch, and reap in real time.
- **Attach what you already run** — enroll any existing Postgres (a VM, RDS,
  an appliance) with just a connection string: live inventory and health,
  zero migration, zero changes to the server.

Storage is [Neon's](https://github.com/neondatabase/neon) Apache-2.0
disaggregated engine, unmodified. The platform around it — operator, chart,
lifecycle, agent API — is what this demo shows.

## Run it

Prereqs: Docker, [kind](https://kind.sigs.k8s.io), kubectl, helm, jq, and the `gh` CLI (authenticated).
Optional: the `claude` CLI (Claude Code) and/or IBM Bob for the agent flow.

```sh
gh repo clone anibjoshi/sspc-demo && cd sspc-demo
./install.sh          # ~5 minutes first run; re-runs are seconds
```

The installer creates a local kind cluster, installs the platform, runs a
smoke test, and (with your consent) registers the MCP server with Claude
Code and IBM Bob.

## Things to try

Open Claude Code (or Bob) and say:

1. *"Create a postgres database called demo and load 100k rows of test data."*
2. *"Branch it and try dropping a column on the branch — is production affected?"*
3. Wait five minutes, then: *"Reconnect me to demo."* — watch the wake time.
4. *"Enroll my existing postgres at postgresql://user:pass@host:5432/db and
   show me the estate."*

The installer ends by opening the **estate UI** in your browser — leave it visible
while you work: suspends, wakes, and TTL reaps happen on screen.

Or by hand: `kubectl -n sspc-cell get databases,branches,enrolleddatabases`

## Teardown

```sh
./down.sh
```

Everything is local; nothing phones home.

---

*Demo quality, deliberately: single admin token, no TLS, one safekeeper,
per-endpoint ports. It exists to show the shape of the platform, not to be
the product.*
