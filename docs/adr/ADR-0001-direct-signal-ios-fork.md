# ADR-0001: Direct Signal-iOS Fork

**Status:** Accepted

Preserve Signal-iOS history and submodules in the eventual production repository.
The generated archive is an overlay solely because upstream could not be cloned
inside the generation environment. `bootstrap-direct-fork.sh` creates the intended
repository shape.
