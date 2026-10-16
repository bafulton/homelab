---
# STAND-IN DRAFTED BY CLAUDE from your description of this position.
# Rewrite in your own voice or delete before launch.
kind: rumination
title: Sign your own pull requests
date: "2026-10-15"
summary: Tool attribution in a PR description quietly moves responsibility from the author to the tool. The author is still the author.
thesis: A “written by Claude” footer is a way of not signing your own work.
tags:
  - ai
  - pull-requests
  - code-review
  - process
public: false
---

Every agentic coding tool wants to sign its work. Claude Code appends a
footer. Codex appends a footer. The default is always on, always at the
bottom, always some variant of *generated with*.

I turn it off. Not because I am hiding anything â my team knows exactly how I
work â but because of what the footer does to the sentence above it.

## Responsibility does not delegate

A pull request is a request. You are asking people to spend their attention on
your change and then to accept it into something they are jointly responsible
for. That request carries an implicit claim: *I understand this, I believe it
is correct, and I will own it when it breaks.*

A tool footer undercuts that claim without quite retracting it. It reads as a
disclaimer â a small note saying that if the reasoning turns out to be hollow,
the author was only the conduit. But the author was not the conduit. The
author chose the approach, read the diff, and pressed the button.

Nobody credits their compiler. Nobody footnotes their IDE's refactoring tool,
or the Stack Overflow answer from 2014, or the colleague who sketched the
approach on a whiteboard. We do not do this because authorship of a change has
never meant typing the characters. It means standing behind them.

## The honest version of transparency

The argument for the footer is transparency, and transparency is a real value,
so it is worth saying what it actually requires.

It requires that I can explain every line in review. It requires that when a
reviewer asks *why this way?* I have an answer that is mine, not a summary of
one I accepted. It requires that if the change is wrong at 3am, I am the one
who understands it well enough to fix it.

A footer provides none of that. It is cheap in exactly the way real
transparency is not, and the places where provenance genuinely matters â
licensing questions, research reproducibility, anything where the origin of
text is itself the subject â are not served by a decorative line at the bottom
of a PR body either. Those need a real answer, recorded somewhere real.

## What I do instead

I read every line before it goes out. If I cannot defend a hunk in review, it
does not ship â I rewrite it or I ask for it to be rewritten until I can. The
PR description is written for the reviewer: what changed, why, and what to
look at first.

No footer. The commit has my name on it, and that is the point.
