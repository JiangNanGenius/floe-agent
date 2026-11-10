# ``SwiftGitX/Repository``

## Topics

### Creating a Repository

- ``init(at:createIfNotExists:)``
- ``open(at:)``
- ``create(at:isBare:)``
- ``clone(from:to:options:)``
- ``clone(from:to:options:transferProgressHandler:)``

### Properties

- ``HEAD``
- ``workingDirectory``
- ``isHEADDetached``
- ``isHEADUnborn``
- ``isEmpty``
- ``isBare``
- ``isShallow``

### Create a Commit

- ``add(file:)``
- ``add(files:)``
- ``add(path:)``
- ``add(paths:)``
- ``commit(message:)``

### Collections

- ``branch``
- ``config-swift.property``
- ``config-swift.type.property``
- ``reference``
- ``remote``
- ``stash``
- ``tag``

### Diff

- ``diff(to:)``
- ``diff(commit:)``
- ``diff(from:to:)``

### Log

- ``log(sorting:)``
- ``log(from:sorting:)-2c8fu``
- ``log(from:sorting:)-3rteq``
- ``LogSortingOption``

### Patch

- ``patch(from:)``
- ``patch(from:to:)-10g8i``
- ``patch(from:to:)-957bd``

### Restore

- ``restore(_:files:)``
- ``restore(_:paths:)``
- ``RestoreOption``

### Reset

- ``reset(to:mode:)``
- ``ResetOption``

- ``reset(from:files:)``
- ``reset(from:paths:)``

### Revert

- ``revert(_:)``

### Show

- ``show(id:)``

### Status

- ``status(options:)``

#### Status of a specific file

- ``status(file:)``
- ``status(path:)``

### Switch

- ``switch(to:)-8oxzx``
- ``switch(to:)-16nyq``
- ``switch(to:)-2ysnq``

### Remote Repository Operations

- ``push(remote:)``
- ``fetch(remote:)``
