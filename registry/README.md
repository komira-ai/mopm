# registry

The package registry behind mopm.dev: the package index, the ownership rules
for package names (only the owner of a name can publish new versions of it),
and the website.

- The service (CDK stacks, deploy and promotion pipelines, access stack) lives in
  [`service/`](../service). Start with [`service/docs/pipelines.md`](../service/docs/pipelines.md).
- The wire contract (OpenAPI, channel, index and lock formats) lives in `spec/`.

Nothing is deployed from this directory.
