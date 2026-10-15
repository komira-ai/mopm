// Cross-cell closure probe: komira's pinned crates and a mopm-pinned crate in one binary.
use itertools::Itertools;

fn main() -> anyhow::Result<()> {
    let mut buf = itoa::Buffer::new();
    let joined = [1u32, 2, 3].iter().map(|n| buf.format(*n).to_string()).join(",");
    println!("{joined}");
    Ok(())
}
