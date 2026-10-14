/* libouter: the native library of the fixture package `outer`. It is linked
   against libinner (DT_NEEDED libinner.so, macOS @rpath/libinner.dylib) with
   no run path of its own, so libinner loads only if something names it. */
int inner_base(void);
int outer_chain(void) { return inner_base() + 234; }
