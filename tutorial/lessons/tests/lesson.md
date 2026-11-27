This project has a small library, `src/calc`, with one function, `double`. The program `src/main.mojo` uses it:
press **Run** and it prints

```output run
42
```

`tests/test_calc.mojo` tests `double`. A test is a function whose name starts with `test_`; it calls the code and
checks the result with `assert_equal` from `std.testing`. mopm finds every `tests/**/test_*.mojo` file, builds it, and
runs each test in a process of its own. Press **Test**: mopm prints a line for each test, with how long it took, and
then a summary.

```output test
PASS          tests/test_calc.mojo::test_double (81 ms)
PASS          tests/test_calc.mojo::test_double_negative (81 ms)

mopm test: 2 tests: 2 passed, 0 failed, 0 crashed, 0 timed out, 0 out of memory, 0 not built, 0 flaky, 0 ignored
```

Now break `double` (return `x * 3`) and press **Test** again: both tests fail, and mopm prints what each assertion
expected and what it got. Put it back, and add a test of your own, such as `test_double_zero`.
