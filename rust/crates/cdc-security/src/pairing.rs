//! Código de pareamento: 6 dígitos que os dois lados calculam e o usuário compara.

use sha2::{Digest, Sha256};

/// Código de 6 dígitos das duas impressões digitais e do `nonce` do computador.
///
/// Quem intermedia a conexão apresenta ao celular um certificado e ao computador outro, e
/// por isso cada tela mostra um código diferente. A ordem dos argumentos é fixa (celular,
/// depois computador) para os dois lados chegarem ao mesmo número.
pub fn pairing_code(phone_fingerprint: &str, computer_fingerprint: &str, nonce: &str) -> String {
    let mut hash = Sha256::new();
    hash.update(b"conectdroidcam-pairing-v1\0");
    for parte in [phone_fingerprint, computer_fingerprint, nonce] {
        hash.update((parte.len() as u32).to_be_bytes());
        hash.update(parte.as_bytes());
    }
    let digest = hash.finalize();
    let n = u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]) % 1_000_000;
    format!("{n:06}")
}

/// Um `nonce` novo, em hexadecimal (16 bytes aleatórios).
pub fn new_nonce() -> Result<String, crate::SecError> {
    // O `rcgen` já traz a fonte de números aleatórios do sistema, por meio do `ring`.
    use rustls::crypto::ring::default_provider;
    let mut bytes = [0u8; 16];
    default_provider()
        .secure_random
        .fill(&mut bytes)
        .map_err(|_| crate::SecError::Identity("sem fonte de números aleatórios".into()))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mesmo_resultado_dos_dois_lados() {
        assert_eq!(
            pairing_code("aa", "bb", "n1"),
            pairing_code("aa", "bb", "n1")
        );
    }

    #[test]
    fn tem_sempre_seis_digitos() {
        for i in 0..200 {
            let c = pairing_code("aa", "bb", &i.to_string());
            assert_eq!(c.len(), 6);
            assert!(c.chars().all(|c| c.is_ascii_digit()));
        }
    }

    #[test]
    fn certificado_diferente_muda_o_codigo() {
        // É o que acontece quando alguém se põe no meio: cada lado vê um certificado.
        assert_ne!(pairing_code("aa", "bb", "n"), pairing_code("aa", "cc", "n"));
        assert_ne!(pairing_code("aa", "bb", "n"), pairing_code("xx", "bb", "n"));
        assert_ne!(pairing_code("aa", "bb", "n"), pairing_code("aa", "bb", "m"));
    }

    #[test]
    fn emendar_campos_nao_colide() {
        assert_ne!(pairing_code("ab", "c", "n"), pairing_code("a", "bc", "n"));
    }

    #[test]
    fn nonces_sao_diferentes_e_tem_32_hex() {
        let (a, b) = (new_nonce().unwrap(), new_nonce().unwrap());
        assert_ne!(a, b);
        assert_eq!(a.len(), 32);
    }
}
