//! Frame binário do protocolo v1.
//!
//! Cabeçalho de 14 bytes, em big-endian:
//!
//! | Campo    | Tamanho | Conteúdo                                   |
//! |----------|---------|--------------------------------------------|
//! | `type`   | u8      | [`FrameType`]                              |
//! | `flags`  | u8      | bit 0 = keyframe (só em vídeo)             |
//! | `pts_us` | u64     | relógio de captura, em microssegundos      |
//! | `length` | u32     | tamanho do payload                         |

use std::io::{self, Read, Write};

use crate::error::ProtocolError;

/// Tamanho fixo do cabeçalho, em bytes.
pub const HEADER_LEN: usize = 14;
/// Limite de payload para vídeo, áudio e configurações (8 MiB).
pub const MAX_PAYLOAD: u32 = 8 * 1024 * 1024;
/// Limite de payload para mensagens de controle (64 KiB).
pub const MAX_CONTROL_PAYLOAD: u32 = 64 * 1024;
/// Marca um frame de vídeo que pode ser decodificado sem frames anteriores.
pub const FLAG_KEYFRAME: u8 = 0b0000_0001;

/// Tipo de conteúdo transportado por um frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameType {
    /// Mensagem de controle em JSON.
    Control = 0,
    /// SPS e PPS do H.264, em Annex B.
    VideoConfig = 1,
    /// Uma unidade de acesso H.264, em Annex B.
    Video = 2,
    /// `AudioSpecificConfig` do AAC.
    AudioConfig = 3,
    /// Um frame AAC bruto.
    Audio = 4,
}

impl FrameType {
    fn from_byte(byte: u8) -> Result<Self, ProtocolError> {
        match byte {
            0 => Ok(Self::Control),
            1 => Ok(Self::VideoConfig),
            2 => Ok(Self::Video),
            3 => Ok(Self::AudioConfig),
            4 => Ok(Self::Audio),
            other => Err(ProtocolError::UnknownFrameType(other)),
        }
    }

    /// Maior payload aceito para este tipo de frame.
    pub fn max_payload(self) -> u32 {
        match self {
            Self::Control => MAX_CONTROL_PAYLOAD,
            _ => MAX_PAYLOAD,
        }
    }
}

/// Cabeçalho já validado.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHeader {
    pub kind: FrameType,
    pub flags: u8,
    pub pts_us: u64,
    pub len: u32,
}

impl FrameHeader {
    /// Valida e interpreta 14 bytes de cabeçalho, antes de qualquer alocação.
    pub fn parse(buf: &[u8; HEADER_LEN]) -> Result<Self, ProtocolError> {
        let kind = FrameType::from_byte(buf[0])?;
        let flags = buf[1];
        let mut pts = [0u8; 8];
        pts.copy_from_slice(&buf[2..10]);
        let mut len = [0u8; 4];
        len.copy_from_slice(&buf[10..14]);
        let header = Self {
            kind,
            flags,
            pts_us: u64::from_be_bytes(pts),
            len: u32::from_be_bytes(len),
        };
        header.validate()?;
        Ok(header)
    }

    /// Serializa o cabeçalho.
    pub fn to_bytes(&self) -> [u8; HEADER_LEN] {
        let mut out = [0u8; HEADER_LEN];
        out[0] = self.kind as u8;
        out[1] = self.flags;
        out[2..10].copy_from_slice(&self.pts_us.to_be_bytes());
        out[10..14].copy_from_slice(&self.len.to_be_bytes());
        out
    }

    fn validate(&self) -> Result<(), ProtocolError> {
        let allowed = if self.kind == FrameType::Video {
            FLAG_KEYFRAME
        } else {
            0
        };
        if self.flags & !allowed != 0 {
            return Err(ProtocolError::InvalidFlags {
                flags: self.flags,
                kind: self.kind,
            });
        }
        let max = self.kind.max_payload();
        if self.len > max {
            return Err(ProtocolError::PayloadTooLarge {
                len: u64::from(self.len),
                max,
            });
        }
        Ok(())
    }
}

/// Frame completo: cabeçalho mais payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub kind: FrameType,
    pub flags: u8,
    pub pts_us: u64,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: FrameType, flags: u8, pts_us: u64, payload: Vec<u8>) -> Self {
        Self {
            kind,
            flags,
            pts_us,
            payload,
        }
    }

    /// `true` se o frame tem o bit de keyframe.
    pub fn is_keyframe(&self) -> bool {
        self.flags & FLAG_KEYFRAME != 0
    }

    fn header(&self) -> Result<FrameHeader, ProtocolError> {
        let len =
            u32::try_from(self.payload.len()).map_err(|_| ProtocolError::PayloadTooLarge {
                len: self.payload.len() as u64,
                max: self.kind.max_payload(),
            })?;
        let header = FrameHeader {
            kind: self.kind,
            flags: self.flags,
            pts_us: self.pts_us,
            len,
        };
        header.validate()?;
        Ok(header)
    }

    /// Serializa o frame inteiro em memória.
    pub fn encode(&self) -> Result<Vec<u8>, ProtocolError> {
        let header = self.header()?;
        let mut out = Vec::with_capacity(HEADER_LEN + self.payload.len());
        out.extend_from_slice(&header.to_bytes());
        out.extend_from_slice(&self.payload);
        Ok(out)
    }

    /// Escreve o frame em um fluxo, validando antes de enviar qualquer byte.
    pub fn write_to<W: Write>(&self, writer: &mut W) -> Result<(), ProtocolError> {
        let header = self.header()?;
        writer.write_all(&header.to_bytes())?;
        writer.write_all(&self.payload)?;
        Ok(())
    }

    /// Lê um frame de um fluxo.
    ///
    /// Devolve `Ok(None)` se a conexão fechou limpa, antes do primeiro byte do
    /// cabeçalho. Fechar no meio de um frame é [`ProtocolError::Truncated`].
    pub fn read_from<R: Read>(reader: &mut R) -> Result<Option<Self>, ProtocolError> {
        let mut buf = [0u8; HEADER_LEN];
        let mut got = 0;
        while got < HEADER_LEN {
            match reader.read(&mut buf[got..]) {
                Ok(0) if got == 0 => return Ok(None),
                Ok(0) => return Err(ProtocolError::Truncated),
                Ok(n) => got += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e.into()),
            }
        }
        let header = FrameHeader::parse(&buf)?;
        let mut payload = vec![0u8; header.len as usize];
        reader.read_exact(&mut payload).map_err(|e| {
            if e.kind() == io::ErrorKind::UnexpectedEof {
                ProtocolError::Truncated
            } else {
                e.into()
            }
        })?;
        Ok(Some(Self {
            kind: header.kind,
            flags: header.flags,
            pts_us: header.pts_us,
            payload,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn video(len: usize) -> Frame {
        Frame::new(FrameType::Video, FLAG_KEYFRAME, 123_456, vec![7; len])
    }

    #[test]
    fn roundtrip_preserva_todos_os_campos() {
        let original = video(1000);
        let bytes = original.encode().unwrap();
        assert_eq!(bytes.len(), HEADER_LEN + 1000);
        let lido = Frame::read_from(&mut bytes.as_slice()).unwrap().unwrap();
        assert_eq!(lido, original);
        assert!(lido.is_keyframe());
    }

    #[test]
    fn cabecalho_e_big_endian() {
        let bytes = Frame::new(FrameType::Audio, 0, 0x0102_0304_0506_0708, vec![0; 5])
            .encode()
            .unwrap();
        assert_eq!(bytes[0], 4);
        assert_eq!(&bytes[2..10], &[1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(&bytes[10..14], &[0, 0, 0, 5]);
    }

    #[test]
    fn payload_vazio_e_valido() {
        let frame = Frame::new(FrameType::VideoConfig, 0, 0, vec![]);
        let bytes = frame.encode().unwrap();
        assert_eq!(
            Frame::read_from(&mut bytes.as_slice()).unwrap(),
            Some(frame)
        );
    }

    #[test]
    fn fluxo_vazio_e_fechamento_limpo() {
        assert_eq!(Frame::read_from(&mut io::empty()).unwrap(), None);
    }

    #[test]
    fn cabecalho_incompleto_e_truncado() {
        let bytes = video(10).encode().unwrap();
        let err = Frame::read_from(&mut &bytes[..5]).unwrap_err();
        assert!(matches!(err, ProtocolError::Truncated));
    }

    #[test]
    fn payload_incompleto_e_truncado() {
        let bytes = video(100).encode().unwrap();
        let err = Frame::read_from(&mut &bytes[..HEADER_LEN + 40]).unwrap_err();
        assert!(matches!(err, ProtocolError::Truncated));
    }

    #[test]
    fn tipo_desconhecido_e_rejeitado() {
        let mut bytes = video(4).encode().unwrap();
        bytes[0] = 9;
        let err = Frame::read_from(&mut bytes.as_slice()).unwrap_err();
        assert!(matches!(err, ProtocolError::UnknownFrameType(9)));
    }

    #[test]
    fn flags_reservadas_sao_rejeitadas() {
        let mut bytes = video(4).encode().unwrap();
        bytes[1] = 0b10;
        let err = Frame::read_from(&mut bytes.as_slice()).unwrap_err();
        assert!(matches!(err, ProtocolError::InvalidFlags { .. }));
    }

    #[test]
    fn keyframe_so_vale_em_video() {
        let frame = Frame::new(FrameType::Audio, FLAG_KEYFRAME, 0, vec![1]);
        assert!(matches!(
            frame.encode().unwrap_err(),
            ProtocolError::InvalidFlags { .. }
        ));
    }

    #[test]
    fn tamanho_acima_do_limite_e_rejeitado_sem_alocar() {
        let header = FrameHeader {
            kind: FrameType::Video,
            flags: 0,
            pts_us: 0,
            len: MAX_PAYLOAD + 1,
        };
        // Só o cabeçalho: se o leitor tentasse alocar e ler o payload, falharia por outro motivo.
        let err = Frame::read_from(&mut header.to_bytes().as_slice()).unwrap_err();
        assert!(matches!(err, ProtocolError::PayloadTooLarge { .. }));
    }

    #[test]
    fn controle_tem_limite_menor() {
        let frame = Frame::new(
            FrameType::Control,
            0,
            0,
            vec![b' '; MAX_CONTROL_PAYLOAD as usize + 1],
        );
        assert!(matches!(
            frame.encode().unwrap_err(),
            ProtocolError::PayloadTooLarge { .. }
        ));
    }

    #[test]
    fn varios_frames_em_sequencia() {
        let mut fluxo = Vec::new();
        for i in 0..5u64 {
            Frame::new(FrameType::Video, 0, i * 33_333, vec![i as u8; 10])
                .write_to(&mut fluxo)
                .unwrap();
        }
        let mut leitor = fluxo.as_slice();
        for i in 0..5u64 {
            let frame = Frame::read_from(&mut leitor).unwrap().unwrap();
            assert_eq!(frame.pts_us, i * 33_333);
        }
        assert_eq!(Frame::read_from(&mut leitor).unwrap(), None);
    }
}
