use rustler::{Encoder, Env, NifResult, Term};

mod atoms {
    rustler::atoms! {
        ok,
        error,
    }
}

mod error;
mod profile;
mod request;
mod response;
mod transport;

use error::RequestError;
rustler::init!("Elixir.ExUndercover.Nif");

#[rustler::nif(schedule = "DirtyCpu")]
fn request<'a>(env: Env<'a>, payload_json: String) -> NifResult<rustler::Term<'a>> {
    let payload = match serde_json::from_str(&payload_json) {
        Ok(payload) => payload,
        Err(error) => return Ok((atoms::error(), error.to_string()).encode(env)),
    };

    match transport::dispatch(payload) {
        Ok(response) => Ok((atoms::ok(), rustler::SerdeTerm(response)).encode(env)),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

#[rustler::nif]
fn profile_metadata<'a>(env: Env<'a>) -> NifResult<Term<'a>> {
    let metadata = profile::profile_metadata();
    Ok((atoms::ok(), rustler::SerdeTerm(metadata)).encode(env))
}

#[rustler::nif]
fn build_request_plan<'a>(env: Env<'a>, payload_json: String) -> NifResult<rustler::Term<'a>> {
    let payload = match serde_json::from_str(&payload_json) {
        Ok(payload) => payload,
        Err(error) => return Ok((atoms::error(), error.to_string()).encode(env)),
    };

    match transport::plan::build(&payload) {
        Ok(plan) => Ok((atoms::ok(), rustler::SerdeTerm(plan)).encode(env)),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

impl From<serde_json::Error> for RequestError {
    fn from(error: serde_json::Error) -> Self {
        RequestError::Serde(error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_serde_errors_into_request_errors() {
        let error = serde_json::from_str::<serde_json::Value>("{").unwrap_err();
        let request_error: RequestError = error.into();

        assert!(matches!(request_error, RequestError::Serde(_)));
    }
}
