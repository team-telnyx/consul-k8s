# infra-oci-consul-k8s

This is a fork of hashicorp/consul-k8s repo. We needed to add support for some new annotations and features.

## Overview

We will work our changes on the release branch of interest and once, done, we will also merge our changes to main.

## Syncing with upstream

To sync with upstream, we will use the following commands:

```bash
git remote add upstream git@github.com:hashicorp/consul-k8s.git
git fetch upstream
git checkout release/<release-version>
git rebase upstream/release/<release-version>
```