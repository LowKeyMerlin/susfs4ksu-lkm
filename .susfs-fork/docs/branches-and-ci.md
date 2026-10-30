# Branches and CI

How the branches of this fork relate to upstream, and how the workflows build and test each of
them.

## Branches

| Branch | Tracks upstream | Content | Edited by |
| --- | --- | --- | --- |
| `main` | Yes, identical to the parent's `main` | Upstream as it is | `susfs-sync` only, never by hand |
| `susfs-main` | Yes, rebased on `main` | Files only added: `.susfs-fork/`, workflows, and numbered patches in `.susfs-fork/patches/` for upstream files | Pull requests and `test/` branches squashed in |
| `susfs-dev` | No, after one initial sync | Starts as `main`, then gets the CI files it needs. May edit `kernel/` directly | Pull requests and `test/` branches squashed in |
| `test/<item>` | No | Throwaway, one change under test | The author, deleted after the squash |

`susfs-main` keeps upstream conflicts at zero: it never edits a file the parent owns, so a sync
cannot conflict in the tree and a patch that stops applying fails the sync and the build with the rejects
attached. `susfs-dev` is the place for work that should not wait for upstream or be written as a
patch. It is not synced. An upstream change that dev wants is cherry-picked by hand, and a dev
change that `susfs-main` wants is rewritten as a patch.

## Rules per branch

| | `main` | `susfs-main` | `susfs-dev` |
| --- | --- | --- | --- |
| Edit upstream files | no | no, patches only | yes |
| `susfs-guard`, add-files-only check | no | runs | skipped |
| `susfs-guard`, build and guard tests | no | runs | runs |
| `gen_build.py` check | no | runs | runs |
| Scheduled sync, drift, pins | sync only | yes | no |

## Workflows

The default branch is the only one GitHub reads `schedule` and `workflow_run` triggers from, and
`workflow_run` links stages by workflow name. Copying that chain for a second branch would leave
the copy without its triggers, or start the main chain from dev's build. So stages are called
from one workflow instead of following each other.

| Workflow | Role | Trigger |
| --- | --- | --- |
| `susfs-pipeline` | Calls the stages below and gives one verdict | push to the module branches and `test/**`, pull request, dispatch |
| `susfs-build` | Generated from upstream's `build-ddk.yml` by `.susfs-fork/gen_build.py`, never edited | called by the pipeline, dispatch |
| `susfs-smoke` | Boots every kernel of the zip in QEMU | called by the pipeline, schedule, dispatch |
| `susfs-ksu` | The same boots with each KernelSU fork loaded | called by the pipeline, schedule, dispatch |
| `susfs-android` | Cuttlefish guest: guard test and priority filter | called by the pipeline, dispatch |
| `susfs-triage` | Bundles the failed steps and rejects of a failed build | called by the pipeline on a build failure |
| `susfs-release` | Attaches the zip of the tagged commit's pipeline run | release, dispatch |
| `susfs-sync`, `susfs-drift`, `susfs-pins`, `susfs-ksud`, `susfs-guard` | Maintenance | schedule, push, dispatch |

`build-ddk.yml`, `module-zip.yml` and the other upstream workflows stay as they are and stay
disabled in the repository settings.

### The pipeline

```
flow -> build -> smoke -> verdict
              \-> ksu -> android -/
```

* Every stage downloads the artifacts of the pipeline run itself, so what is tested is what was
  built, and a stage cannot pick up the build of another commit.
* The workflow files and test scripts are the ones of the pushed commit. A change to the tests or
  the CI is tested by the run that carries it.
* `verdict` is the one check to require on a pull request. A stage that was not wanted does not
  fail it, a stage that was wanted and did not pass does.
* A newer push to a `test/` branch cancels its running pipeline. Module branches and pull
  requests are never cancelled midway.
* The token is read-only except in the build, which deletes the run's intermediate artifacts.
  `SYNC_TOKEN` is only used by `susfs-sync` and `susfs-pins`.

### Tiers

| Where | Runs |
| --- | --- |
| module branches and pull requests | build, smoke, KernelSU forks, Android guest |
| push to `test/**` | build, smoke |
| dispatch with `full=true` | all of it, on any ref |

## The flow of a branch

`.susfs-fork/flow.json` on each branch lists the validation stages that branch runs:

```json
{ "stages": ["smoke", "ksu", "android"] }
```

The `flow` job reads it from the pushed commit and the pipeline switches the stages on or off. The
workflow files then stay the same on every branch, so a CI fix is cherry-picked between them
without a conflict, and only this file differs.

* Allowed stages are `smoke`, `ksu` and `android`. `android` needs `ksu`, since it uses the
  KernelSU modules that stage built.
* A list that is not valid fails the run before the build starts.
* The full tier is applied on top: a stage the file lists still does not run on a `test/` branch
  without `full=true`.
* The build has no switch. `apply_patches.sh` does nothing when there is no patches directory, so
  a dev branch that folded the patches into `kernel/` builds the same way.

A new difference between the branches is added as one key in this file and one condition in the
pipeline. Examples are a different smoke suite or KernelSU channel.

## Trying a change

1. `git switch -c test/<item>` from the module branch, make the change, push.
2. The push runs the build and the smoke. For everything:
   `gh workflow run susfs-pipeline.yml --ref test/<item> -f full=true`.
3. Fix on the same branch. A new push replaces the running pipeline.
4. When it passes, squash into few commits with a title of at most 72 characters and a body that
   says what changed, why, and any difference from upstream. Open the pull request or
   fast-forward the module branch, then delete `test/<item>`.

A kernel change is not committed to a module branch before it has passed on a test branch.
