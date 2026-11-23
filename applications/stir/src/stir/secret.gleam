//// A private key or a credential in memory.
////
//// Opaque so that no module outside this one can read it by accident, and
//// so that its debug rendering is a label rather than the bytes. The bytes
//// are held behind a closure rather than in a field, so a `Secret` that
//// does reach `string.inspect`, `io.debug`, a log line or a crash report
//// renders its label and a function, never the key.
//// The only readers are the signer (to sign) and the store (to seal it).

/// The bytes, labelled by what they are: a PEM or a credential.
pub opaque type Secret {
  Secret(label: String, bytes: fn() -> BitArray)
}

pub fn new(label: String, bytes: BitArray) -> Secret {
  Secret(label:, bytes: fn() { bytes })
}

/// What the secret is, for a log line. Never the bytes.
pub fn label(secret: Secret) -> String {
  secret.label
}

/// Use the bytes and answer something that is not them: a signature, a
/// sealed blob, a public key.
pub fn with(secret: Secret, do: fn(BitArray) -> a) -> a {
  do(secret.bytes())
}
