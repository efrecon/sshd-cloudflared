# Executable Shorthands

This directory contains a series of executable shorthands to ease calling the
functions of the [library] from the command-line (directly or via the Docker
image). The directory contains:

+ [`image_api.sh`](./image_api.sh) the implementation of the shorthands relaying
  functionality. This is also the entry point of the Docker image.
+ A series of a symbolic links, named after the name of the functions of the
  library, with a `.sh` suffix, and pointing the the implementation of the
  shorthands relaying functionality.

The implementation of the shorthands relaying functionality changes behaviour
depending on its basename. When named after the name of a function (but with a
trailing `.sh` suffix), and if that function exists, the function will be
blindly called with all further arguments passed at the command-line. Otherwise,
the first argument should be the name of an existing function of the library
(`img_` prefix can be omitted), in which case the function will be blindly
called with all remaining arguments from the command-line.

  [library]: ../image_api.sh