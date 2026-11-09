//! Segurança do ConectDroidCam: identidade de cada instalação, TLS com a impressão digital
//! do outro lado fixada, e o código de pareamento.
//!
//! O modelo é o de "confiar no primeiro uso, com conferência humana":
//!
//! 1. Cada lado tem um certificado autoassinado (P-256), criado uma vez.
//! 2. No **pareamento** o computador aceita o certificado que o celular apresentar e os dois
//!    lados mostram o mesmo código de 6 dígitos, calculado das duas impressões digitais.
//!    Quem se põe no meio apresenta certificados diferentes a cada lado, e os códigos
//!    divergem. O usuário confere e confirma nas duas telas.
//! 3. Depois, cada lado só aceita a impressão digital que ficou registrada.

mod identity;
mod link;
mod pairing;
mod tls;

pub use identity::{Identity, fingerprint, short_fingerprint};
pub use link::SecureLink;
pub use pairing::{new_nonce, pairing_code};
pub use tls::{SecError, accept_secure, connect_secure};
