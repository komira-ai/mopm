use super::*;

#[test]
#[should_panic(expected = "expected a domain error, got 7")]
fn code_of_a_success_fails_the_scenario_naming_the_value() {
    code_of(Ok(7u8));
}
