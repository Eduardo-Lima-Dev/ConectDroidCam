//! Protocolo v1 do ConectDroidCam: frames binários e mensagens de controle.
//!
//! Este crate não abre sockets nem conhece TLS. Ele só define o formato e o
//! valida, para que emissor, receptor e testes compartilhem a mesma definição.

mod error;
mod frame;
mod message;

pub use error::ProtocolError;
pub use frame::{
    FLAG_KEYFRAME, Frame, FrameHeader, FrameType, HEADER_LEN, MAX_CONTROL_PAYLOAD, MAX_PAYLOAD,
};
pub use message::{
    CapabilityMode, ErrorCode, Facing, Message, PROTOCOL_VERSION, Platform, ProfileAvailability,
    VideoProfile,
};
