use std::io;

use thiserror::Error;

use crate::frame::FrameType;

/// Falhas ao ler, escrever ou interpretar o protocolo.
#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("tipo de frame desconhecido: {0}")]
    UnknownFrameType(u8),
    #[error("flags {flags:#04x} inválidas para frame {kind:?}")]
    InvalidFlags { flags: u8, kind: FrameType },
    #[error("payload de {len} bytes excede o limite de {max}")]
    PayloadTooLarge { len: u64, max: u32 },
    #[error("conexão encerrada no meio de um frame")]
    Truncated,
    #[error("mensagem de controle inválida: {0}")]
    InvalidControl(#[from] serde_json::Error),
    #[error("versão de protocolo não suportada: {0}")]
    UnsupportedVersion(u32),
    #[error("esperava frame de controle, recebi {0:?}")]
    NotControl(FrameType),
    #[error(transparent)]
    Io(#[from] io::Error),
}
