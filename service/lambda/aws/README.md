# mopm_aws

The ports on the AWS SDK for Rust. Nothing here signs a request or retries one: the SDK does.

`dynamo`: `DynamoStore`, `DynamoAuthStore`, `DynamoPublishStore`, the DynamoDB adapters of the three stores. The rows they
write are the TypeScript adapters' (a version keyed by the canonical version with `version_spelling` beside it; an owner's
or user's id as a string key plus `github_id_num`; a token's expiry as epoch seconds for the TTL plus `expires_at_iso`;
`ts_seq`, `search_bucket`, `token_hash`, ...). Create-once is a conditional put; a version and its audit row are one
transaction (the SDK sets the `ClientRequestToken`); an update is read, state machine, a transaction conditional on `rev`.

How they are tested (`mopm_testing::fake_dynamo`): the SDK talks real DynamoDB JSON over HTTP to a fake on loopback that
refuses what DynamoDB refuses (raw reserved words in expressions, unused names or values, empty `begins_with`, non-string keys,
a TTL that is not a number, a consistent read of an index, a starting key outside the query, a transaction without a token), pages
like DynamoDB, and can enforce the Lambda role's grants from `lambda-auth-grants.json`. The same contract scenarios that run on the memory
stores run on these, and the tests assert the rows and requests as DynamoDB JSON.
