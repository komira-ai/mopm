/* libinner: the native library of the fixture package `inner`. libouter
   needs it, so it is the transitive library of the `outer` package. */
int inner_base(void) { return 1000; }
