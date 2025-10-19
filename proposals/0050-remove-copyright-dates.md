## Remove copyright dates

* **Owners**
  * Ben Kochie ([@SuperQ](https://github.com/SuperQ))

* **Implementation**: Accepted

* **Related Issues and PRs:**
  * https://github.com/prometheus/proposals/issues/50

* **Other docs or links:**
  * https://github.com/cncf/foundation/blob/main/copyright-notices.md

> CONSENSUS: We agree that we want to remove the date from the license headers from our files

## Why

The CNCF copyright notice guidelines recommend against including dates/years in them.

We should, on a best effort basis, remove the year from the notice headers on our projects. This would reduce the issues with having to deal with PRs copy-and-pasting the wrong year when creating new files.

## How

The new copyright header at the beginning of source files:

```
// Copyright The Prometheus Authors
```

Simple sed script to help automate updates:

```
find . -type f \( -iname '*.go' -or -iname Makefile \) \
  \( ! -path './vendor/*' -and ! -path '*/node_modules/*' \) \
  | xargs sed -i -E '1s/^(\/\/|#) Copyright .*/\1 Copyright The Prometheus Authors/'
```
