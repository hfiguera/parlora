# Development validation

This directory contains development tools and investigation notes. It is not
required to use the published Parlora package.

Keep scripts, build configuration, dependency lock files, regression fixtures and
intentional reports in Git. Markdown investigation reports and compact JSON
summaries remain tracked. Raw call captures, screenshots, logs, generated result
files, downloaded datasets and caches stay on the machine that produced them.
The Pipecat preparation script downloads its dataset into its ignored `.cache`
directory when needed.

`validation/.gitignore` lists the recorded inputs needed by offline tests and
replay scripts. It also allows data files under `fixtures/` and tool configuration
such as `package.json`. Put new reusable inputs in a fixture directory, or add an
explicit exception for an existing location. Do not force-add entire run folders.

Historical investigation notes may link to raw artifacts that are now local.
Those links document the original run; the artifacts are not included in a fresh
checkout. Run a report's generation commands to produce new results. A script
that accepts a prior capture or model response as a command-line argument needs
that local input. Offline regression tests retain their required inputs in Git.

Ignoring a file does not remove copies in earlier commits. Removing a tracked
artifact from the index keeps the working file locally, but excluding its old
versions from a push requires a separate history rewrite.
