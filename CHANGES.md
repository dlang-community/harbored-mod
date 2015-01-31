=====
0.2.0
=====

----------
Highlights
----------

* Automatic cross-referencing in code blocks and inline code
* New (and now default) output format: "aggregated" HTML; generate documentation
  files only for aggregates (modules, structs, classes, etc.) and document 
  non-aggregate members (functions, variables, etc.) in these files.

  The previous, DDox compatible format, where a separate file is generated for
  every symbol, is still supported through the `--format=html-simple` options.
* Various style and usability improvements
* Major refactoring
* Many bugfixes


------------
Enhancements
------------

* Automatic cross-referencing in code blocks and inline code
* New (and now default) output format: "aggregated" HTML; generate documentation
  files only for aggregates (modules, structs, classes, etc.) and document 
  non-aggregate members (functions, variables, etc.) in these files.

  The previous, DDox compatible format, where a separate file is generated for
  every symbol, is still supported through the `--format=html-simple` options.
* Table of contents sidebar can be collapsed to save space (No JS needed)
* Multi-level indentation of nested parameter lists (parameter lists of function
  parameters) (Ilya Yaroshenko)
* Public imports are now prominently displayed at the top of documentation of
* Breadcrumbs are now always visible for fast search, parent access
* `_` for `_emphasis_` in Markdown is now disabled, to avoid breaking some
  `snake_case` names. `*emphasis*` can still be used
* Folding tree table of contents (JS-only atm) (Akzwar)
* Highlighting current module in table of contents (Akzwar)
  modules containing them (useful for package modules)
* Decreased file size of generated documentation
* Better log/info messages
* Multiple `--toc-additional` parameters are now supported
* `--toc-additional-direct` to add TOC content without a proxy file
* Minor improvements in the default CSS style
* Renamed the short version of the `--config` option from `-f` to `-F`
* More `<div>`s and `class=`es for better CSS styling

-----------------
Code improvements
-----------------

* Refactored code to write to ranges instead of directly to files
* Refactored (almost all) file output and HTML writing code into a separate
  module
* Added a 'symbol database' for cross-referencing and maybe more future features
* Changed the hacky breadcrumbs/TOC order in HTML and simplified related CSS
* Table of contents is now generated into a `ScopeBuffer` for speed
* Moved the help string and default `hmod.cfg` into separate, string-imported
  files
* Various optimizations
* Various minor refactoring

--------
Bugfixes
--------

* TocAdditional content is no longer processed through a temp file
* Fixed crashes on empty comments, `libddoc` errors and missing source files
* Fixed ditto with no preceding comments (Ilya Yaroshenko)
* Fixed interface format (Ilya Yaroshenko)
* Fixed inherited templated class format (Ilya Yaroshenko)
* Fixed breadcrumbs links (Ilya Yaroshenko)
* Fixed package table of contents entries (Ilya Yaroshenko)
* Fixed `protected` being printed as `public`
* Fixed a bug where some files were left open for too long
* Fixed the "config file not found" error message
* Undocumented enum members are now not ignored
* Various minor bugfixes
