# harbored-mod [![CI status](https://travis-ci.org/dlang-community/harbored-mod.svg?branch=master)](https://travis-ci.org/dlang-community/harbored-mod/)

## Introduction

Documentation generator for [D](https://www.dlang.org) with Markdown support, based on [harbored](https://github.com/economicmodeling/harbored).

Harbored-mod supports both [DDoc](https://dlang.org/spec/ddoc.html) and [Markdown](https://daringfireball.net/projects/markdown/) in documentation comments, but DDoc takes precedence. 
This means that there are slight differences from standard Markdown.

## Getting started

### Building

- using git

    - `git clone https://github.com/dlang-community/harbored-mod.git`
    - `cd harbored-mod`
    - `dub build`
    
- using DUB only

    - `dub fetch harbored-mod`
    - `dub build harbored-mod`

### Setting up

At this point you should have a binary called `hmod` in the `bin`
directory.

-   Modify your `PATH` to point to the `bin` directory or copy the
    binary into your project.
-   From your project's directory, run `hmod`. This assumes your source
    code is in the `./source` subdirectory (as is often the case with
    `dub` projects) and that the `hmod` binary is in `PATH`, prepend
    with `./` if it's in the project directory).:

        hmod source

    This will write generate documentation to the `./doc` subdirectory.
    See `./doc/index.html`. Note that the main page will be blank,
    although you should see a list of all modules on the left.

    To further tweak the documentation, generate the default
    configuration file:

## Features

- Supports DDoc **and** (most, see differences) Markdown syntax
- Sensible defaults (get decent documentation without tweaking any settings)
- Automatic cross-referencing in code blocks and `inline code`
- Very fast
- All command-line options can be set in a config file (`hmod.cfg`) so just `hmod` is enough to generate documentation
- Generates one file per module/`class`/`struct`/`enum`/etc. by default, as opposed to one file per module (old Phobos documentation) or one file per symbol (`ddox`).
- File paths can be made compatible with ddox using the non-default `--format=html-simple` option
- Generated HTML enriched by classes to be more tweakable with CSS
- Customizable main page, table of contents and style (CSS)
- Can exclude modules/packages from documentation by their name (not file name)
- Generated docs are usable without JavaScript (e.g. NoScript), JS may used for optional functionality
- **Only** generates HTML, and is unlikely to support any other formats

## Differences from vanilla Markdown

- `---` will not generate a horizontal line, as it is used for DDoc blocks. Use `- - -` instead. This is still standard Markdown.
- *emphasis* can be denoted by `*`, but not by `_` (this would break snake\_case names).
- This does not work (again because DDoc uses `---` to mark code blocks):

    Subheading
    ----------

Instead, use either (standard Markdown):

    ## Subheading

Or (non-standard):

    Subheading
    **********
    
## Directory structure

| Directory     | Contents                                                                                             |
|---------------|------------------------------------------------------------------------------------------------------|
| `./`          | This README, Makefile, license.                                                                      |
| `./bin`       | Harbored-mod binaries when compiled.                                                                 |
| `./src`       | Source code.                                                                                         |
| `./strings`   | Files compiled into Harbored-mod to be used in generated documentation (e.g. the default CSS style). |

## Credits

Harbored-mod is based on [harbored](https://github.com/economicmodeling/harbored) by Brian Schott, 
with modifications by Ferdinand Majerech aka Kiith-Sa,
maintained by the dlang-community.
