//! Utilitários para H.264 em Annex B.

/// Maior quantidade de bytes acumulada sem achar dois delimitadores; acima disso o
/// buffer é descartado, para uma entrada sem delimitadores não crescer sem fim.
const MAX_BUFFER: usize = 16 * 1024 * 1024;

const NAL_IDR: u8 = 5;
const NAL_SPS: u8 = 7;
const NAL_PPS: u8 = 8;
const NAL_AUD: u8 = 9;

/// Posições de cada start code `00 00 01`, com o tipo da NAL que vem depois.
fn start_codes(data: &[u8]) -> Vec<(usize, u8)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 3 < data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            out.push((i, data[i + 3] & 0x1f));
            i += 3;
        } else {
            i += 1;
        }
    }
    out
}

/// Início real da NAL: inclui o zero extra de um start code de 4 bytes.
fn nal_start(data: &[u8], code_pos: usize) -> usize {
    if code_pos > 0 && data[code_pos - 1] == 0 {
        code_pos - 1
    } else {
        code_pos
    }
}

/// Divide um fluxo Annex B em unidades de acesso, usando delimitadores AUD (NAL 9).
///
/// O ffmpeg precisa gerar o fluxo com `-bsf:v h264_metadata=aud=insert`.
#[derive(Default)]
pub struct AccessUnitSplitter {
    buf: Vec<u8>,
}

impl AccessUnitSplitter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Acrescenta bytes e devolve as unidades de acesso que já terminaram.
    ///
    /// A última unidade só é entregue quando o próximo AUD chega, porque até lá
    /// ainda pode receber mais NALs.
    pub fn push(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        self.buf.extend_from_slice(data);
        let starts: Vec<usize> = start_codes(&self.buf)
            .into_iter()
            .filter(|&(_, kind)| kind == NAL_AUD)
            .map(|(pos, _)| nal_start(&self.buf, pos))
            .collect();
        if starts.len() < 2 {
            if self.buf.len() > MAX_BUFFER {
                self.buf.clear();
            }
            return Vec::new();
        }
        let units = starts
            .windows(2)
            .map(|w| self.buf[w[0]..w[1]].to_vec())
            .collect();
        self.buf.drain(..starts[starts.len() - 1]);
        units
    }
}

/// `true` se a unidade de acesso contém um frame IDR.
pub fn is_keyframe(unit: &[u8]) -> bool {
    start_codes(unit).iter().any(|&(_, kind)| kind == NAL_IDR)
}

/// SPS e PPS da unidade, concatenados com seus start codes. `None` se faltar algum.
pub fn extract_config(unit: &[u8]) -> Option<Vec<u8>> {
    let codes = start_codes(unit);
    let mut config = Vec::new();
    let (mut has_sps, mut has_pps) = (false, false);
    for (idx, &(pos, kind)) in codes.iter().enumerate() {
        if kind != NAL_SPS && kind != NAL_PPS {
            continue;
        }
        let begin = nal_start(unit, pos);
        let end = codes
            .get(idx + 1)
            .map_or(unit.len(), |&(next, _)| nal_start(unit, next));
        config.extend_from_slice(&unit[begin..end]);
        has_sps |= kind == NAL_SPS;
        has_pps |= kind == NAL_PPS;
    }
    (has_sps && has_pps).then_some(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    const AUD: [u8; 6] = [0, 0, 0, 1, 0x09, 0xf0];

    fn nal(kind: u8, corpo: &[u8]) -> Vec<u8> {
        let mut v = vec![0, 0, 0, 1, kind];
        v.extend_from_slice(corpo);
        v
    }

    fn unidade(nals: &[Vec<u8>]) -> Vec<u8> {
        let mut v = AUD.to_vec();
        for n in nals {
            v.extend_from_slice(n);
        }
        v
    }

    #[test]
    fn divide_em_unidades_e_segura_a_ultima() {
        let a = unidade(&[nal(0x65, &[1, 2, 3])]);
        let b = unidade(&[nal(0x41, &[4, 5])]);
        let c = unidade(&[nal(0x41, &[6])]);
        let mut fluxo = a.clone();
        fluxo.extend(&b);
        fluxo.extend(&c);

        let mut divisor = AccessUnitSplitter::new();
        let prontas = divisor.push(&fluxo);
        assert_eq!(prontas, vec![a, b]);
        // `c` só sai quando o próximo AUD chegar.
        let prontas = divisor.push(&AUD);
        assert_eq!(prontas, vec![c]);
    }

    #[test]
    fn funciona_com_bytes_chegando_aos_pedacos() {
        let a = unidade(&[nal(0x65, &[9; 50])]);
        let b = unidade(&[nal(0x41, &[8; 20])]);
        let mut fluxo = a.clone();
        fluxo.extend(&b);
        fluxo.extend(&AUD);

        let mut divisor = AccessUnitSplitter::new();
        let mut prontas = Vec::new();
        for pedaco in fluxo.chunks(3) {
            prontas.extend(divisor.push(pedaco));
        }
        assert_eq!(prontas, vec![a, b]);
    }

    #[test]
    fn detecta_keyframe() {
        assert!(is_keyframe(&unidade(&[nal(0x65, &[1])])));
        assert!(!is_keyframe(&unidade(&[nal(0x41, &[1])])));
    }

    #[test]
    fn extrai_sps_e_pps() {
        let sps = nal(0x67, &[0x42, 0x00, 0x1f]);
        let pps = nal(0x68, &[0xce, 0x3c]);
        let idr = nal(0x65, &[1, 2, 3]);
        let u = unidade(&[sps.clone(), pps.clone(), idr]);
        let mut esperado = sps;
        esperado.extend(pps);
        assert_eq!(extract_config(&u), Some(esperado));
    }

    #[test]
    fn sem_sps_ou_pps_nao_ha_config() {
        assert_eq!(extract_config(&unidade(&[nal(0x65, &[1])])), None);
        assert_eq!(extract_config(&unidade(&[nal(0x67, &[1])])), None);
    }

    #[test]
    fn entrada_sem_delimitadores_nao_cresce_sem_limite() {
        let mut divisor = AccessUnitSplitter::new();
        let lixo = vec![0xAAu8; 1024 * 1024];
        for _ in 0..40 {
            assert!(divisor.push(&lixo).is_empty());
        }
        assert!(divisor.buf.len() <= MAX_BUFFER + lixo.len());
    }
}
