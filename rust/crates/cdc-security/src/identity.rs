//! Certificado autoassinado de cada instalação e sua impressão digital.

use std::fs;
use std::io;
use std::path::Path;

use rcgen::{CertificateParams, KeyPair};
use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};
use sha2::{Digest, Sha256};

use crate::tls::SecError;

/// Certificado e chave privada desta instalação.
#[derive(Clone)]
pub struct Identity {
    pub(crate) cert: Vec<u8>,
    pub(crate) key: Vec<u8>,
}

impl Identity {
    /// Cria uma identidade nova (certificado autoassinado, curva P-256).
    pub fn generate() -> Result<Self, SecError> {
        let key_pair = KeyPair::generate().map_err(|e| SecError::Identity(e.to_string()))?;
        let params = CertificateParams::new(vec!["conectdroidcam.local".to_string()])
            .map_err(|e| SecError::Identity(e.to_string()))?;
        let cert = params
            .self_signed(&key_pair)
            .map_err(|e| SecError::Identity(e.to_string()))?;
        Ok(Self {
            cert: cert.der().to_vec(),
            key: key_pair.serialize_der(),
        })
    }

    /// Lê a identidade guardada em `path`; se o arquivo não existe, cria uma e a grava
    /// (só o dono lê). Um arquivo ilegível é um erro, nunca é sobrescrito em silêncio.
    pub fn load_or_create(path: &Path) -> Result<Self, SecError> {
        match fs::read_to_string(path) {
            Ok(text) => Self::decode(&text),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let identity = Self::generate()?;
                if let Some(dir) = path.parent() {
                    fs::create_dir_all(dir)?;
                }
                write_private(path, &identity.encode())?;
                Ok(identity)
            }
            Err(e) => Err(e.into()),
        }
    }

    /// SHA-256 do certificado, em hexadecimal minúsculo (64 caracteres).
    pub fn fingerprint(&self) -> String {
        fingerprint(&self.cert)
    }

    /// Certificado de `cert` com a chave de `key`. Só para testes: simula quem copia um
    /// certificado público sem ter a chave dele.
    #[doc(hidden)]
    pub fn mix(cert: &Identity, key: &Identity) -> Self {
        Self {
            cert: cert.cert.clone(),
            key: key.key.clone(),
        }
    }

    pub(crate) fn cert_der(&self) -> CertificateDer<'static> {
        CertificateDer::from(self.cert.clone())
    }

    pub(crate) fn key_der(&self) -> PrivatePkcs8KeyDer<'static> {
        PrivatePkcs8KeyDer::from(self.key.clone())
    }

    fn encode(&self) -> String {
        format!("cert={}\nkey={}\n", hex(&self.cert), hex(&self.key))
    }

    fn decode(text: &str) -> Result<Self, SecError> {
        let campo = |nome: &str| {
            text.lines()
                .find_map(|l| l.strip_prefix(nome).and_then(|r| r.strip_prefix('=')))
                .and_then(unhex)
                .ok_or_else(|| SecError::Identity(format!("arquivo de identidade sem `{nome}`")))
        };
        Ok(Self {
            cert: campo("cert")?,
            key: campo("key")?,
        })
    }
}

/// SHA-256 de um certificado em DER, em hexadecimal minúsculo.
pub fn fingerprint(cert_der: &[u8]) -> String {
    hex(&Sha256::digest(cert_der))
}

/// Os primeiros 16 caracteres da impressão digital, em grupos de 4: serve para mostrar ao
/// usuário e aos logs sem expor a impressão inteira.
pub fn short_fingerprint(fingerprint: &str) -> String {
    fingerprint
        .chars()
        .take(16)
        .collect::<Vec<_>>()
        .chunks(4)
        .map(|c| c.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join(" ")
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok())
        .collect()
}

#[cfg(unix)]
fn write_private(path: &Path, content: &str) -> io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(content.as_bytes())
}

#[cfg(not(unix))]
fn write_private(path: &Path, content: &str) -> io::Result<()> {
    fs::write(path, content)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identidade_gerada_tem_impressao_de_64_hex() {
        let id = Identity::generate().unwrap();
        let fp = id.fingerprint();
        assert_eq!(fp.len(), 64);
        assert!(fp.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn duas_identidades_tem_impressoes_diferentes() {
        assert_ne!(
            Identity::generate().unwrap().fingerprint(),
            Identity::generate().unwrap().fingerprint()
        );
    }

    #[test]
    fn gravar_e_ler_devolve_a_mesma_identidade() {
        let dir = std::env::temp_dir().join(format!("cdc-id-{}", std::process::id()));
        let caminho = dir.join("identidade");
        let _ = fs::remove_dir_all(&dir);
        let criada = Identity::load_or_create(&caminho).unwrap();
        let lida = Identity::load_or_create(&caminho).unwrap();
        assert_eq!(criada.fingerprint(), lida.fingerprint());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let modo = fs::metadata(&caminho).unwrap().permissions().mode();
            assert_eq!(modo & 0o077, 0, "só o dono pode ler a chave");
        }
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn arquivo_corrompido_e_erro_e_nao_e_sobrescrito() {
        let dir = std::env::temp_dir().join(format!("cdc-id-ruim-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let caminho = dir.join("identidade");
        fs::write(&caminho, "lixo").unwrap();
        assert!(Identity::load_or_create(&caminho).is_err());
        assert_eq!(fs::read_to_string(&caminho).unwrap(), "lixo");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn impressao_curta_agrupa_de_quatro_em_quatro() {
        assert_eq!(
            short_fingerprint("0123456789abcdef0000"),
            "0123 4567 89ab cdef"
        );
    }
}
