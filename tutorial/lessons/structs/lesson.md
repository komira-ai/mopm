A struct groups values into a type of your own. `Point` in `src/main.mojo` has two fields, `x` and `y`, declared with
`var`:

- `@fieldwise_init` gives it a constructor that takes the fields in order, so `Point(1, 2)` makes one.
- `move_by` is a method. It changes the point, so it takes `mut self`; a method that only reads takes `self`.
- `Writable` in the parentheses is a trait: the promise that a `Point` can write itself, which `print` needs.
  `write_to` keeps that promise.

Press **Run**:

```output run
(1, 2)
(4, 6)
10
```

Add a method `def sum(self) -> Int` that returns `self.x + self.y`, and print `p.sum()` in place of `p.x + p.y`.
