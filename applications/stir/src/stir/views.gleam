//// The application's CouchDB views and JSON schemas, registered on start
//// and again on every platform refresh, and re-tried by the monitor on
//// every pass: a node that came up before the datastore did has no design
//// document until something tries again, and without the views the key
//// store reads as empty. The schemas ride along: the `stir_shaken` callflow
//// action's schema is this application's, and Crossbar cannot store a flow
//// that uses the action until it is in `system_schemas`.

/// Register the views under `priv/couchdb/views` and the schemas under
/// `priv/couchdb/schemas`, and bind so that a platform refresh puts them
/// back. Idempotent; safe without a datastore.
@external(erlang, "stir_ffi", "register_views")
pub fn register() -> Nil
