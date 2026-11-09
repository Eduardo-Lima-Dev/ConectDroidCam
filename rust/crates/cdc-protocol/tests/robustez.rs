//! Entradas hostis: o leitor pode recusar qualquer coisa, mas nunca deve entrar em pânico.

use cdc_protocol::{Frame, FrameType, Message};

/// Gerador xorshift determinístico, para os testes serem reproduzíveis.
struct Xorshift(u64);

impl Xorshift {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    fn bytes(&mut self, len: usize) -> Vec<u8> {
        (0..len).map(|_| (self.next() >> 24) as u8).collect()
    }
}

#[test]
fn bytes_aleatorios_nunca_causam_panico() {
    let mut rng = Xorshift(0x9E37_79B9_7F4A_7C15);
    for i in 0..20_000 {
        let tamanho = (rng.next() % 200) as usize;
        let entrada = rng.bytes(tamanho);
        let _ = Frame::read_from(&mut entrada.as_slice());
        let _ = Message::from_json(&entrada);
        if i % 5000 == 0 {
            assert!(tamanho < 200);
        }
    }
}

#[test]
fn frames_validos_corrompidos_nunca_causam_panico() {
    let mut rng = Xorshift(42);
    let base = Frame::new(FrameType::Video, 1, 99, rng.bytes(300))
        .encode()
        .unwrap();
    for _ in 0..20_000 {
        let mut copia = base.clone();
        for _ in 0..(1 + rng.next() % 4) {
            let pos = (rng.next() as usize) % copia.len();
            copia[pos] = (rng.next() >> 16) as u8;
        }
        let corte = (rng.next() as usize) % (copia.len() + 1);
        let _ = Frame::read_from(&mut &copia[..corte]);
    }
}

#[test]
fn cabecalho_com_tamanho_gigante_nao_aloca_gigabytes() {
    // 0xFFFF_FFFF no campo de tamanho: tem que ser recusado só pelo cabeçalho.
    let mut cabecalho = [0u8; 14];
    cabecalho[0] = FrameType::Video as u8;
    cabecalho[10..14].copy_from_slice(&u32::MAX.to_be_bytes());
    assert!(Frame::read_from(&mut cabecalho.as_slice()).is_err());
}
