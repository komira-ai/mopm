# A directory that lays out files under the relative paths given as keys of `srcs` (symlinks, no copy and no action that runs a
# program), and a sub target for each path, so a zig_module can take `":tree[path]"` as its `src` or an import and Zig finds the
# files beside each other where the old code expects them. (The prelude's filegroup makes the same directory but has no sub targets.)

def _tree_impl(ctx):
    out = ctx.actions.symlinked_dir(ctx.label.name, ctx.attrs.srcs)
    return [DefaultInfo(
        default_output = out,
        sub_targets = {path: [DefaultInfo(default_output = out.project(path))] for path in ctx.attrs.srcs},
    )]

tree = rule(impl = _tree_impl, attrs = {"srcs": attrs.dict(attrs.string(), attrs.source())})
