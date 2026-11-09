//! Núcleo do receptor do ConectDroidCam, compartilhado pelo app do computador e pelas
//! ferramentas de linha de comando.
//!
//! - [`discovery`]: acha os celulares na rede (mDNS).
//! - [`session`]: conecta a um celular e entrega o vídeo recebido.
//! - [`filter`]: gira o vídeo para ficar em pé e o encaixa num quadro de tamanho fixo.
//! - [`output`]: escreve na webcam virtual (V4L2) por um `ffmpeg`.
//! - [`stats`]: medições da sessão.

pub mod discovery;
pub mod filter;
pub mod output;
pub mod session;
pub mod stats;
pub mod v4l2info;

pub use cdc_security::{Identity, SecError, SecureLink};
pub use discovery::{Device, DeviceEvent, Discovery, DiscoveryError, SERVICE_TYPE};
pub use filter::{Canvas, OutputSize, canvas_size, normalize_rotation, video_filter};
pub use output::{DISCARD, OutputError, Sink};
pub use session::{
    SessionError, SessionEvent, SessionOptions, ShapeDevice, Stats, StopHandle, connect,
    connect_secure_phone, run,
};
pub use stats::{LagTracker, Report, percentile};
