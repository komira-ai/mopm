//! mopm_testing: the in-memory implementations of the ports (`mopm_ports`), the contract every
//! implementation of a port must keep, a clock and a random source a test sets, and seeds.
//!
//! The contract suites are scenarios (`store_cases`, `auth_cases`, `publish_cases`) run by the macros
//! [`store_contract_tests!`], [`auth_contract_tests!`] and [`publish_contract_tests!`] against any
//! implementation: here against the memory ones, in `mopm_aws` against the DynamoDB ones.

pub mod auth_cases;
pub mod env;
pub mod fake_dynamo;
pub mod memory_auth;
pub mod memory_publish;
pub mod memory_store;
pub mod publish_cases;
pub mod records;
pub mod seed;
pub mod store_cases;

#[cfg(test)]
mod memory_contract {
    mod store {
        use crate::memory_store::MemoryStore;
        crate::store_contract_tests!(MemoryStore::new);
    }
    mod auth {
        use crate::memory_auth::MemoryAuthStore;
        crate::auth_contract_tests!(MemoryAuthStore::new);
    }
    mod publish {
        use crate::memory_publish::MemoryPublishStore;
        crate::publish_contract_tests!(MemoryPublishStore::new);
    }
}
