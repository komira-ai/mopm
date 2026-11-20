//! The cold start (docs/design/tutorial-sign-in.md, section 5): the function's name gives the stage, the stage's
//! `config` table gives its settings, and the stage's `edge-origin` secret gives the edge value. A failure is a
//! [`SetupError`] naming what is wrong; the function answers nothing with half of its setup.

use mopm_ports::auth::AuthStore;
use mopm_ports::env::Clock;
use mopm_ports::secrets::SecretReader;
use mopm_web::csrf::CsrfCheck;
use mopm_web::edge::EdgeCheck;
use mopm_web::settings::{ConfigTable, FunctionName, SetupError, StageSettings};
use mopm_web::SessionAuth;

use crate::handler::WebSessionHandler;

/// The handler of the stage `name` names: its settings read from `config`, its edge value from `secrets`, its
/// sessions in `store`, its time from `clock`. The caller builds `store` for the same stage.
pub async fn cold_start<S: AuthStore, C: Clock>(
    name: &FunctionName,
    config: &impl ConfigTable,
    secrets: &impl SecretReader,
    store: S,
    clock: C,
) -> Result<WebSessionHandler<S, C>, SetupError> {
    let settings = StageSettings::load(config).await?;
    let edge = EdgeCheck::load(secrets, &name.stage).await?;
    Ok(WebSessionHandler::new(SessionAuth::new(
        edge,
        CsrfCheck::new(&settings.site_origin),
        store,
        clock,
    )))
}
