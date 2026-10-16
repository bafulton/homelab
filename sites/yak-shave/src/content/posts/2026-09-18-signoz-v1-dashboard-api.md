---
# STAND-IN DRAFTED BY CLAUDE from your incident notes.
# Rewrite in your own voice or delete before launch.
kind: shave
title: Twelve dashboards against an API that stopped existing
date: 2026-09-18
summary: A sync job started failing, and the reason was an endpoint that had been deleted upstream.
descent:
  - The nightly dashboard-sync CronJob started failing
  - Every request to /api/v1/dashboards comes back 404
  - SigNoz v0.142.1 removed the v1 dashboard API outright
  - The MCP server I manage dashboards through still spoke v1
  - All twelve dashboard files in git are written in the v1 shape
resolution: Move the CronJob, the MCP server and all twelve dashboard files to v2 together.
tags:
  - signoz
  - observability
  - gitops
  - api-migration
public: true
---

My dashboards are IaC. Twelve JSON files in the repo, and a PostSync CronJob
that pushes them into SigNoz so that what is on screen is what is in git. The
job started failing and, because it is a CronJob and not a Deployment, it
failed quietly for longer than I would like to admit.

## 404, not 500

The failure was a 404 rather than a 500 or a timeout, which narrows things
considerably. A 500 is the server having a bad day. A 404 on an endpoint you
have called successfully for a year means the endpoint is gone.

It was. SigNoz removed the v1 dashboards API in v0.142.1. Tuppr had upgraded
me into it some days earlier. Nothing was broken — the API I was calling had
simply been deleted, on purpose, in a release note I did not read.

## The second consumer

Fixing the CronJob was mechanical. What I had not accounted for was that the
CronJob is not the only thing talking to that API: I also manage dashboards
interactively through a SigNoz MCP server, and it was pinned to a version that
still spoke v1.

So there were two clients, in different languages, on different release
cycles, and both were wrong in the same way at the same time. The MCP server
needed to go to v0.14.0 before I could use it to check my own migration — the
tool I would normally investigate with was broken by the thing I was
investigating.

## Twelve files

The v2 dashboard shape is not a rename. Queries carry different structure, and
the pieces I had internalised from writing v1 panels — `type: "tag"` with a
`key`, `reduceTo` on aggregations, `temporality` set explicitly — all needed
revisiting per panel.

Twelve files, migrated and live-tested one at a time against the real
instance, because a dashboard that renders an empty panel looks identical to a
dashboard that renders a correct panel for a metric with no data.

The useful lesson was not about SigNoz. It was that "dashboards as code" gave
me twelve files that all broke simultaneously, which sounds like a failure of
the approach and is actually the opposite: they broke visibly, in one place,
in a diff I could review. The version of this where I had clicked twelve
dashboards together by hand is the version where I find out months later that
four of them silently stopped updating.
