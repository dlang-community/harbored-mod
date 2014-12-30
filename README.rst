============
harbored-mod
============


------------
Introduction
------------

Documentation generator for `D <http://dlang.org>`_ with Markdown support, based on
`harbored <https://github.com/economicmodeling/harbored>`_.

Harbored-mod supports both `DDoc <http://dlang.org/ddoc.html>`_ and `Markdown
<http://en.wikipedia.org/wiki/Markdown>`_ in documentation comments, but DDoc takes
precedence. This means that there are slight differences_ from standard Markdown.

Note that Harbored-mod is fairly unstable at the moment and has not seen much testing.
There may still be some conflicts between DDoc and Markdown, for example.


-----------------------------------
Examples of generated documentation
-----------------------------------

* `Class with a template parameter, member functions and aliases <http://defenestrate.eu/docs/tharsis-core/api/tharsis/entity/entitymanager/EntityManager.html>`_
* `Simple DDoc See_Also: section <http://defenestrate.eu/docs/tharsis-core/api/tharsis/entity/componenttypeinfo/ImmutableRawComponent.html>`_
* `Note: DDoc section with some markdown <http://defenestrate.eu/docs/tharsis-core/api/tharsis/entity/processtypeinfo/prioritizeProcessOverloads.html>`_ (**bold**, \`code\`, *italic*)

---------------
Getting started
---------------

This assumes you are using the DMD compiler. Currently, harbored-mod uses a Makefile
hardcoded to DMD. Eventually it will be moved to `dub <http://code.dlang.org>`_.

.. note:: There are experimental binaries for some platforms on the
          `releases <https://github.com/kiith-sa/harbored-mod/releases>`_ page.
          If you're using a binary, you can jump to step ``5``.

1. Get harbored-mod and its dependencies::

      git clone --recursive https://github.com/kiith-sa/harbored-mod.git

2. Go into the directory harbored-mod was cloned into::

      cd harbored-mod

3. Compile::

      make

4. This should generate a called ``hmod`` in the ``bin`` directory.

5. Modify your ``PATH`` to point to this directory or copy the binary into your project.

6. From your project directory, use ``hmod``. This assumes your source code is in the 
   ``./source`` subdirectory (as is often the case with ``dub`` projects) and that the 
   ``hmod`` binary is in ``PATH``, prepend with ``./`` if it's in the project directory).::

      hmod source

   This will write generate documentation to the ``./doc`` subdirectory. See
   ``./doc/index.html``. Note that the main page will be blank, although you should see
   a list of all modules on the left.


To further tweak the documentation, generate the default configuration file::

   hmod -g

This will generate a file called ``hmod.cfg`` in the current directory. Harbored-mod looks 
for this file in the directory it's running from, and if present, loads configuration 
options such as main page content, style, files to exclude from documentation generation,
and so on. See comments in ``hmod.cfg`` for more information.



--------
Features
--------

* Supports DDoc **and** (most, see differences_) Markdown syntax
* Sensible defaults (get decent documentation without tweaking any settings)
* Very fast; it takes ``0.12s`` to generate API documentation
  `documentation <http://defenestrate.eu/docs/tharsis-core/api/index.html>`_ of
  `tharsis-core <https://github.com/kiith-sa/tharsis-core>`_ on a 3.4GHz Core
  i5 (Ivy Bridge).
* All command-line options can be set in a config file (`hmod.cfg`) so just ``hmod`` is
  enough to generate documentation
* File paths compatible with `ddox <https://github.com/rejectedsoftware/ddox>`_
* Custimizable main page, table of contents and style (CSS)
* Generated HTML enriched by classes to be more tweakable with CSS
* Can exclude modules/packages from documentation by name (not file name)
* **Only** generates HTML, and is unlikely to support any other formats
* **No** automatic cross-referencing at the moment


.. _differences:

----------------------------------
Differences from vanilla Markdown:
----------------------------------

* ``---`` will not generate a horizontal line, as it is used for DDoc blocks.

  Use ``- - -`` instead. This is still standard Markdown.

* This does not work (again because DDoc uses ``---`` to mark code blocks)::
  
     Subheading
     ----------

  Instead, use either (standard Markdown)::

     ## Subheading

  Or (non-standard)::

     Subheading
     **********


-------------------
Directory structure
-------------------

===============  =======================================================================
Directory        Contents
===============  =======================================================================
``./``           This README, Makefile, license.
``./bin``        Harbored-mod binaries when compiled.
``./dmarkdown``  `dmarkdown <https://github.com/kiith-sa/dmarkdown>`_ dependency.
``./libddoc``    `libddoc <https://github.com/economicmodeling/libddoc>`_ dependency.
``./libdparse``  `libdparse <https://github.com/Hackerpilot/libdparse>`_ dependency.
``man1``         Man page.
``./src``        Source code.
``./strings``    Files compiled into Harbored-mod to be used in generated documentation 
                 (e.g. the default CSS style).
===============  =======================================================================


-------
License
-------

Harbored-mod is released under the terms of the `Boost Software License 1.0
<http://www.boost.org/LICENSE_1_0.txt>`_.  This license allows you to use the source code
in your own projects, open source or proprietary, and to modify it to suit your needs.
However, in source distributions, you have to preserve the license headers in the source
code and the accompanying license file.

Full text of the license can be found in file ``LICENSE_1_0.txt`` and is also
displayed here::

    Boost Software License - Version 1.0 - August 17th, 2003

    Permission is hereby granted, free of charge, to any person or organization
    obtaining a copy of the software and accompanying documentation covered by
    this license (the "Software") to use, reproduce, display, distribute,
    execute, and transmit the Software, and to prepare derivative works of the
    Software, and to permit third-parties to whom the Software is furnished to
    do so, all subject to the following:

    The copyright notices in the Software and this entire statement, including
    the above license grant, this restriction and the following disclaimer,
    must be included in all copies of the Software, in whole or in part, and
    all derivative works of the Software, unless such copies or derivative
    works are solely in the form of machine-executable object code generated by
    a source language processor.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
    SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
    FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
    ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
    DEALINGS IN THE SOFTWARE.



-------
Credits
-------

Harbored-mod is based on `harbored <https://github.com/economicmodeling/harbored>`_ by 
Brian Schott, with modifications by Ferdinand Majerech aka Kiith-Sa
kiithsacmp[AT]gmail.com.

Harbored-mod was created as a documentation generator for the `D programming language
<http://www.dlang.org>`_.  See more D projects at `code.dlang.org
<http://code.dlang.org>`_.
